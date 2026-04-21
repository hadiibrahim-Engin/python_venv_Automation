#Requires -Version 5.1
# =============================================================================
# Module  : Venv.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Virtual-environment lifecycle helpers.

.DESCRIPTION
    Provides deletion/recreation support, structural validation, activation,
    and post-create helpers such as DLL copy and .pth file creation.
#>

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'UI.psm1')         -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Filesystem.psm1') -Force -DisableNameChecking -ErrorAction Stop

<#
.SYNOPSIS
    Removes an existing .venv directory with robust fallback behavior.

.DESCRIPTION
    Stops running venv processes, retries deletion, and quarantines locked
    environments when direct deletion is not possible.
#>
function Remove-VenvIfExists {
    param(
        [Parameter(Mandatory=$true)][string] $VenvDir,
        [bool] $NonInteractive = $false
    )
    if (Test-Path -LiteralPath $VenvDir) {
        Write-Host 'Force-removing existing .venv (stop running processes, clear attributes) ...' -ForegroundColor Yellow
        Stop-VenvProcesses -VenvDir $VenvDir

        $removed = Remove-PathRobust -Path $VenvDir -MaxRetry 8 -DelayMs 700
        if (-not $removed) {
            Write-Host 'Direct removal failed - attempting quarantine/rename ...' -ForegroundColor Yellow
            $q = Move-PathToQuarantine -Path $VenvDir
            if ($q) {
                Write-Banner ".venv quarantined to '$q' (will be removed when files are released)" 'WARN'
            } else {
                Exit-WithError -Message "Could not remove or quarantine .venv - close any processes using it and retry." -NonInteractive ([bool]$NonInteractive)
            }
        } else {
            Write-Banner '.venv removed.' 'SUCCESS'
        }
    }
}

<#
.SYNOPSIS
    Validates that .venv exists and contains required core artifacts.

.DESCRIPTION
    Ensures setup does not continue with a partial or corrupted environment.
#>
function Confirm-VenvExists {
    param([Parameter(Mandatory=$true)][string] $VenvDir)
    if (-not (Test-Path -LiteralPath $VenvDir -PathType Container)) {
        throw '.venv directory was not created. Check the package-manager output above.'
    }

    $onWindows = $env:OS -eq 'Windows_NT'
    $requiredFiles = @(
        [System.IO.Path]::GetFullPath((Join-Path $VenvDir 'pyvenv.cfg'))
    )

    # Platform-specific activation script
    if ($onWindows) {
        $requiredFiles += @(
            [System.IO.Path]::GetFullPath((Join-Path $VenvDir 'Scripts\Activate.ps1')),
            [System.IO.Path]::GetFullPath((Join-Path $VenvDir 'Scripts\python.exe'))
        )
    } else {
        $requiredFiles += @(
            [System.IO.Path]::GetFullPath((Join-Path $VenvDir 'bin/activate')),
            [System.IO.Path]::GetFullPath((Join-Path $VenvDir 'bin/python'))
        )
    }

    $missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missing.Count -gt 0) {
        throw ('.venv exists but is incomplete. Missing required file(s): {0}' -f ($missing -join ', '))
    }
}

<#
.SYNOPSIS
    Copies a Python runtime DLL into the virtual environment root.
#>
function Copy-PythonDllToVenv {
    param(
        [Parameter(Mandatory=$true)][string] $DllSourceDir,
        [Parameter(Mandatory=$true)][string] $VenvDir,
        [Parameter(Mandatory=$true)][string] $DllName
    )
    $dllSrc = [System.IO.Path]::GetFullPath((Join-Path $DllSourceDir $DllName))
    if (Test-Path -LiteralPath $dllSrc -PathType Leaf) {
        Copy-Item -LiteralPath $dllSrc -Destination $VenvDir -Force
        Write-Banner "$DllName copied to .venv." 'SUCCESS'
    } else {
        Write-Banner ("$DllName not found at: {0} -- skipping." -f $dllSrc) 'WARN'
    }
}

<#
.SYNOPSIS
    Writes a .pth file pointing site-packages to the project root.
#>
function Write-ProjectPth {
    param(
        [Parameter(Mandatory=$true)][string] $ProjectRoot,
        [Parameter(Mandatory=$true)][string] $SitePackagesDir
    )
    if (-not (Test-Path -LiteralPath $SitePackagesDir -PathType Container)) {
        New-Item -ItemType Directory -LiteralPath $SitePackagesDir | Out-Null
    }
    $pthName = (Split-Path $ProjectRoot -Leaf) -replace '[^a-zA-Z0-9]', '_'
    $pthFile = [System.IO.Path]::GetFullPath((Join-Path $SitePackagesDir "$pthName.pth"))
    $ProjectRoot | Set-Content -LiteralPath $pthFile -Encoding UTF8
}

<#
.SYNOPSIS
    Best-effort activation of the project venv in the current shell.
#>
function Invoke-VenvActivation {
    param([Parameter(Mandatory=$true)][string] $ProjectRoot)
    $activateScript = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot 'scripts4PythonAutomation\activate-venv.ps1'))
    if (Test-Path -LiteralPath $activateScript -PathType Leaf) {
        Write-Host 'Activating project venv in current shell ...' -ForegroundColor Yellow
        try {
            . $activateScript
            Write-Banner 'Project venv activated.' 'SUCCESS'
        } catch {
            Write-Banner ("Could not auto-activate venv: {0}" -f $_.Exception.Message) 'WARN'
        }
    } else {
        Write-Banner 'Venv activation script not found -- skipping auto-activation.' 'WARN'
    }
}

<#
.SYNOPSIS
    Creates a timestamped backup of the existing .venv directory.

.DESCRIPTION
    Renames .venv to .venv_backup_<timestamp> before a destructive recreation
    so setup can restore it if the new install fails.

.OUTPUTS
    The backup path string, or $null if no .venv existed.
#>
function New-VenvBackup {
    param([Parameter(Mandatory=$true)][string] $VenvDir)

    if (-not (Test-Path -LiteralPath $VenvDir -PathType Container)) {
        return $null
    }

    $stamp      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupPath = "{0}_backup_{1}" -f $VenvDir, $stamp

    try {
        Rename-Item -LiteralPath $VenvDir -NewName $backupPath -ErrorAction Stop
        Write-Host ("  Backed up existing .venv to: {0}" -f (Split-Path $backupPath -Leaf)) -ForegroundColor DarkGray
        return $backupPath
    } catch {
        Write-Host ("  Could not back up .venv: {0} - proceeding without backup." -f $_.Exception.Message) -ForegroundColor DarkYellow
        return $null
    }
}

<#
.SYNOPSIS
    Restores a previously created .venv backup on setup failure.

.DESCRIPTION
    Renames the backup directory back to the original .venv path.
    No-ops when BackupPath is null/empty or when the target already exists
    (meaning a partial new .venv was created and must be cleaned up first).
#>
function Restore-VenvBackup {
    param(
        [string] $BackupPath,
        [Parameter(Mandatory=$true)][string] $VenvDir
    )

    if (-not $BackupPath) { return }
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) { return }

    # Remove any partial new .venv so the rename can succeed
    if (Test-Path -LiteralPath $VenvDir) {
        Remove-PathRobust -Path $VenvDir -MaxRetry 4 -DelayMs 500 | Out-Null
    }

    try {
        Rename-Item -LiteralPath $BackupPath -NewName $VenvDir -ErrorAction Stop
        Write-Host ("  Restored .venv from backup: {0}" -f (Split-Path $BackupPath -Leaf)) -ForegroundColor Yellow
    } catch {
        Write-Host ("  Could not restore .venv backup '{0}': {1}" -f (Split-Path $BackupPath -Leaf), $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

<#
.SYNOPSIS
    Deletes a successful .venv backup after setup completes successfully.
#>
function Remove-VenvBackup {
    param([string] $BackupPath)

    if (-not $BackupPath) { return }
    if (-not (Test-Path -LiteralPath $BackupPath)) { return }

    if (Remove-PathRobust -Path $BackupPath -MaxRetry 3 -DelayMs 400) {
        Write-Host ("  Removed .venv backup: {0}" -f (Split-Path $BackupPath -Leaf)) -ForegroundColor DarkGray
    } else {
        Write-Host ("  Could not remove .venv backup (still locked): {0}" -f (Split-Path $BackupPath -Leaf)) -ForegroundColor DarkYellow
    }
}

Export-ModuleMember -Function `
    Remove-VenvIfExists, `
    Confirm-VenvExists, `
    Copy-PythonDllToVenv, `
    Write-ProjectPth, `
    Invoke-VenvActivation, `
    New-VenvBackup, `
    Restore-VenvBackup, `
    Remove-VenvBackup