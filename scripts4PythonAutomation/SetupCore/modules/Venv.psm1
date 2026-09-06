#Requires -Version 5.1
# =============================================================================
# Module  : Venv.psm1
# Purpose : Virtual-environment lifecycle helpers with ShouldProcess support.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Constants.psm1')     -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'UI.psm1')            -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Filesystem.psm1')    -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Compat.psm1')        -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Versioning.psm1')    -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'NativeCommand.psm1') -Force -DisableNameChecking -ErrorAction Stop

function Remove-VenvIfExists {
<#
.SYNOPSIS
    Removes an existing .venv directory with robust fallback behavior.

.EXAMPLE
    Remove-VenvIfExists -VenvDir '.\.venv' -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string] $VenvDir,
        [bool] $NonInteractive = $false
    )

    if (-not (Test-Path -LiteralPath $VenvDir)) { return }
    if (-not $PSCmdlet.ShouldProcess($VenvDir, 'Remove existing virtual environment')) { return }

    $constants = Get-SetupConstants
    Stop-VenvProcesses -VenvDir $VenvDir -Confirm:$false
    $removed = Remove-PathRobust -Path $VenvDir -MaxRetry ([int]$constants.Retry.MaxRetry) -DelayMs ([int]$constants.Retry.DelayMs) -Confirm:$false
    if (-not $removed) {
        $q = Move-PathToQuarantine -Path $VenvDir -Confirm:$false
        if ($q) {
            Write-Banner ".venv quarantined to '$q' (will be removed when files are released)" 'WARN'
        } else {
            Exit-WithError -Message 'Could not remove or quarantine .venv - close any processes using it and retry.' -NonInteractive ([bool]$NonInteractive)
        }
    } else {
        Write-Banner '.venv removed.' 'SUCCESS'
    }
}

function Confirm-VenvExists {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string] $VenvDir)

    if (-not (Test-Path -LiteralPath $VenvDir -PathType Container)) {
        throw '.venv directory was not created. Check the package-manager output above.'
    }

    $requiredFiles = @(
        [System.IO.Path]::GetFullPath((Join-Path $VenvDir 'pyvenv.cfg')),
        [System.IO.Path]::GetFullPath((Join-Path $VenvDir 'Scripts\Activate.ps1')),
        [System.IO.Path]::GetFullPath((Join-Path $VenvDir 'Scripts\python.exe'))
    )
    $missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missing.Count -gt 0) {
        throw ('.venv exists but is incomplete. Missing required file(s): {0}' -f ($missing -join ', '))
    }
}

function Confirm-VenvPythonCompatible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string] $VenvDir,
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[hashtable]] $Constraints,
        [Parameter(Mandatory=$true)][string] $RequiresPythonRaw,
        [Parameter(Mandatory=$true)][object] $SelectedPython,
        [bool] $RequireSelectedPython = $false
    )

    if (-not (Test-Path -LiteralPath $VenvDir -PathType Container)) { return }
    $venvPython = Get-VenvPythonExe -VenvDir $VenvDir
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        throw (".venv exists but its Python executable is missing: {0}." -f $venvPython)
    }

    $probeCode = "import sys; print('{}.{}.{}'.format(*sys.version_info[:3])); print(getattr(sys, '_base_executable', '') or sys.executable)"
    $probe = Invoke-NativeCommand -Executable $venvPython -Arguments @('-c',$probeCode) -Quiet -NoLog
    if (-not $probe.Succeeded) {
        throw (".venv exists but its Python could not be started (exit {0}): {1}." -f $probe.ExitCode, $venvPython)
    }

    $lines = @($probe.StdOut -split "`r?`n" | Where-Object { $_ })
    if ($lines.Count -lt 1) { throw (".venv Python did not report a version: {0}." -f $venvPython) }

    try { $venvVersion = [Version]($lines[0].Trim()) }
    catch { throw (".venv Python reported an unparseable version '{0}'." -f $lines[0]) }

    if (-not (Test-VersionConstraints -Version $venvVersion -Constraints $Constraints)) {
        throw (".venv uses Python {0}, which does not satisfy requires-python '{1}'." -f $venvVersion, $RequiresPythonRaw)
    }

    if ($RequireSelectedPython -and $SelectedPython -and $SelectedPython.Version) {
        $selectedVersion = [Version]$SelectedPython.Version
        if ($venvVersion.Major -ne $selectedVersion.Major -or $venvVersion.Minor -ne $selectedVersion.Minor) {
            throw (".venv uses Python {0}, but the requested interpreter is Python {1}." -f $venvVersion, $selectedVersion)
        }
    }

    $baseExe = if ($lines.Count -ge 2) { $lines[1].Trim() } else { $venvPython }
    Write-Host ("  Existing .venv Python OK: {0} ({1})" -f $venvVersion, $baseExe) -ForegroundColor DarkGray
}

function Resolve-VenvReuseOrRecreate {
<#
.SYNOPSIS
    Reuses a compatible venv or safely backs up/removes an incompatible one.
#>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory=$true)][string] $VenvDir,
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[hashtable]] $Constraints,
        [Parameter(Mandatory=$true)][string] $RequiresPythonRaw,
        [Parameter(Mandatory=$true)][object] $SelectedPython,
        [bool] $RequireSelectedPython = $false,
        [bool] $NonInteractive = $false
    )

    try {
        Confirm-VenvPythonCompatible -VenvDir $VenvDir -Constraints $Constraints -RequiresPythonRaw $RequiresPythonRaw -SelectedPython $SelectedPython -RequireSelectedPython $RequireSelectedPython
        return $null
    }
    catch {
        Write-Banner ("Existing .venv can't be reused ({0}) - recreating automatically." -f $_.Exception.Message) 'WARN'
        if (-not $PSCmdlet.ShouldProcess($VenvDir, 'Backup and recreate incompatible virtual environment')) { return $null }
        $backupPath = New-VenvBackup -VenvDir $VenvDir -Confirm:$false
        Remove-VenvIfExists -VenvDir $VenvDir -NonInteractive $NonInteractive -Confirm:$false
        [pscustomobject]@{ BackupPath = $backupPath }
    }
}

function Copy-PythonDllToVenv {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][string] $DllSourceDir,
        [Parameter(Mandatory=$true)][string] $VenvDir,
        [Parameter(Mandatory=$true)][string] $DllName
    )

    $dllSrc = [System.IO.Path]::GetFullPath((Join-Path $DllSourceDir $DllName))
    if (Test-Path -LiteralPath $dllSrc -PathType Leaf) {
        if ($PSCmdlet.ShouldProcess($VenvDir, "Copy $DllName")) {
            Copy-Item -LiteralPath $dllSrc -Destination $VenvDir -Force
            Write-Banner "$DllName copied to .venv." 'SUCCESS'
        }
    } else {
        Write-Banner ("$DllName not found at: {0} -- skipping." -f $dllSrc) 'WARN'
    }
}

function Write-ProjectPth {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][string] $ProjectRoot,
        [Parameter(Mandatory=$true)][string] $SitePackagesDir
    )

    $pthName = (Split-Path $ProjectRoot -Leaf) -replace '[^a-zA-Z0-9]', '_'
    $pthFile = [System.IO.Path]::GetFullPath((Join-Path $SitePackagesDir "$pthName.pth"))
    if (-not $PSCmdlet.ShouldProcess($pthFile, 'Write project path file')) { return }

    if (-not (Test-Path -LiteralPath $SitePackagesDir -PathType Container)) {
        New-Item -ItemType Directory -LiteralPath $SitePackagesDir | Out-Null
    }
    $ProjectRoot | Set-Content -LiteralPath $pthFile -Encoding UTF8
}

function Invoke-VenvActivation {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][string] $ProjectRoot)

    $activateScript = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot 'scripts4PythonAutomation\activate-venv.ps1'))
    if (-not (Test-Path -LiteralPath $activateScript -PathType Leaf)) {
        Write-Banner 'Venv activation script not found -- skipping auto-activation.' 'WARN'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($activateScript, 'Activate project venv in current shell')) { return }

    try {
        . $activateScript
        Write-Banner 'Project venv activated.' 'SUCCESS'
    } catch {
        Write-Banner ("Could not auto-activate venv: {0}" -f $_.Exception.Message) 'WARN'
    }
}

function New-VenvBackup {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param([Parameter(Mandatory=$true)][string] $VenvDir)

    if (-not (Test-Path -LiteralPath $VenvDir -PathType Container)) { return $null }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupPath = "{0}_backup_{1}" -f $VenvDir, $stamp
    if (-not $PSCmdlet.ShouldProcess($VenvDir, "Rename to backup $backupPath")) { return $null }

    try {
        Rename-Item -LiteralPath $VenvDir -NewName $backupPath -ErrorAction Stop
        Write-Host ("  Backed up existing .venv to: {0}" -f (Split-Path $backupPath -Leaf)) -ForegroundColor DarkGray
        $backupPath
    } catch {
        Write-Warning ("Could not back up .venv: {0}; proceeding without backup." -f $_.Exception.Message)
        $null
    }
}

function Restore-VenvBackup {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        [string] $BackupPath,
        [Parameter(Mandatory=$true)][string] $VenvDir
    )

    if (-not $BackupPath -or -not (Test-Path -LiteralPath $BackupPath -PathType Container)) { return }
    if (-not $PSCmdlet.ShouldProcess($VenvDir, "Restore virtual environment from $BackupPath")) { return }

    $constants = Get-SetupConstants
    if (Test-Path -LiteralPath $VenvDir) {
        Remove-PathRobust -Path $VenvDir -MaxRetry ([int]$constants.Retry.MaxRetry) -DelayMs ([int]$constants.Retry.DelayMs) -Confirm:$false | Out-Null
    }

    try {
        Rename-Item -LiteralPath $BackupPath -NewName $VenvDir -ErrorAction Stop
        Write-Host ("  Restored .venv from backup: {0}" -f (Split-Path $BackupPath -Leaf)) -ForegroundColor Yellow
    } catch {
        Write-Warning ("Could not restore .venv backup '{0}': {1}" -f (Split-Path $BackupPath -Leaf), $_.Exception.Message)
    }
}

function Remove-VenvBackup {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string] $BackupPath)

    if (-not $BackupPath -or -not (Test-Path -LiteralPath $BackupPath)) { return }
    if (-not $PSCmdlet.ShouldProcess($BackupPath, 'Remove successful venv backup')) { return }

    $constants = Get-SetupConstants
    if (-not (Remove-PathRobust -Path $BackupPath -MaxRetry ([int]$constants.Retry.CleanupMaxRetry) -DelayMs ([int]$constants.Retry.CleanupDelayMs) -Confirm:$false)) {
        Write-Warning ("Could not remove .venv backup (still locked): {0}" -f (Split-Path $BackupPath -Leaf))
    }
}

Export-ModuleMember -Function `
    Remove-VenvIfExists, `
    Confirm-VenvExists, `
    Confirm-VenvPythonCompatible, `
    Resolve-VenvReuseOrRecreate, `
    Copy-PythonDllToVenv, `
    Write-ProjectPth, `
    Invoke-VenvActivation, `
    New-VenvBackup, `
    Restore-VenvBackup, `
    Remove-VenvBackup
