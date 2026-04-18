#Requires -Version 5.1
# =============================================================================
# Module  : CodeSigning.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Modular code-signing helpers for executables (DigiCertUtil.exe).

.DESCRIPTION
    Provides:
      - Set-CodeSignerDefaults / Get-CodeSignerDefaults: session-wide defaults for DigiCertUtil path and mode.
      - Sign-ExeViaDigiCert: sign one or many executables (simple global entry point).
      - Invoke-CodeSigner: low-level DigiCertUtil.exe invoker.
      - Sign-Files: batch-first then per-file fallback with optional verification.
      - Get-ExecutableTargets, Sign-VenvScripts, Sign-PoetryShim: convenience helpers.

    Depends on:
      - UI.psm1 (Write-Banner)
      - NativeCommand.psm1 (Invoke-NativeCommand)
#>

# Bring in shared helpers (Document: "UI.psm1", "NativeCommand.psm1")
$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'UI.psm1') -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'NativeCommand.psm1') -Force -DisableNameChecking -ErrorAction Stop

# Session-wide defaults for the signer
$script:CodeSignerDefaults = @{
    DigiCertUtilityExe   = $null
    KernelDriverSigning  = $false
}

<#
.SYNOPSIS
    Sets session-wide defaults for DigiCert signing.

.PARAMETER DigiCertUtilityExe
    Full path to DigiCertUtil.exe.

.PARAMETER KernelDriverSigning
    Default: $false (normal code signing). Set $true if you need /kernelDriverSigning by default.
#>
function Set-CodeSignerDefaults {
    param(
        [Parameter(Mandatory=$true)][string] $DigiCertUtilityExe,
        [bool] $KernelDriverSigning = $false
    )
    $normalizedExe = [System.IO.Path]::GetFullPath($DigiCertUtilityExe)
    if (-not (Test-Path -LiteralPath $normalizedExe -PathType Leaf)) {
        throw ("DigiCert Utility not found at: {0}" -f $normalizedExe)
    }
    $resolved = $normalizedExe
    $script:CodeSignerDefaults.DigiCertUtilityExe  = $resolved
    $script:CodeSignerDefaults.KernelDriverSigning = $KernelDriverSigning
}

<#
.SYNOPSIS
    Gets the current session-wide DigiCert signing defaults.

.OUTPUTS
    PSCustomObject with DigiCertUtilityExe and KernelDriverSigning.
#>
function Get-CodeSignerDefaults {
    [pscustomobject]@{
        DigiCertUtilityExe  = $script:CodeSignerDefaults.DigiCertUtilityExe
        KernelDriverSigning = $script:CodeSignerDefaults.KernelDriverSigning
    }
}

<#
.SYNOPSIS
    Executes DigiCertUtil.exe sign for one or many files.

.DESCRIPTION
    Builds the special single-argument file list separated by '*' per DigiCertUtil.exe requirements
    and invokes the signer via Invoke-NativeCommand. Does not perform fallback or file discovery.

.PARAMETER DigiCertUtilityExe
    Full path to DigiCertUtil.exe.

.PARAMETER Files
    One or more file paths to sign.

.PARAMETER KernelDriverSigning
    When specified, adds /kernelDriverSigning to the signer arguments.

.PARAMETER Quiet
    Suppress mirrored stdout/stderr from the signer.

.OUTPUTS
    PSCustomObject with ExitCode, Succeeded, StdOut, StdErr, ErrorText.
#>
function Invoke-CodeSigner {
    param(
        [Parameter(Mandatory=$true)][string]   $DigiCertUtilityExe,
        [Parameter(Mandatory=$true)][string[]] $Files,
        [switch] $KernelDriverSigning,
        [switch] $Quiet
    )

    if (-not (Test-Path -LiteralPath $DigiCertUtilityExe -PathType Leaf)) {
        throw ("DigiCert Utility not found at: {0}" -f $DigiCertUtilityExe)
    }

    $existing = @($Files | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique)
    if ($existing.Count -eq 0) {
        return [pscustomobject]@{
            ExitCode  = 0
            Succeeded = $true
            StdOut    = ''
            StdErr    = ''
            ErrorText = $null
        }
    }

    $fileList = ($existing | ForEach-Object { (Resolve-Path -LiteralPath $_).Path }) -join '*'
    $args = @('sign', '/noInput')
    if ($KernelDriverSigning) { $args += '/kernelDriverSigning' }
    $args += $fileList

    if (-not $Quiet) {
        $cmdLine = ('"{0}" {1}' -f $DigiCertUtilityExe, ($args -join ' '))
        Write-Host ("Executing DigiCert command: {0}" -f $cmdLine) -ForegroundColor DarkCyan
    }

    Invoke-NativeCommand -Executable $DigiCertUtilityExe -Arguments $args -Quiet:$Quiet
}

<#
.SYNOPSIS
    Signs a set of files with batch-first then per-file fallback.

.PARAMETER DigiCertUtilityExe
    Full path to DigiCertUtil.exe. Optional - falls back to the value set via
    Set-CodeSignerDefaults.

.PARAMETER Files
    Paths to files to sign.

.PARAMETER KernelDriverSigning
    Include /kernelDriverSigning in the signer arguments (default: $false).
    Only enable this when signing actual kernel drivers, not regular .exe files.

.PARAMETER Verify
    If set, validates signatures with Get-AuthenticodeSignature and treats non-Valid as failure.

.OUTPUTS
    PSCustomObject with Total, Signed, Failed.
#>
function Sign-Files {
    param(
        [string]   $DigiCertUtilityExe,
        [Parameter(Mandatory=$true)][string[]] $Files,
        [bool]   $KernelDriverSigning = $false,
        [switch] $Verify,
        [switch] $Quiet
    )

    if (-not $DigiCertUtilityExe) { $DigiCertUtilityExe = $script:CodeSignerDefaults.DigiCertUtilityExe }
    if (-not $DigiCertUtilityExe) {
        throw 'DigiCertUtilityExe not provided and no default set. Call Set-CodeSignerDefaults first or pass -DigiCertUtilityExe.'
    }

    $targets = $Files | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique
    $targets = @($targets)
    if ($targets.Count -eq 0) {
        Write-Host 'No files to sign.' -ForegroundColor Yellow
        return [pscustomobject]@{ Total = 0; Signed = 0; Failed = @() }
    }

    Write-Host ("Signing {0} file(s) ..." -f $targets.Count) -ForegroundColor Cyan
    if (-not $Quiet) {
        foreach ($t in $targets) {
            Write-Host ("  -> {0}" -f $t) -ForegroundColor DarkGray
        }
    }

    $failures = New-Object System.Collections.ArrayList
    $signed   = 0

    try {
        $batch = Invoke-CodeSigner -DigiCertUtilityExe $DigiCertUtilityExe -Files $targets -KernelDriverSigning:$KernelDriverSigning -Quiet:$Quiet
        if ($batch.Succeeded) {
            $signed = $targets.Count
            if (-not $Quiet) {
                Write-Host 'Batch signing reported success.' -ForegroundColor Green
            }
        } else {
            Write-Banner ("Batch signing failed (ExitCode {0}). Falling back to per-file signing ..." -f $batch.ExitCode) 'WARN'
            foreach ($f in $targets) {
                try {
                    $single = Invoke-CodeSigner -DigiCertUtilityExe $DigiCertUtilityExe -Files @($f) -KernelDriverSigning:$KernelDriverSigning -Quiet:$Quiet
                    if (-not $single.Succeeded) {
                        Write-Host ("Signing failed (ExitCode {0}): {1}" -f $single.ExitCode, $f) -ForegroundColor Red
                        [void]$failures.Add($f)
                        continue
                    }
                    if ($Verify) {
                        $sig = Get-AuthenticodeSignature -FilePath $f
                        if ($sig.Status -ne 'Valid') {
                            Write-Host ("Signature verification failed ({0}): {1}" -f $sig.Status, $f) -ForegroundColor Red
                            [void]$failures.Add($f)
                            continue
                        }
                    }
                    Write-Host ("Signed: {0}" -f (Split-Path $f -Leaf)) -ForegroundColor Green
                    $signed++
                } catch {
                    Write-Host ("Signing threw exception: {0} -> {1}" -f $f, $_.Exception.Message) -ForegroundColor Red
                    [void]$failures.Add($f)
                }
            }
        }
    } catch {
        Write-Banner ("Signing threw exception: {0}" -f $_.Exception.Message) 'ERROR'
        foreach ($f in $targets) { [void]$failures.Add($f) }
    }

    if ($failures.Count -gt 0) {
        Write-Banner ("Some files failed to sign ({0}/{1} failed)." -f $failures.Count, $targets.Count) 'WARN'
    } else {
        Write-Banner "All files signed successfully." 'SUCCESS'
    }

    [pscustomobject]@{
        Total  = $targets.Count
        Signed = $signed
        Failed = @($failures)
    }
}

<#
.SYNOPSIS
    Simple global entry point to sign one or many executables via DigiCert.

.DESCRIPTION
    Uses session defaults if DigiCertUtilityExe is not passed explicitly.
    Batch-signs and falls back to per-file to isolate failures. Optionally verifies Authenticode.

.PARAMETER Path
    One or more executable file paths to sign.

.PARAMETER DigiCertUtilityExe
    Full path to DigiCertUtil.exe. If omitted, uses Set-CodeSignerDefaults value.

.PARAMETER KernelDriverSigning
    Overrides default. If omitted, uses Set-CodeSignerDefaults value.

.PARAMETER Verify
    Verify Authenticode signature after signing.

.PARAMETER Quiet
    Suppress signer output (still reports summary).
#>
function Sign-ExeViaDigiCert {
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)][string[]] $Path,
        [string] $DigiCertUtilityExe,
        [AllowNull()][object] $KernelDriverSigning = $null,
        [switch] $Verify,
        [switch] $Quiet
    )
    begin {
        $buffer = New-Object System.Collections.Generic.List[string]
    }
    process {
        foreach ($p in $Path) { if ($p) { $buffer.Add($p) } }
    }
    end {
        $exe = $DigiCertUtilityExe
        if (-not $exe) { $exe = $script:CodeSignerDefaults.DigiCertUtilityExe }
        if (-not $exe) { throw 'DigiCertUtilityExe not provided and no default set. Call Set-CodeSignerDefaults first or pass -DigiCertUtilityExe.' }

        $kds = [bool]$script:CodeSignerDefaults.KernelDriverSigning
        if ($null -ne $KernelDriverSigning) {
            $kds = [bool]$KernelDriverSigning
        }

        $files = @($buffer)
        if ($files.Count -eq 0) {
            Write-Host 'No files to sign.' -ForegroundColor Yellow
            return [pscustomobject]@{ Total = 0; Signed = 0; Failed = @() }
        }

        Sign-Files -DigiCertUtilityExe $exe -Files $files -KernelDriverSigning:$kds -Verify:$Verify -Quiet:$Quiet
    }
}

<#
.SYNOPSIS
    Discovers signable files (*.exe and optionally *.dll) under a directory.

.PARAMETER IncludeDlls
    Also collect *.dll files alongside *.exe. DigiCert can sign both.
#>
function Get-ExecutableTargets {
    param(
        [Parameter(Mandatory=$true)][string] $Root,
        [string[]] $IncludeNames,
        [bool]   $Recurse    = $true,
        [switch] $IncludeDlls
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
        $nameSet = $IncludeNames | ForEach-Object { $_.ToLowerInvariant() }
        $items = $items | Where-Object { $nameSet -contains $_.Name.ToLowerInvariant() }
    }
    @($items | Select-Object -ExpandProperty FullName -Unique)
}

<#
.SYNOPSIS
    Signs executables under .venv\Scripts (optionally a subset by name).

.PARAMETER DigiCertUtilityExe
    Optional. Falls back to the value from Set-CodeSignerDefaults.

.PARAMETER KernelDriverSigning
    Default: $false. Only set when signing actual kernel drivers.
#>
function Sign-VenvScripts {
    param(
        [Parameter(Mandatory=$true)][string] $VenvDir,
        [string] $DigiCertUtilityExe,
        [bool] $KernelDriverSigning = $false,
        [string[]] $IncludeNames,
        [switch] $PoetryOnly,
        [switch] $Verify,
        [switch] $Quiet
    )

    if (-not $DigiCertUtilityExe) { $DigiCertUtilityExe = $script:CodeSignerDefaults.DigiCertUtilityExe }
    if (-not $DigiCertUtilityExe) {
        throw 'DigiCertUtilityExe not provided and no default set. Call Set-CodeSignerDefaults first or pass -DigiCertUtilityExe.'
    }

    if (-not (Test-Path -LiteralPath $VenvDir -PathType Container)) {
        Write-Banner ("Venv not found at: {0}" -f $VenvDir) 'ERROR'
        return [pscustomobject]@{ Total = 0; Signed = 0; Failed = @() }
    }

    $scriptsDir = [System.IO.Path]::GetFullPath((Join-Path $VenvDir 'Scripts'))
    if (-not (Test-Path -LiteralPath $scriptsDir -PathType Container)) {
        Write-Banner ("Scripts folder not found at: {0}" -f $scriptsDir) 'ERROR'
        return [pscustomobject]@{ Total = 0; Signed = 0; Failed = @() }
    }

    $names = $IncludeNames
    if ($PoetryOnly) { $names = @('poetry.exe') }

    $targets = Get-ExecutableTargets -Root $scriptsDir -IncludeNames $names -Recurse:$true
    $targets = @($targets)
    if ($targets.Count -eq 0) {
        Write-Host ("No {0} found under: {1}" -f ($(if ($names) { ($names -join ',') } else { '*.exe' }), $scriptsDir) ) -ForegroundColor Yellow
        return [pscustomobject]@{ Total = 0; Signed = 0; Failed = @() }
    }

    if ($KernelDriverSigning) {
        Write-Host "Signing mode: Kernel driver signing (/kernelDriverSigning)" -ForegroundColor Yellow
    } else {
        Write-Host "Signing mode: Normal code signing" -ForegroundColor Yellow
    }

    Sign-Files -DigiCertUtilityExe $DigiCertUtilityExe -Files $targets -KernelDriverSigning:$KernelDriverSigning -Verify:$Verify -Quiet:$Quiet
}

<#
.SYNOPSIS
    Signs the Poetry CLI shim (poetry.exe) installed by the official installer.

.DESCRIPTION
    Requires the caller to pass an explicit -ShimPath. This keeps CodeSigning
    ignorant of Poetry's layout (which differs between Poetry 1.2+ and
    legacy installs); the orchestrator should resolve the shim via
    Get-PoetryShimPath from Poetry.psm1 and pass the result here.

.PARAMETER ShimPath
    Absolute path to poetry.exe. If missing or the file does not exist,
    the function warns and no-ops (returns an empty result).

.PARAMETER DigiCertUtilityExe
    Optional. Falls back to the value from Set-CodeSignerDefaults.

.PARAMETER KernelDriverSigning
    Default: $false. Kernel driver signing is wrong for a Python CLI shim.
#>
function Sign-PoetryShim {
    param(
        [string] $ShimPath,
        [string] $DigiCertUtilityExe,
        [bool] $KernelDriverSigning = $false,
        [switch] $Verify,
        [switch] $Quiet
    )

    if (-not $ShimPath) {
        Write-Banner 'Sign-PoetryShim called without -ShimPath; nothing to sign.' 'WARN'
        return [pscustomobject]@{ Total = 0; Signed = 0; Failed = @() }
    }

    if (-not (Test-Path -LiteralPath $ShimPath -PathType Leaf)) {
        Write-Banner ("poetry.exe not found at: {0} -- skipping shim signing." -f $ShimPath) 'WARN'
        return [pscustomobject]@{ Total = 0; Signed = 0; Failed = @() }
    }

    if (-not $DigiCertUtilityExe) { $DigiCertUtilityExe = $script:CodeSignerDefaults.DigiCertUtilityExe }

    Sign-ExeViaDigiCert -Path $ShimPath -DigiCertUtilityExe $DigiCertUtilityExe -KernelDriverSigning:$KernelDriverSigning -Verify:$Verify -Quiet:$Quiet
}

Export-ModuleMember -Function `
    Set-CodeSignerDefaults, `
    Get-CodeSignerDefaults, `
    Invoke-CodeSigner, `
    Sign-Files, `
    Sign-ExeViaDigiCert, `
    Get-ExecutableTargets, `
    Sign-VenvScripts, `
    Sign-PoetryShim