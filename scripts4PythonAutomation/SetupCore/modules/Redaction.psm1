#Requires -Version 5.1
# =============================================================================
# Module  : Redaction.psm1
# Purpose : Central secret redaction for logs and support bundles (Part U).
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
    One place decides what a secret looks like. Every path that leaves the
    machine - support bundles, structured logs, diagnostics output - goes
    through here, so a new secret shape only has to be taught once.
#>

$script:RedactionPlaceholder = '***REDACTED***'

# Key names whose VALUE is always removed, matched case-insensitively as a
# substring so 'AZURE_DEVOPS_PAT' and 'apiKey' are both covered.
$script:SecretKeyFragments = @(
    'password', 'passwd', 'pwd',
    'token',
    'pat',
    'secret',
    'apikey', 'api_key', 'api-key',
    'authorization', 'auth',
    'credential', 'cred',
    'private_key', 'privatekey',
    'connectionstring', 'connection_string',
    'sessionid', 'session_id',
    'signature',
    'clientsecret', 'client_secret'
)

function Get-RedactionPlaceholder {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:RedactionPlaceholder
}

function Test-SecretKeyName {
<#
.SYNOPSIS
    True when a key name looks like it holds a secret.

.DESCRIPTION
    Substring match against a fixed fragment list. Deliberately eager: a false
    positive costs a redacted diagnostic field, a false negative leaks a token.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $normalized = $Name.ToLowerInvariant()
    foreach ($fragment in $script:SecretKeyFragments) {
        if ($normalized.Contains($fragment)) { return $true }
    }
    return $false
}

function Protect-SecretText {
<#
.SYNOPSIS
    Redacts secrets that appear inside free-form text.

.DESCRIPTION
    Handles the shapes that actually turn up in logs and git output:
      * credentials embedded in a URL   https://user:PAT@host/...
      * key/value pairs                 token=abc, "apiKey": "abc", PAT: abc
      * Authorization headers           Authorization: Bearer abc
      * bare Azure DevOps / GitHub PATs

    Returns the text with every match replaced by the redaction placeholder.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string] $Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $out = $Text
    $ph = $script:RedactionPlaceholder

    # 1. Credentials embedded in a URL: scheme://user:secret@host
    #    Keep the user so the log still says who, drop the secret.
    $out = [regex]::Replace($out, '(?i)([a-z][a-z0-9+.\-]*://)([^:/@\s]+):([^@/\s]+)@', ('$1$2:{0}@' -f $ph))

    # 2. Authorization headers, including the scheme word.
    # The scheme word is dropped with the value so rule 3 cannot redact it a
    # second time and produce a doubled placeholder.
    $out = [regex]::Replace($out, '(?i)(authorization\s*[:=]\s*)(?:bearer|basic|token)?\s*\S+', ('$1{0}' -f $ph))

    # 3. key = value / key: value / "key": "value" for known secret key names.
    $keyPattern = ($script:SecretKeyFragments | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $out = [regex]::Replace(
        $out,
        ('(?i)(["'']?[\w.\-]*(?:{0})[\w.\-]*["'']?\s*[:=]\s*)(["'']?)([^\s,;"''}}\)]+)(\2)' -f $keyPattern),
        ('$1$2{0}$4' -f $ph))

    # 4. Bare Azure DevOps / GitHub style tokens.
    $out = [regex]::Replace($out, '\bgh[pousr]_[A-Za-z0-9]{16,}\b', $ph)
    $out = [regex]::Replace($out, '\b[a-z2-7]{52}\b', $ph)   # classic ADO PAT shape

    return $out
}

function Protect-SecretObject {
<#
.SYNOPSIS
    Recursively redacts secrets in hashtables, PSCustomObjects and arrays.

.DESCRIPTION
    A value is removed when its KEY looks secret; otherwise string values are
    still passed through Protect-SecretText so an embedded credential URL is
    caught even under an innocent key name.

.PARAMETER Depth
    Recursion guard. Structures deeper than this are replaced by a marker
    rather than risking an infinite walk on a self-referencing object.
#>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $InputObject,
        [Parameter()][int] $Depth = 12
    )

    if ($null -eq $InputObject) { return $null }
    if ($Depth -le 0) { return '***TRUNCATED***' }

    if ($InputObject -is [string]) { return (Protect-SecretText -Text $InputObject) }
    if ($InputObject -is [bool] -or $InputObject -is [int] -or $InputObject -is [long] -or
        $InputObject -is [double] -or $InputObject -is [datetime]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            if (Test-SecretKeyName -Name ([string]$key)) { $result[[string]$key] = $script:RedactionPlaceholder }
            else { $result[[string]$key] = Protect-SecretObject -InputObject $InputObject[$key] -Depth ($Depth - 1) }
        }
        return $result
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $InputObject) { $items += , (Protect-SecretObject -InputObject $item -Depth ($Depth - 1)) }
        return , $items
    }

    if ($InputObject -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            if (Test-SecretKeyName -Name $prop.Name) { $result[$prop.Name] = $script:RedactionPlaceholder }
            else { $result[$prop.Name] = Protect-SecretObject -InputObject $prop.Value -Depth ($Depth - 1) }
        }
        return [pscustomobject]$result
    }

    return (Protect-SecretText -Text ([string]$InputObject))
}

function Protect-SecretFile {
<#
.SYNOPSIS
    Copies a text file to a destination with every secret redacted.

.DESCRIPTION
    Used when building a support bundle: the original is never moved, only a
    sanitised copy is written.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string] $SourcePath,
        [Parameter(Mandatory = $true)][string] $DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($DestinationPath, 'Write redacted copy')) { return $false }

    $content = Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8 -ErrorAction Stop
    Set-Content -LiteralPath $DestinationPath -Value (Protect-SecretText -Text $content) -Encoding UTF8
    return $true
}

Export-ModuleMember -Function `
    Protect-SecretText, `
    Protect-SecretObject, `
    Protect-SecretFile, `
    Test-SecretKeyName, `
    Get-RedactionPlaceholder
