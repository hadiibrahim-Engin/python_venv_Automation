#Requires -Version 5.1
# =============================================================================
# Module  : Distribution.psm1
# Purpose : Release format, manifests and channels for the in-repo
#           distribution branch (Parts A, B, AB).
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Errors.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop

<#
    Distribution lives on an orphan branch of THIS repository, not in a second
    repo and not as a ZIP.

        distribution (orphan branch)
        ├── install/
        │   ├── Install-DevSetup.cmd
        │   └── Install-DevSetup.ps1
        ├── channels/
        │   ├── stable.json
        │   └── pilot.json
        └── packages/
            └── 1.9.0/
                ├── manifest.json
                ├── SHA256SUMS.txt
                └── content/          <- loose files, delta-compressible

    Why no ZIP: git is already a content-addressed, immutable transport. A ZIP
    cannot be delta-compressed, so every release would add its full size to the
    history forever, and release diffs would be unreadable. Loose files plus a
    per-file checksum list give stronger guarantees at a fraction of the size.

    Trust chain:
        Entra/HTTPS git  ->  channels/<channel>.json
                         ->  packages/<v>/manifest.json (hash of SHA256SUMS.txt)
                         ->  SHA256SUMS.txt (hash per file)
                         ->  Authenticode per file (Windows)
#>

$script:DistributionSchemaVersion = 1
$script:DistributionProduct       = 'DevSetup'
$script:ChecksumFileName          = 'SHA256SUMS.txt'
$script:PackageManifestName       = 'manifest.json'
$script:ContentDirName            = 'content'

function Get-DevSetupDistributionLayout {
    <#
    .SYNOPSIS
        The well-known names used on the distribution branch.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [pscustomobject]@{
        SchemaVersion    = $script:DistributionSchemaVersion
        Product          = $script:DistributionProduct
        ChecksumFileName = $script:ChecksumFileName
        ManifestName     = $script:PackageManifestName
        ContentDirName   = $script:ContentDirName
        ChannelsDir      = 'channels'
        PackagesDir      = 'packages'
        InstallDir       = 'install'
    }
}

function New-DistributionError {
    param([string] $Message, [string] $ErrorCode = 'DISTRIBUTION_INVALID', [hashtable] $Context = @{})
    return (New-SetupException -Message $Message -ErrorCode $ErrorCode -Step 'DISTRIBUTION' -Context $Context)
}

# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------

function Test-DevSetupVersionString {
<#
.SYNOPSIS
    True when the string is a plain X.Y.Z SemVer release version.

.DESCRIPTION
    Pre-release and build-metadata suffixes are rejected on purpose: the
    ordering rules for them are subtle, and a distribution channel that cannot
    compare two versions with certainty is worse than one that refuses.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string] $Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    return [bool]($Version -match '^\d+\.\d+\.\d+$')
}

function ConvertTo-DevSetupVersion {
<#
.SYNOPSIS
    Converts a validated X.Y.Z string to [version], failing closed.
#>
    [CmdletBinding()]
    [OutputType([version])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Version)

    if (-not (Test-DevSetupVersionString -Version $Version)) {
        throw (New-DistributionError -Message ("'{0}' is not a plain X.Y.Z version." -f $Version) `
            -ErrorCode 'DISTRIBUTION_VERSION_INVALID' -Context @{ Version = $Version })
    }
    return [version]$Version
}

# ---------------------------------------------------------------------------
# Checksums
# ---------------------------------------------------------------------------

function New-DevSetupChecksumFile {
<#
.SYNOPSIS
    Writes SHA256SUMS.txt covering every file under a content directory.

.DESCRIPTION
    Format is `<sha256>  <relative/path>` with forward slashes, sorted by path
    so the file is byte-stable across machines and reruns. That stability is
    what makes the manifest's checksumsSha256 meaningful.

.OUTPUTS
    PSCustomObject with Path, FileCount and Sha256 (hash of the list itself).
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $ContentPath,
        [Parameter(Mandatory = $true)][string] $OutputPath
    )

    $root = (Resolve-Path -LiteralPath $ContentPath).Path
    $files = Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($root.Length).TrimStart([char]'\', [char]'/')
        $relative = $relative -replace '\\', '/'
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines.Add(('{0}  {1}' -f $hash, $relative))
    }
    $sorted = @($lines.ToArray() | Sort-Object { ($_ -split '  ', 2)[1] })
    $text = ($sorted -join "`n")
    if ($text.Length -gt 0) { $text += "`n" }

    if ($PSCmdlet.ShouldProcess($OutputPath, 'Write SHA256SUMS.txt')) {
        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -LiteralPath $OutputPath -Value $text -Encoding UTF8 -NoNewline
    }

    [pscustomobject]@{
        Path      = $OutputPath
        FileCount = $sorted.Count
        Sha256    = (Get-DevSetupTextSha256 -Text $text)
    }
}

function Get-DevSetupTextSha256 {
    <#
    .SYNOPSIS
        SHA256 of a string as lowercase hex.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}

function Test-DevSetupChecksumFile {
<#
.SYNOPSIS
    Verifies every file listed in SHA256SUMS.txt, and that nothing extra exists.

.DESCRIPTION
    Both directions matter: a changed file is caught by its hash, an *added*
    file would otherwise slip in unverified. Returns a result object rather
    than throwing so the caller can log every mismatch at once.

.OUTPUTS
    PSCustomObject with IsValid, Mismatched, Missing, Unexpected, Verified.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $ContentPath,
        [Parameter(Mandatory = $true)][string] $ChecksumPath
    )

    $mismatched = New-Object System.Collections.Generic.List[string]
    $missing    = New-Object System.Collections.Generic.List[string]
    $unexpected = New-Object System.Collections.Generic.List[string]
    $verified   = 0

    if (-not (Test-Path -LiteralPath $ChecksumPath -PathType Leaf)) {
        throw (New-DistributionError -Message ("Checksum file not found: {0}" -f $ChecksumPath) `
            -ErrorCode 'DISTRIBUTION_CHECKSUMS_MISSING' -Context @{ Path = $ChecksumPath })
    }
    if (-not (Test-Path -LiteralPath $ContentPath -PathType Container)) {
        throw (New-DistributionError -Message ("Content directory not found: {0}" -f $ContentPath) `
            -ErrorCode 'DISTRIBUTION_CONTENT_MISSING' -Context @{ Path = $ContentPath })
    }

    $root = (Resolve-Path -LiteralPath $ContentPath).Path
    $listed = @{}

    foreach ($line in (Get-Content -LiteralPath $ChecksumPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '  ', 2
        if ($parts.Count -ne 2) {
            throw (New-DistributionError -Message ("Malformed checksum line: '{0}'" -f $line) `
                -ErrorCode 'DISTRIBUTION_CHECKSUMS_MALFORMED' -Context @{ Line = $line })
        }
        $expected = $parts[0].Trim().ToLowerInvariant()
        $relative = $parts[1].Trim()
        $listed[$relative] = $true

        $full = Join-Path $root ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $missing.Add($relative); continue }

        $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { $mismatched.Add($relative) } else { $verified++ }
    }

    foreach ($file in (Get-ChildItem -LiteralPath $root -Recurse -File)) {
        $relative = ($file.FullName.Substring($root.Length).TrimStart([char]'\', [char]'/')) -replace '\\', '/'
        if (-not $listed.ContainsKey($relative)) { $unexpected.Add($relative) }
    }

    [pscustomobject]@{
        IsValid    = ($mismatched.Count -eq 0 -and $missing.Count -eq 0 -and $unexpected.Count -eq 0)
        Verified   = $verified
        Mismatched = $mismatched.ToArray()
        Missing    = $missing.ToArray()
        Unexpected = $unexpected.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Manifests
# ---------------------------------------------------------------------------

function Test-DevSetupManifestObject {
<#
.SYNOPSIS
    Strict field/type validation with forward compatibility.

.DESCRIPTION
    Required fields must be present and of the right type. Unknown fields are
    tolerated so a newer publisher can add data without breaking older clients
    (Part B).

.OUTPUTS
    PSCustomObject with IsValid and Errors.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Manifest,
        [Parameter(Mandatory = $true)][hashtable] $Required,
        [Parameter()][string] $Label = 'manifest'
    )

    $errors = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Manifest) {
        $errors.Add("$Label is null.")
        return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray() }
    }

    $names = @($Manifest.PSObject.Properties.Name)
    foreach ($field in ($Required.Keys | Sort-Object)) {
        if ($names -notcontains $field) { $errors.Add("$Label is missing required field '$field'."); continue }
        $value = $Manifest.$field
        switch ($Required[$field]) {
            'string' {
                if ($null -eq $value -or -not ($value -is [string]) -or [string]::IsNullOrWhiteSpace($value)) {
                    $errors.Add("$Label field '$field' must be a non-empty string.")
                }
            }
            'int' {
                if ($null -eq $value -or -not ($value -is [int] -or $value -is [long])) {
                    $errors.Add("$Label field '$field' must be an integer.")
                }
            }
            'bool' {
                if ($null -eq $value -or -not ($value -is [bool])) {
                    $errors.Add("$Label field '$field' must be a boolean.")
                }
            }
            'version' {
                if ($null -eq $value -or -not ($value -is [string]) -or -not (Test-DevSetupVersionString -Version $value)) {
                    $errors.Add("$Label field '$field' must be a plain X.Y.Z version string.")
                }
            }
            'timestamp' {
                # ConvertFrom-Json turns an ISO-8601 string into [datetime] on
                # its own, so a timestamp field is valid as either shape.
                if ($null -eq $value) {
                    $errors.Add("$Label field '$field' must be an ISO-8601 timestamp.")
                }
                elseif ($value -is [datetime]) { }
                elseif ($value -is [string]) {
                    $parsed = [datetime]::MinValue
                    if ([string]::IsNullOrWhiteSpace($value) -or
                        -not [datetime]::TryParse($value, [System.Globalization.CultureInfo]::InvariantCulture,
                             [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
                        $errors.Add("$Label field '$field' must be an ISO-8601 timestamp.")
                    }
                }
                else {
                    $errors.Add("$Label field '$field' must be an ISO-8601 timestamp.")
                }
            }
            default { $errors.Add("$Label field '$field' has an unknown validation type.") }
        }
    }

    [pscustomobject]@{ IsValid = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

function Test-DevSetupChannelManifest {
<#
.SYNOPSIS
    Validates a channel manifest (channels/stable.json, channels/pilot.json).
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Manifest)

    $result = Test-DevSetupManifestObject -Manifest $Manifest -Label 'channel manifest' -Required @{
        schemaVersion           = 'int'
        product                 = 'string'
        channel                 = 'string'
        version                 = 'version'
        manifest                = 'string'
        minimumSupportedVersion = 'version'
        force                   = 'bool'
        publishedUtc            = 'timestamp'
    }
    if (-not $result.IsValid) { return $result }

    $errors = New-Object System.Collections.Generic.List[string]
    if ([int]$Manifest.schemaVersion -ne $script:DistributionSchemaVersion) {
        $errors.Add(("channel manifest schemaVersion {0} is not supported (expected {1})." -f $Manifest.schemaVersion, $script:DistributionSchemaVersion))
    }
    if ($Manifest.product -ne $script:DistributionProduct) {
        $errors.Add(("channel manifest product '{0}' is not '{1}'." -f $Manifest.product, $script:DistributionProduct))
    }
    if ((ConvertTo-DevSetupVersion -Version $Manifest.minimumSupportedVersion) -gt (ConvertTo-DevSetupVersion -Version $Manifest.version)) {
        $errors.Add('channel manifest minimumSupportedVersion is greater than version.')
    }
    [pscustomobject]@{ IsValid = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

function Test-DevSetupPackageManifest {
<#
.SYNOPSIS
    Validates a package manifest (packages/<version>/manifest.json).
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Manifest,
        [Parameter()][AllowNull()][AllowEmptyString()][string] $ExpectedVersion
    )

    $result = Test-DevSetupManifestObject -Manifest $Manifest -Label 'package manifest' -Required @{
        schemaVersion           = 'int'
        product                 = 'string'
        version                 = 'version'
        contentPath             = 'string'
        checksums               = 'string'
        checksumsSha256         = 'string'
        fileCount               = 'int'
        channel                 = 'string'
        minimumBootstrapVersion = 'version'
        publishedUtc            = 'timestamp'
    }
    if (-not $result.IsValid) { return $result }

    $errors = New-Object System.Collections.Generic.List[string]
    if ([int]$Manifest.schemaVersion -ne $script:DistributionSchemaVersion) {
        $errors.Add(("package manifest schemaVersion {0} is not supported." -f $Manifest.schemaVersion))
    }
    if ($Manifest.product -ne $script:DistributionProduct) {
        $errors.Add(("package manifest product '{0}' is not '{1}'." -f $Manifest.product, $script:DistributionProduct))
    }
    if ($Manifest.checksumsSha256 -notmatch '^[0-9a-f]{64}$') {
        $errors.Add('package manifest checksumsSha256 is not a lowercase SHA256 hex digest.')
    }
    if ([int]$Manifest.fileCount -lt 1) {
        $errors.Add('package manifest fileCount must be at least 1.')
    }
    if ($ExpectedVersion -and $Manifest.version -ne $ExpectedVersion) {
        $errors.Add(("package manifest version '{0}' does not match its directory '{1}'." -f $Manifest.version, $ExpectedVersion))
    }
    [pscustomobject]@{ IsValid = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

function Read-DevSetupJsonFile {
<#
.SYNOPSIS
    Reads and parses a JSON file, failing closed with a structured error.
#>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (New-DistributionError -Message ("File not found: {0}" -f $Path) `
            -ErrorCode 'DISTRIBUTION_FILE_MISSING' -Context @{ Path = $Path })
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw (New-DistributionError -Message ("File is empty: {0}" -f $Path) `
            -ErrorCode 'DISTRIBUTION_FILE_EMPTY' -Context @{ Path = $Path })
    }
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) }
    catch {
        throw (New-DistributionError -Message ("File is not valid JSON: {0} ({1})" -f $Path, $_.Exception.Message) `
            -ErrorCode 'DISTRIBUTION_JSON_INVALID' -Context @{ Path = $Path })
    }
}


# ---------------------------------------------------------------------------
# Publishing (Parts A / AA / AB)
# ---------------------------------------------------------------------------

function New-DevSetupPackage {
<#
.SYNOPSIS
    Materialises one version under packages/<version>/ in a distribution tree.

.DESCRIPTION
    Copies the given source directories into packages/<version>/content, writes
    SHA256SUMS.txt over them and then manifest.json describing both.

    Nothing here talks to git. The caller decides whether the resulting tree is
    a real checkout that gets committed or a scratch directory in a test.

.PARAMETER SourcePaths
    Directories to include. Each is copied as a top-level folder under content/.

.PARAMETER DistributionRoot
    Root of the distribution working tree (the orphan branch checkout).

.OUTPUTS
    PSCustomObject with Version, PackageDir, ContentDir, ManifestPath,
    ChecksumPath, FileCount and ChecksumsSha256.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $DistributionRoot,
        [Parameter(Mandatory = $true)][string] $Version,
        [Parameter(Mandatory = $true)][string[]] $SourcePaths,
        [Parameter()][string] $Channel = 'stable',
        [Parameter()][string] $MinimumBootstrapVersion = '1.0.0',
        [Parameter()][switch] $Force
    )

    $versionText = (ConvertTo-DevSetupVersion -Version $Version).ToString()
    $layout = Get-DevSetupDistributionLayout

    $packageDir = Join-Path (Join-Path $DistributionRoot $layout.PackagesDir) $versionText
    $contentDir = Join-Path $packageDir $layout.ContentDirName

    # Immutability guard (Part A): a published version is never rewritten.
    if ((Test-Path -LiteralPath $packageDir -PathType Container) -and -not $Force) {
        throw (New-DistributionError `
            -Message ("Version {0} is already published. Published versions are immutable - publish a new SemVer version instead." -f $versionText) `
            -ErrorCode 'DISTRIBUTION_VERSION_EXISTS' `
            -Context @{ Version = $versionText; PackageDir = $packageDir })
    }

    if (-not $PSCmdlet.ShouldProcess($packageDir, ("Publish DevSetup {0}" -f $versionText))) {
        return [pscustomobject]@{ Version = $versionText; PackageDir = $packageDir; Created = $false }
    }

    if (Test-Path -LiteralPath $packageDir) { Remove-Item -LiteralPath $packageDir -Recurse -Force }
    New-Item -ItemType Directory -Path $contentDir -Force | Out-Null

    foreach ($source in $SourcePaths) {
        if (-not (Test-Path -LiteralPath $source -PathType Container)) {
            throw (New-DistributionError -Message ("Source directory not found: {0}" -f $source) `
                -ErrorCode 'DISTRIBUTION_SOURCE_MISSING' -Context @{ Path = $source })
        }
        $name = Split-Path -Path (Resolve-Path -LiteralPath $source).Path -Leaf
        Copy-Item -LiteralPath (Resolve-Path -LiteralPath $source).Path `
                  -Destination (Join-Path $contentDir $name) -Recurse -Force
    }

    $checksumPath = Join-Path $packageDir $layout.ChecksumFileName
    $checksums = New-DevSetupChecksumFile -ContentPath $contentDir -OutputPath $checksumPath -Confirm:$false

    if ($checksums.FileCount -lt 1) {
        Remove-Item -LiteralPath $packageDir -Recurse -Force -ErrorAction SilentlyContinue
        throw (New-DistributionError -Message 'Refusing to publish an empty package.' `
            -ErrorCode 'DISTRIBUTION_PACKAGE_EMPTY' -Context @{ Version = $versionText })
    }

    $manifest = [ordered]@{
        schemaVersion           = $layout.SchemaVersion
        product                 = $layout.Product
        version                 = $versionText
        contentPath             = $layout.ContentDirName
        checksums               = $layout.ChecksumFileName
        checksumsSha256         = $checksums.Sha256
        fileCount               = [int]$checksums.FileCount
        channel                 = $Channel
        minimumBootstrapVersion = $MinimumBootstrapVersion
        publishedUtc            = (Get-Date).ToUniversalTime().ToString('o')
    }
    $manifestPath = Join-Path $packageDir $layout.ManifestName
    Set-Content -LiteralPath $manifestPath -Value ($manifest | ConvertTo-Json -Depth 6) -Encoding UTF8

    [pscustomobject]@{
        Version         = $versionText
        PackageDir      = $packageDir
        ContentDir      = $contentDir
        ManifestPath    = $manifestPath
        ChecksumPath    = $checksumPath
        FileCount       = [int]$checksums.FileCount
        ChecksumsSha256 = $checksums.Sha256
        Created         = $true
    }
}

function Test-DevSetupPublishedPackage {
<#
.SYNOPSIS
    Verifies a published version end to end: manifest, checksum list, files.

.DESCRIPTION
    This is the same validation the client bootstrap performs, run on the
    publisher side so a broken release never reaches the branch.

.OUTPUTS
    PSCustomObject with IsValid, Errors, Manifest and Checksums.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $DistributionRoot,
        [Parameter(Mandatory = $true)][string] $Version
    )

    $layout = Get-DevSetupDistributionLayout
    $errors = New-Object System.Collections.Generic.List[string]
    $packageDir = Join-Path (Join-Path $DistributionRoot $layout.PackagesDir) $Version

    if (-not (Test-Path -LiteralPath $packageDir -PathType Container)) {
        return [pscustomobject]@{ IsValid = $false; Errors = @("Package directory not found: $packageDir"); Manifest = $null; Checksums = $null }
    }

    $manifest = Read-DevSetupJsonFile -Path (Join-Path $packageDir $layout.ManifestName)
    $manifestCheck = Test-DevSetupPackageManifest -Manifest $manifest -ExpectedVersion $Version
    foreach ($e in $manifestCheck.Errors) { $errors.Add($e) }
    if (-not $manifestCheck.IsValid) {
        return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray(); Manifest = $manifest; Checksums = $null }
    }

    # The manifest pins the checksum list, so tampering with the list itself is
    # detected before any file hash is trusted.
    $checksumPath = Join-Path $packageDir $manifest.checksums
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        $errors.Add("Checksum file not found: $checksumPath")
        return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray(); Manifest = $manifest; Checksums = $null }
    }
    $listText = Get-Content -LiteralPath $checksumPath -Raw -Encoding UTF8
    if ($null -eq $listText) { $listText = '' }
    $listHash = Get-DevSetupTextSha256 -Text $listText
    if ($listHash -ne $manifest.checksumsSha256) {
        $errors.Add("SHA256SUMS.txt does not match checksumsSha256 in the manifest (expected $($manifest.checksumsSha256), got $listHash).")
    }

    $checksums = Test-DevSetupChecksumFile -ContentPath (Join-Path $packageDir $manifest.contentPath) -ChecksumPath $checksumPath
    foreach ($f in $checksums.Mismatched) { $errors.Add("Checksum mismatch: $f") }
    foreach ($f in $checksums.Missing)    { $errors.Add("File listed but missing: $f") }
    foreach ($f in $checksums.Unexpected) { $errors.Add("File present but not listed: $f") }

    if ([int]$manifest.fileCount -ne ($checksums.Verified + $checksums.Mismatched.Count + $checksums.Missing.Count)) {
        $errors.Add("fileCount in the manifest does not match SHA256SUMS.txt.")
    }

    [pscustomobject]@{
        IsValid   = ($errors.Count -eq 0)
        Errors    = $errors.ToArray()
        Manifest  = $manifest
        Checksums = $checksums
    }
}

function Set-DevSetupChannel {
<#
.SYNOPSIS
    Points a channel at an already-published version (Part AB).

.DESCRIPTION
    Promotion never rebuilds: a version is published once, then stable.json or
    pilot.json is repointed at it. The target must already exist and validate,
    so a channel can never name a package that is missing or corrupt.

.PARAMETER Force
    Writes force=true into the channel, meaning clients must not fall back to
    an older local version when offline.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $DistributionRoot,
        [Parameter(Mandatory = $true)][ValidateSet('stable', 'pilot')][string] $Channel,
        [Parameter(Mandatory = $true)][string] $Version,
        [Parameter()][string] $MinimumSupportedVersion,
        [Parameter()][switch] $Force
    )

    $layout = Get-DevSetupDistributionLayout
    $versionText = (ConvertTo-DevSetupVersion -Version $Version).ToString()

    $verify = Test-DevSetupPublishedPackage -DistributionRoot $DistributionRoot -Version $versionText
    if (-not $verify.IsValid) {
        throw (New-DistributionError `
            -Message ("Refusing to point channel '{0}' at {1}: {2}" -f $Channel, $versionText, ($verify.Errors -join '; ')) `
            -ErrorCode 'DISTRIBUTION_PROMOTION_INVALID' `
            -Context @{ Channel = $Channel; Version = $versionText })
    }

    $channelDir = Join-Path $DistributionRoot $layout.ChannelsDir
    $channelPath = Join-Path $channelDir ("{0}.json" -f $Channel)

    if (-not $MinimumSupportedVersion) {
        # Keep whatever the channel already declared; only fall back to the
        # published version on a brand-new channel.
        if (Test-Path -LiteralPath $channelPath -PathType Leaf) {
            $existing = Read-DevSetupJsonFile -Path $channelPath
            $MinimumSupportedVersion = [string]$existing.minimumSupportedVersion
        }
        if (-not (Test-DevSetupVersionString -Version $MinimumSupportedVersion)) { $MinimumSupportedVersion = $versionText }
    }
    $minText = (ConvertTo-DevSetupVersion -Version $MinimumSupportedVersion).ToString()
    if ((ConvertTo-DevSetupVersion -Version $minText) -gt (ConvertTo-DevSetupVersion -Version $versionText)) {
        throw (New-DistributionError `
            -Message ("minimumSupportedVersion {0} is greater than the channel version {1}." -f $minText, $versionText) `
            -ErrorCode 'DISTRIBUTION_CHANNEL_INVALID' -Context @{ Channel = $Channel })
    }

    $manifest = [ordered]@{
        schemaVersion           = $layout.SchemaVersion
        product                 = $layout.Product
        channel                 = $Channel
        version                 = $versionText
        manifest                = ('{0}/{1}/{2}' -f $layout.PackagesDir, $versionText, $layout.ManifestName)
        minimumSupportedVersion = $minText
        force                   = [bool]$Force
        publishedUtc            = (Get-Date).ToUniversalTime().ToString('o')
    }

    $check = Test-DevSetupChannelManifest -Manifest ([pscustomobject]$manifest)
    if (-not $check.IsValid) {
        throw (New-DistributionError -Message ("Generated channel manifest is invalid: {0}" -f ($check.Errors -join '; ')) `
            -ErrorCode 'DISTRIBUTION_CHANNEL_INVALID' -Context @{ Channel = $Channel })
    }

    if (-not $PSCmdlet.ShouldProcess($channelPath, ("Point channel '{0}' at {1}" -f $Channel, $versionText))) {
        return [pscustomobject]@{ Channel = $Channel; Version = $versionText; Path = $channelPath; Changed = $false }
    }

    if (-not (Test-Path -LiteralPath $channelDir -PathType Container)) {
        New-Item -ItemType Directory -Path $channelDir -Force | Out-Null
    }
    Set-Content -LiteralPath $channelPath -Value ($manifest | ConvertTo-Json -Depth 6) -Encoding UTF8

    [pscustomobject]@{ Channel = $Channel; Version = $versionText; Path = $channelPath; Changed = $true }
}

function Get-DevSetupChannel {
<#
.SYNOPSIS
    Reads and validates a channel manifest from a distribution tree.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $DistributionRoot,
        [Parameter(Mandatory = $true)][string] $Channel
    )

    $layout = Get-DevSetupDistributionLayout
    $path = Join-Path (Join-Path $DistributionRoot $layout.ChannelsDir) ("{0}.json" -f $Channel)
    $manifest = Read-DevSetupJsonFile -Path $path

    $check = Test-DevSetupChannelManifest -Manifest $manifest
    if (-not $check.IsValid) {
        throw (New-DistributionError -Message ("Channel '{0}' is invalid: {1}" -f $Channel, ($check.Errors -join '; ')) `
            -ErrorCode 'DISTRIBUTION_CHANNEL_INVALID' -Context @{ Channel = $Channel; Path = $path })
    }
    return $manifest
}

function Get-DevSetupPublishedVersion {
<#
.SYNOPSIS
    Lists every published version in a distribution tree, newest first.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string] $DistributionRoot)

    $layout = Get-DevSetupDistributionLayout
    $packagesDir = Join-Path $DistributionRoot $layout.PackagesDir
    if (-not (Test-Path -LiteralPath $packagesDir -PathType Container)) { return @() }

    $versions = Get-ChildItem -LiteralPath $packagesDir -Directory |
        Where-Object { Test-DevSetupVersionString -Version $_.Name } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { $_.Name }
    return @($versions)
}


Export-ModuleMember -Function `
    Get-DevSetupDistributionLayout, `
    Test-DevSetupVersionString, `
    ConvertTo-DevSetupVersion, `
    New-DevSetupChecksumFile, `
    Test-DevSetupChecksumFile, `
    Get-DevSetupTextSha256, `
    Test-DevSetupManifestObject, `
    Test-DevSetupChannelManifest, `
    Test-DevSetupPackageManifest, `
    Read-DevSetupJsonFile, `
    New-DevSetupPackage, `
    Test-DevSetupPublishedPackage, `
    Set-DevSetupChannel, `
    Get-DevSetupChannel, `
    Get-DevSetupPublishedVersion
