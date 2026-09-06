#Requires -Version 5.1
# =============================================================================
# Module  : CodeSigning.psm1
# Purpose : Idempotent DigiCert-backed Authenticode signing helpers.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Modular code-signing helpers for executables and DLLs.

.DESCRIPTION
    Signing is intentionally idempotent. Before DigiCert is invoked, every
    target is inspected with Get-AuthenticodeSignature.

    Files whose Authenticode status is already Valid are preserved and skipped.
    New, unsigned, changed, hash-mismatched, or otherwise non-valid files are
    sent to DigiCert. This prevents every setup/update run from re-signing an
    already healthy .venv.

    A valid third-party/vendor signature is also preserved. This is deliberate:
    the setup automation must not replace a valid upstream signature merely to
    stamp the file again. If a future policy requires a specific company signer,
    that should be implemented as an explicit signer-thumbprint policy.
#>

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'UI.psm1') -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'NativeCommand.psm1') -Force -DisableNameChecking -ErrorAction Stop

$script:CodeSignerDefaults = @{
    DigiCertUtilityExe  = $null
    KernelDriverSigning = $false
}

function New-CodeSigningResult {
    param(
        [int] $Total = 0,
        [int] $Signed = 0,
        [int] $NewlySigned = 0,
        [int] $Skipped = 0,
        [string[]] $SkippedFiles = @(),
        [string[]] $Failed = @(),
        [int] $Pending = 0,
        [bool] $ForceResign = $false
    )

    [pscustomobject]@{
        # Backward-compatible meaning for existing callers:
        # Signed = files that are in a valid signed state after this operation.
        Total        = $Total
        Signed       = $Signed
        NewlySigned  = $NewlySigned
        Skipped      = $Skipped
        SkippedFiles = @($SkippedFiles)
        Failed       = @($Failed)
        Pending      = $Pending
        ForceResign  = $ForceResign
    }
}

function Set-CodeSignerDefaults {
<#
.SYNOPSIS
    Sets session-wide defaults for DigiCert signing.

.EXAMPLE
    Set-CodeSignerDefaults -DigiCertUtilityExe $env:DIGICERT_UTILITY_EXE
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $DigiCertUtilityExe,

        [bool] $KernelDriverSigning = $false
    )

    $normalizedExe = [System.IO.Path]::GetFullPath($DigiCertUtilityExe)
    if (-not (Test-Path -LiteralPath $normalizedExe -PathType Leaf)) {
        throw ("DigiCert Utility not found at: {0}" -f $normalizedExe)
    }

    $script:CodeSignerDefaults.DigiCertUtilityExe  = $normalizedExe
    $script:CodeSignerDefaults.KernelDriverSigning = $KernelDriverSigning
}

function Get-CodeSignerDefaults {
<#
.SYNOPSIS
    Gets the current session-wide DigiCert signing defaults.
#>
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        DigiCertUtilityExe  = $script:CodeSignerDefaults.DigiCertUtilityExe
        KernelDriverSigning = $script:CodeSignerDefaults.KernelDriverSigning
    }
}

function Get-CodeSignatureState {
<#
.SYNOPSIS
    Inspects the current Authenticode state of one file.

.DESCRIPTION
    A file is considered reusable when Get-AuthenticodeSignature returns
    Status=Valid. Any other status means the file is a candidate for signing.
    Inspection errors are treated as non-valid so the caller can attempt a
    repair/sign operation instead of silently skipping the file.

.EXAMPLE
    Get-CodeSignatureState -FilePath '.\.venv\Scripts\tool.exe'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Signature target does not exist: $FilePath"
    }

    $resolved = (Resolve-Path -LiteralPath $FilePath).Path

    try {
        $sig = Get-AuthenticodeSignature -FilePath $resolved -ErrorAction Stop
        $status = [string]$sig.Status

        return [pscustomobject]@{
            Path                   = $resolved
            Status                 = $status
            IsValid                = ($status -eq 'Valid')
            StatusMessage          = [string]$sig.StatusMessage
            SignerCertificate      = $sig.SignerCertificate
            TimeStamperCertificate = $sig.TimeStamperCertificate
            InspectionError        = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Path                   = $resolved
            Status                 = 'InspectionError'
            IsValid                = $false
            StatusMessage          = $_.Exception.Message
            SignerCertificate      = $null
            TimeStamperCertificate = $null
            InspectionError        = $_.Exception.Message
        }
    }
}

function Invoke-CodeSigner {
<#
.SYNOPSIS
    Executes DigiCertUtil.exe sign for one or many files.

.DESCRIPTION
    Low-level DigiCert invocation. Higher-level functions should normally call
    Set-CodeSignature so already-valid signatures are filtered first.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $DigiCertUtilityExe,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [string[]] $Files,

        [switch] $KernelDriverSigning,
        [switch] $Quiet
    )

    if (-not (Test-Path -LiteralPath $DigiCertUtilityExe -PathType Leaf)) {
        throw ("DigiCert Utility not found at: {0}" -f $DigiCertUtilityExe)
    }

    $existing = @(
        $Files |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            ForEach-Object { (Resolve-Path -LiteralPath $_).Path } |
            Select-Object -Unique
    )

    if ($existing.Count -eq 0) {
        return [pscustomobject]@{
            ExitCode  = 0
            Succeeded = $true
            StdOut    = ''
            StdErr    = ''
            ErrorText = $null
        }
    }

    $fileList = $existing -join '*'
    $args = @('sign', '/noInput')
    if ($KernelDriverSigning) { $args += '/kernelDriverSigning' }
    $args += $fileList

    if (-not $Quiet) {
        $cmdLine = ('"{0}" {1}' -f $DigiCertUtilityExe, ($args -join ' '))
        Write-Host ("Executing DigiCert command: {0}" -f $cmdLine) -ForegroundColor DarkCyan
    }

    Invoke-NativeCommand -Executable $DigiCertUtilityExe -Arguments $args -Quiet:$Quiet
}

function Set-CodeSignature {
<#
.SYNOPSIS
    Ensures a set of files has valid Authenticode signatures.

.DESCRIPTION
    This is the central idempotent signing function.

    1. Every file is inspected with Get-AuthenticodeSignature.
    2. Status=Valid files are skipped by default.
    3. Only unsigned/non-valid files are passed to DigiCert.
    4. Batch signing is attempted first, with per-file fallback on failure.
    5. -ForceResign bypasses the skip optimization when an explicit re-sign is
       required by an operator.

    If a previously signed file is modified, Authenticode validation no longer
    returns Valid, so it automatically becomes a signing candidate again.

.PARAMETER Verify
    Verify newly signed files with Get-AuthenticodeSignature after signing.

.PARAMETER ForceResign
    Explicitly re-sign files even when their current signature is Valid.

.OUTPUTS
    PSCustomObject with Total, Signed, NewlySigned, Skipped, SkippedFiles,
    Failed, Pending, and ForceResign.

.EXAMPLE
    Set-CodeSignature -Files $targets -Verify

.EXAMPLE
    Set-CodeSignature -Files $targets -ForceResign -Confirm
#>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        [string] $DigiCertUtilityExe,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [string[]] $Files,

        [bool] $KernelDriverSigning = $false,
        [switch] $Verify,
        [switch] $Quiet,
        [switch] $ForceResign
    )

    if (-not $DigiCertUtilityExe) {
        $DigiCertUtilityExe = $script:CodeSignerDefaults.DigiCertUtilityExe
    }
    if (-not $DigiCertUtilityExe) {
        throw 'DigiCertUtilityExe not provided and no default set. Call Set-CodeSignerDefaults first or pass -DigiCertUtilityExe.'
    }

    $targets = @(
        $Files |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            ForEach-Object { (Resolve-Path -LiteralPath $_).Path } |
            Select-Object -Unique
    )

    if ($targets.Count -eq 0) {
        Write-Host 'No files to sign.' -ForegroundColor Yellow
        return New-CodeSigningResult
    }

    $alreadyValid = New-Object System.Collections.Generic.List[string]
    $pending      = New-Object System.Collections.Generic.List[string]

    foreach ($target in $targets) {
        if ($ForceResign) {
            $pending.Add($target)
            continue
        }

        $state = Get-CodeSignatureState -FilePath $target
        if ($state.IsValid) {
            $alreadyValid.Add($target)
            if (-not $Quiet) {
                $subject = if ($state.SignerCertificate) { $state.SignerCertificate.Subject } else { '<unknown signer>' }
                Write-Host ("  [SKIP] Valid signature: {0} ({1})" -f (Split-Path $target -Leaf), $subject) -ForegroundColor DarkGreen
            }
        }
        else {
            $pending.Add($target)
            if (-not $Quiet) {
                Write-Host ("  [SIGN] {0} - signature status: {1}" -f (Split-Path $target -Leaf), $state.Status) -ForegroundColor DarkYellow
            }
        }
    }

    if ($pending.Count -eq 0) {
        if (-not $Quiet) {
            Write-Banner ("Signing skipped: all {0} target(s) already have valid Authenticode signatures." -f $targets.Count) 'SUCCESS'
        }

        return New-CodeSigningResult `
            -Total $targets.Count `
            -Signed $alreadyValid.Count `
            -NewlySigned 0 `
            -Skipped $alreadyValid.Count `
            -SkippedFiles @($alreadyValid) `
            -Pending 0 `
            -ForceResign ([bool]$ForceResign)
    }

    Write-Host ("Code-signing scan: total={0}, already-valid={1}, needs-signing={2}" -f $targets.Count, $alreadyValid.Count, $pending.Count) -ForegroundColor Cyan

    if (-not $PSCmdlet.ShouldProcess(("{0} file(s)" -f $pending.Count), 'Sign with DigiCert Utility')) {
        return New-CodeSigningResult `
            -Total $targets.Count `
            -Signed $alreadyValid.Count `
            -NewlySigned 0 `
            -Skipped $alreadyValid.Count `
            -SkippedFiles @($alreadyValid) `
            -Pending $pending.Count `
            -ForceResign ([bool]$ForceResign)
    }

    $failures   = New-Object System.Collections.Generic.List[string]
    $newlySigned = New-Object System.Collections.Generic.List[string]

    try {
        $batch = Invoke-CodeSigner `
            -DigiCertUtilityExe $DigiCertUtilityExe `
            -Files @($pending) `
            -KernelDriverSigning:$KernelDriverSigning `
            -Quiet:$Quiet

        if ($batch.Succeeded) {
            foreach ($file in @($pending)) {
                if ($Verify) {
                    $postState = Get-CodeSignatureState -FilePath $file
                    if (-not $postState.IsValid) {
                        Write-Host ("Signature verification failed ({0}): {1}" -f $postState.Status, $file) -ForegroundColor Red
                        $failures.Add($file)
                        continue
                    }
                }
                $newlySigned.Add($file)
            }

            if (-not $Quiet) {
                Write-Host ("Batch signing completed for {0} file(s)." -f $pending.Count) -ForegroundColor Green
            }
        }
        else {
            Write-Banner ("Batch signing failed (ExitCode {0}). Falling back to per-file signing ..." -f $batch.ExitCode) 'WARN'

            foreach ($file in @($pending)) {
                try {
                    $single = Invoke-CodeSigner `
                        -DigiCertUtilityExe $DigiCertUtilityExe `
                        -Files @($file) `
                        -KernelDriverSigning:$KernelDriverSigning `
                        -Quiet:$Quiet

                    if (-not $single.Succeeded) {
                        Write-Host ("Signing failed (ExitCode {0}): {1}" -f $single.ExitCode, $file) -ForegroundColor Red
                        $failures.Add($file)
                        continue
                    }

                    if ($Verify) {
                        $postState = Get-CodeSignatureState -FilePath $file
                        if (-not $postState.IsValid) {
                            Write-Host ("Signature verification failed ({0}): {1}" -f $postState.Status, $file) -ForegroundColor Red
                            $failures.Add($file)
                            continue
                        }
                    }

                    $newlySigned.Add($file)
                    if (-not $Quiet) {
                        Write-Host ("Signed: {0}" -f (Split-Path $file -Leaf)) -ForegroundColor Green
                    }
                }
                catch {
                    Write-Host ("Signing threw exception: {0} -> {1}" -f $file, $_.Exception.Message) -ForegroundColor Red
                    $failures.Add($file)
                }
            }
        }
    }
    catch {
        Write-Banner ("Signing threw exception: {0}" -f $_.Exception.Message) 'ERROR'
        foreach ($file in @($pending)) {
            if (-not $failures.Contains($file)) {
                $failures.Add($file)
            }
        }
    }

    $validAfter = $alreadyValid.Count + $newlySigned.Count

    if ($failures.Count -gt 0) {
        Write-Banner ("Signing completed with failures: valid={0}/{1}, newly-signed={2}, skipped-valid={3}, failed={4}." -f $validAfter, $targets.Count, $newlySigned.Count, $alreadyValid.Count, $failures.Count) 'WARN'
    }
    else {
        Write-Banner ("Signing state valid: total={0}, newly-signed={1}, skipped-valid={2}." -f $targets.Count, $newlySigned.Count, $alreadyValid.Count) 'SUCCESS'
    }

    New-CodeSigningResult `
        -Total $targets.Count `
        -Signed $validAfter `
        -NewlySigned $newlySigned.Count `
        -Skipped $alreadyValid.Count `
        -SkippedFiles @($alreadyValid) `
        -Failed @($failures) `
        -Pending 0 `
        -ForceResign ([bool]$ForceResign)
}

function Invoke-DigiCertSigning {
<#
.SYNOPSIS
    Ensures files or directory contents are validly Authenticode-signed.

.EXAMPLE
    Invoke-DigiCertSigning -Path '.\.venv\Scripts' -Verify
#>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [ValidateNotNull()]
        [string[]] $Path,

        [string] $DigiCertUtilityExe,
        [AllowNull()][object] $KernelDriverSigning = $null,
        [bool] $IncludeDlls = $true,
        [switch] $Verify,
        [switch] $Quiet,
        [switch] $ForceResign
    )

    begin {
        $buffer = New-Object System.Collections.Generic.List[string]
    }
    process {
        foreach ($item in $Path) {
            if ($item) { $buffer.Add($item) }
        }
    }
    end {
        $exe = $DigiCertUtilityExe
        if (-not $exe) { $exe = $script:CodeSignerDefaults.DigiCertUtilityExe }
        if (-not $exe) {
            throw 'DigiCertUtilityExe not provided and no default set. Call Set-CodeSignerDefaults first or pass -DigiCertUtilityExe.'
        }

        $kds = [bool]$script:CodeSignerDefaults.KernelDriverSigning
        if ($null -ne $KernelDriverSigning) {
            $kds = [bool]$KernelDriverSigning
        }

        $resolved = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($buffer)) {
            if (-not $item) { continue }

            if (Test-Path -LiteralPath $item -PathType Container) {
                foreach ($found in @(Get-ExecutableTargets -Root $item -IncludeDlls:$IncludeDlls -Recurse:$true)) {
                    $resolved.Add($found)
                }
                continue
            }

            if (Test-Path -LiteralPath $item -PathType Leaf) {
                $ext = [System.IO.Path]::GetExtension($item)
                $isExe = $ext -and $ext.Equals('.exe', [System.StringComparison]::OrdinalIgnoreCase)
                $isDll = $ext -and $ext.Equals('.dll', [System.StringComparison]::OrdinalIgnoreCase)
                if ($isExe -or ($IncludeDlls -and $isDll)) {
                    $resolved.Add((Resolve-Path -LiteralPath $item).Path)
                }
            }
        }

        $files = @($resolved | Select-Object -Unique)
        if ($files.Count -eq 0) {
            Write-Host 'No files to sign.' -ForegroundColor Yellow
            return New-CodeSigningResult
        }

        $params = @{
            DigiCertUtilityExe  = $exe
            Files               = $files
            KernelDriverSigning = $kds
            Verify              = [bool]$Verify
            Quiet               = [bool]$Quiet
            ForceResign         = [bool]$ForceResign
        }
        if ($PSBoundParameters.ContainsKey('WhatIf')) { $params.WhatIf = [bool]$WhatIfPreference }
        if ($PSBoundParameters.ContainsKey('Confirm')) { $params.Confirm = [bool]$PSBoundParameters['Confirm'] }

        Set-CodeSignature @params
    }
}

function Get-ExecutableTargets {
<#
.SYNOPSIS
    Discovers signable *.exe and optionally *.dll files below a directory.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [string[]] $IncludeNames,
        [bool] $Recurse = $true,
        [bool] $IncludeDlls = $true
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }

    $extensions = @('*.exe')
    if ($IncludeDlls) { $extensions += '*.dll' }

    $items = foreach ($ext in $extensions) {
        $params = @{ LiteralPath = $Root; File = $true; Filter = $ext }
        if ($Recurse) { $params.Recurse = $true }
        Get-ChildItem @params -ErrorAction SilentlyContinue
    }

    if ($IncludeNames -and @($IncludeNames).Count -gt 0) {
        $nameSet = @($IncludeNames | ForEach-Object { $_.ToLowerInvariant() })
        $items = $items | Where-Object { $nameSet -contains $_.Name.ToLowerInvariant() }
    }

    @($items | Select-Object -ExpandProperty FullName -Unique)
}

function Set-VenvScriptSignature {
<#
.SYNOPSIS
    Ensures executables/DLLs below .venv\Scripts have valid signatures.

.DESCRIPTION
    Existing Valid Authenticode signatures are skipped. This makes repeated
    setup and dependency-update runs cheap: only newly installed or changed
    binaries are sent to DigiCert.

.EXAMPLE
    Set-VenvScriptSignature -VenvDir '.\.venv' -Verify
#>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $VenvDir,

        [string] $DigiCertUtilityExe,
        [bool] $KernelDriverSigning = $false,
        [string[]] $IncludeNames,
        [switch] $PoetryOnly,
        [switch] $Verify,
        [switch] $Quiet,
        [bool] $IncludeDlls = $true,
        [switch] $ForceResign
    )

    if (-not $DigiCertUtilityExe) { $DigiCertUtilityExe = $script:CodeSignerDefaults.DigiCertUtilityExe }
    if (-not $DigiCertUtilityExe) {
        throw 'DigiCertUtilityExe not provided and no default set. Call Set-CodeSignerDefaults first or pass -DigiCertUtilityExe.'
    }

    if (-not (Test-Path -LiteralPath $VenvDir -PathType Container)) {
        Write-Banner ("Venv not found at: {0}" -f $VenvDir) 'ERROR'
        return New-CodeSigningResult
    }

    $scriptsDir = [System.IO.Path]::GetFullPath((Join-Path $VenvDir 'Scripts'))
    if (-not (Test-Path -LiteralPath $scriptsDir -PathType Container)) {
        Write-Banner ("Scripts folder not found at: {0}" -f $scriptsDir) 'ERROR'
        return New-CodeSigningResult
    }

    $names = $IncludeNames
    if ($PoetryOnly) { $names = @('poetry.exe') }

    $targets = @(Get-ExecutableTargets -Root $scriptsDir -IncludeNames $names -Recurse:$true -IncludeDlls:$IncludeDlls)
    if ($targets.Count -eq 0) {
        $pattern = if ($names) { ($names -join ',') } else { if ($IncludeDlls) { '*.exe,*.dll' } else { '*.exe' } }
        Write-Host ("No {0} found under: {1}" -f $pattern, $scriptsDir) -ForegroundColor Yellow
        return New-CodeSigningResult
    }

    if ($KernelDriverSigning) {
        Write-Host 'Signing mode: Kernel driver signing (/kernelDriverSigning)' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Signing mode: Normal code signing' -ForegroundColor Yellow
    }

    $params = @{
        DigiCertUtilityExe  = $DigiCertUtilityExe
        Files               = $targets
        KernelDriverSigning = $KernelDriverSigning
        Verify              = [bool]$Verify
        Quiet               = [bool]$Quiet
        ForceResign         = [bool]$ForceResign
    }
    if ($PSBoundParameters.ContainsKey('WhatIf')) { $params.WhatIf = [bool]$WhatIfPreference }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $params.Confirm = [bool]$PSBoundParameters['Confirm'] }

    Set-CodeSignature @params
}

function Set-PoetryShimSignature {
<#
.SYNOPSIS
    Ensures the package-manager CLI shim has a valid Authenticode signature.

.DESCRIPTION
    Despite the historic function name, callers may pass the resolved package
    manager shim path. A currently valid signature is accepted and skipped.

.EXAMPLE
    Set-PoetryShimSignature -ShimPath $poetryExe -Verify
#>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        [string] $ShimPath,
        [string] $DigiCertUtilityExe,
        [bool] $KernelDriverSigning = $false,
        [switch] $Verify,
        [switch] $Quiet,
        [switch] $ForceResign
    )

    if (-not $ShimPath) {
        Write-Banner 'Set-PoetryShimSignature called without -ShimPath; nothing to sign.' 'WARN'
        return New-CodeSigningResult
    }

    if (-not (Test-Path -LiteralPath $ShimPath -PathType Leaf)) {
        Write-Banner ("Package-manager shim not found at: {0} -- skipping shim signing." -f $ShimPath) 'WARN'
        return New-CodeSigningResult
    }

    if (-not $DigiCertUtilityExe) { $DigiCertUtilityExe = $script:CodeSignerDefaults.DigiCertUtilityExe }

    $params = @{
        Path                = @($ShimPath)
        DigiCertUtilityExe  = $DigiCertUtilityExe
        KernelDriverSigning = $KernelDriverSigning
        IncludeDlls         = $false
        Verify              = [bool]$Verify
        Quiet               = [bool]$Quiet
        ForceResign         = [bool]$ForceResign
    }
    if ($PSBoundParameters.ContainsKey('WhatIf')) { $params.WhatIf = [bool]$WhatIfPreference }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $params.Confirm = [bool]$PSBoundParameters['Confirm'] }

    Invoke-DigiCertSigning @params
}

# Backward-compatible aliases.
Set-Alias -Name 'Sign-Files'          -Value 'Set-CodeSignature'
Set-Alias -Name 'Sign-ExeViaDigiCert' -Value 'Invoke-DigiCertSigning'
Set-Alias -Name 'Sign-VenvScripts'    -Value 'Set-VenvScriptSignature'
Set-Alias -Name 'Sign-PoetryShim'     -Value 'Set-PoetryShimSignature'

Export-ModuleMember -Function `
    Set-CodeSignerDefaults, `
    Get-CodeSignerDefaults, `
    Get-CodeSignatureState, `
    Invoke-CodeSigner, `
    Set-CodeSignature, `
    Invoke-DigiCertSigning, `
    Get-ExecutableTargets, `
    Set-VenvScriptSignature, `
    Set-PoetryShimSignature `
    -Alias `
    'Sign-Files', `
    'Sign-ExeViaDigiCert', `
    'Sign-VenvScripts', `
    'Sign-PoetryShim'
