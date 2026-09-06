#Requires -Version 5.1
# =============================================================================
# Module  : PackageManager.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Execution facade - uniform PM interface for install, sync, venv, runtime.

.DESCRIPTION
    The orchestrator (Setup-Core.psm1) calls ONLY the Invoke-Pm* / Get-Pm*
    functions defined here.  It never calls UV.psm1 or Poetry.psm1 directly.
    PM *detection* (which manager to use) lives in Detection.psm1; this module
    only handles *execution* (running the chosen manager's commands).

    Adding a third package manager:
      1. Create its own .psm1 module (e.g. Conda.psm1).
      2. Import it below.
      3. Add switch branches in each function in this file.
    Zero changes to Setup-Core.psm1 or Detection.psm1 are required.

    Context keys written by Invoke-PmEnsureRuntime:
        UV     → $Ctx.UvInfo          { Source; Version; Exe }
                 $Ctx.PmPythonPath    (generic alias = UvInfo.Exe)
        Poetry → $Ctx.PoetryInfo      { PoetryPython; ShimPath; Source; … }
                 $Ctx.PoetryPythonPath (string shortcut for PoetryInfo.PoetryPython)
                 $Ctx.PmPythonPath    (generic alias = PoetryPythonPath)
#>

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'UI.psm1')            -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'NativeCommand.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'UV.psm1')            -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Poetry.psm1')        -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Venv.psm1')          -Force -DisableNameChecking -Global -ErrorAction Stop


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------
function Assert-SupportedPm {
    param([hashtable] $Ctx)
    if ($Ctx.PackageManager -notin @('uv', 'poetry')) {
        throw ("Unsupported PackageManager value '{0}'. Valid values: uv, poetry." -f $Ctx.PackageManager)
    }
}

function Update-Pip {
<#
.SYNOPSIS
    Upgrades pip for the given Python interpreter. Soft-fails silently.
.DESCRIPTION
    Called once before any pip-based PM install. Some environments (managed
    Python, corporate proxies, read-only installs) disallow pip self-upgrades;
    any failure is non-fatal and logged at VERBOSE only.
#>
    param([Parameter(Mandatory=$true)][string] $PythonExe)

    $result = Invoke-NativeCommand `
        -Executable     $PythonExe `
        -Arguments      @('-m', 'pip', 'install', '--quiet', '--upgrade', 'pip') `
        -Quiet `
        -FailureMessage 'pip self-upgrade failed.'
    if (-not $result.Succeeded) {
        Write-Verbose "pip upgrade exited with code $($result.ExitCode) - continuing."
    }
}


# ---------------------------------------------------------------------------
# Step 3 - Ensure runtime is installed and locate the executable
# ---------------------------------------------------------------------------
function Invoke-PmEnsureRuntime {
<#
.SYNOPSIS
    Installs the package manager if missing and populates $Ctx with its info.

    UV:     sets $Ctx.UvInfo           { Source; Version; Exe }
    Poetry: sets $Ctx.PoetryInfo       { PoetryPython; ShimPath; Source; ... }
            sets $Ctx.PoetryPythonPath (string shortcut)
#>
    param([hashtable] $Ctx)
    Assert-SupportedPm -Ctx $Ctx

    Update-Pip -PythonExe $Ctx.SelectedPython.Exe

    switch ($Ctx.PackageManager) {

        'uv' {
            $pinnedUv        = if ($Ctx.ContainsKey('PinnedUvVersion')) { $Ctx.PinnedUvVersion } else { '' }
            $Ctx.UvInfo      = Initialize-UvRuntime `
                                   -PythonExe      $Ctx.SelectedPython.Exe `
                                   -NonInteractive ([bool]$Ctx.NonInteractive) `
                                   -PinnedVersion  $pinnedUv
            # Generic alias so callers need not know which PM is active.
            $Ctx.PmPythonPath = $Ctx.UvInfo.Exe
            Write-LogDetail -Key 'uv_source'  -Value $Ctx.UvInfo.Source
            Write-LogDetail -Key 'uv_version' -Value $Ctx.UvInfo.Version
            Write-LogDetail -Key 'uv_exe'     -Value $Ctx.UvInfo.Exe
        }

        'poetry' {
            $pinnedPoetry         = if ($Ctx.ContainsKey('PinnedPoetryVersion')) { $Ctx.PinnedPoetryVersion } else { '' }
            $Ctx.PoetryInfo       = Initialize-PoetryRuntime `
                                        -PythonExe      $Ctx.SelectedPython.Exe `
                                        -NonInteractive ([bool]$Ctx.NonInteractive) `
                                        -PinnedVersion  $pinnedPoetry
            $Ctx.PoetryPythonPath = $Ctx.PoetryInfo.PoetryPython
            # Generic alias so callers need not know which PM is active.
            $Ctx.PmPythonPath     = $Ctx.PoetryPythonPath
            Write-LogDetail -Key 'poetry_source'  -Value $Ctx.PoetryInfo.Source
            Write-LogDetail -Key 'poetry_python'  -Value $Ctx.PoetryPythonPath
            Write-LogDetail -Key 'poetry_version' -Value $(if ($Ctx.PoetryInfo.PoetryVersion) { $Ctx.PoetryInfo.PoetryVersion } else { '<unknown>' })
            Write-LogDetail -Key 'poetry_shim'    -Value $(if ($Ctx.PoetryInfo.ShimPath)      { $Ctx.PoetryInfo.ShimPath }      else { '<not found>' })
            Write-LogDetail -Key 'poetry_runtime' -Value $(if ($Ctx.PoetryInfo.RuntimeDir)    { $Ctx.PoetryInfo.RuntimeDir }    else { '<project python>' })
        }
    }
}


# ---------------------------------------------------------------------------
# Step 3a helper - return the shim exe path that should be code-signed
# ---------------------------------------------------------------------------
function Get-PmShimPath {
<#
.SYNOPSIS
    Returns the path to the PM CLI executable that should be code-signed,
    or $null when no signing target can be determined.

    UV:     returns uv.exe (the native binary itself - no separate shim).
    Poetry: returns the poetry.exe shim created by the installer.

    Must be called AFTER Invoke-PmEnsureRuntime so $Ctx.UvInfo / $Ctx.PoetryInfo
    are populated.
#>
    param([hashtable] $Ctx)
    Assert-SupportedPm -Ctx $Ctx

    switch ($Ctx.PackageManager) {
        'uv'     { return $(if ($Ctx.UvInfo)     { $Ctx.UvInfo.Exe }          else { $null }) }
        'poetry' { return $(if ($Ctx.PoetryInfo) { $Ctx.PoetryInfo.ShimPath } else { $null }) }
    }
}


# ---------------------------------------------------------------------------
# Step 4 - One-time PM configuration (idempotent)
# ---------------------------------------------------------------------------
function Invoke-PmConfigure {
<#
.SYNOPSIS
    Applies package-manager-level configuration that must be in place before
    the venv is created.

    UV:     no-op (uv reads pyproject.toml directly; no global config needed).
    Poetry: sets virtualenvs.in-project = true so .venv is created inside the
            project root rather than in a central cache directory.
#>
    param([hashtable] $Ctx)
    Assert-SupportedPm -Ctx $Ctx

    switch ($Ctx.PackageManager) {
        'uv'     { }  # no-op
        'poetry' { Set-PoetryConfiguration -PoetryPython $Ctx.PoetryPythonPath }
    }
}


# ---------------------------------------------------------------------------
# Step 5a - Remove stale PM env registrations before .venv recreation
# ---------------------------------------------------------------------------
function Invoke-PmCleanEnvs {
<#
.SYNOPSIS
    Removes any stale environment associations registered with the PM.

    UV:     no-op (uv has no global env registry).
    Poetry: calls Remove-PoetryEnvs so Poetry no longer points to the old
            .venv location.  Prevents 'poetry env list' from showing ghosts.
#>
    param([hashtable] $Ctx)
    Assert-SupportedPm -Ctx $Ctx

    switch ($Ctx.PackageManager) {
        'uv'     { }  # no-op
        'poetry' {
            if ($Ctx.ForceRecreateVenv) {
                # Nur wenn der Benutzer explizit -RecreateVenv/-ForceRecreateVenv angefordert hat:
                Write-Host ">>> [Invoke-PmCleanEnvs] Poetry: running 'env remove --all' because ForceRecreateVenv = true" -ForegroundColor Magenta
                Remove-PoetryEnvs `
                    -PoetryPython $Ctx.PoetryPythonPath `
                    -ProjectRoot  $Ctx.ProjectRoot
            } else {
                # Normaler Lauf: nichts löschen
                Write-Host ">>> [Invoke-PmCleanEnvs] Poetry: skipping 'env remove --all' (ForceRecreateVenv = false)" -ForegroundColor Magenta
            }
        }
    }
}


# ---------------------------------------------------------------------------
# Step 5c - Create the .venv and pin it to the selected Python interpreter
# ---------------------------------------------------------------------------
function Invoke-PmPrepareVenv {
<#
.SYNOPSIS
    Creates the virtual environment and pins it to the selected Python.

    UV:     'uv venv --python <exe> <venv_dir>'
    Poetry: 'poetry env use <exe>'  (Poetry creates .venv inside the project
            root because virtualenvs.in-project was set in step 4)
#>
    param([hashtable] $Ctx)
    Assert-SupportedPm -Ctx $Ctx

    switch ($Ctx.PackageManager) {
        'uv' {
            $venvDir = $Ctx.VenvDir

            if (-not (Test-Path $venvDir -PathType Container)) {
                # .venv-Ordner existiert noch nicht -> neu anlegen
                Write-Host ">>> [Invoke-PmPrepareVenv] uv: .venv does NOT exist -> running 'uv venv'" -ForegroundColor Magenta
                Invoke-UvVenv `
                    -PythonExe $Ctx.SelectedPython.Exe `
                    -VenvDir   $Ctx.VenvDir `
                    -UvExe     $Ctx.UvInfo.Exe
            } else {
                # .venv-Ordner existiert -> nur wiederverwenden, wenn kompatibel;
                # sonst automatisch sichern + neu anlegen (siehe Resolve-VenvReuseOrRecreate)
                Write-Host ">>> [Invoke-PmPrepareVenv] uv: .venv EXISTS -> reusing, NO 'uv venv'" -ForegroundColor Magenta
                $recreate = Resolve-VenvReuseOrRecreate `
                    -VenvDir               $Ctx.VenvDir `
                    -Constraints           $Ctx.ParsedConstraints `
                    -RequiresPythonRaw     $Ctx.RequiresPython `
                    -SelectedPython        $Ctx.SelectedPython `
                    -RequireSelectedPython ([bool]$Ctx.PythonExePath) `
                    -NonInteractive        ([bool]$Ctx.NonInteractive)
                if ($recreate) {
                    $Ctx.VenvBackupPath = $recreate.BackupPath
                    Invoke-UvVenv `
                        -PythonExe $Ctx.SelectedPython.Exe `
                        -VenvDir   $Ctx.VenvDir `
                        -UvExe     $Ctx.UvInfo.Exe
                }
            }
        }
        'poetry' {
            $venvDir = $Ctx.VenvDir
            $needsCreate = $false

            if (-not (Test-Path $venvDir -PathType Container)) {
                # .venv-Ordner existiert überhaupt nicht -> neu anlegen
                Write-Host ">>> .venv existiert NICHT -> needsCreate = true, 'poetry env use' wird aufgerufen" -ForegroundColor Magenta
                $needsCreate = $true
            } else {
                # .venv-Ordner existiert -> nur wiederverwenden, wenn kompatibel;
                # sonst automatisch sichern + neu anlegen (siehe Resolve-VenvReuseOrRecreate)
                Write-Host ">>> .venv EXISTS -> reusing, NO 'poetry env use'" -ForegroundColor Magenta
                Write-Host ("  Reusing existing virtualenv at {0} (skip 'poetry env use')" -f $venvDir) -ForegroundColor DarkGray
                $recreate = Resolve-VenvReuseOrRecreate `
                    -VenvDir               $Ctx.VenvDir `
                    -Constraints           $Ctx.ParsedConstraints `
                    -RequiresPythonRaw     $Ctx.RequiresPython `
                    -SelectedPython        $Ctx.SelectedPython `
                    -RequireSelectedPython ([bool]$Ctx.PythonExePath) `
                    -NonInteractive        ([bool]$Ctx.NonInteractive)
                if ($recreate) {
                    $Ctx.VenvBackupPath = $recreate.BackupPath
                    $needsCreate = $true
                }
            }

            if ($needsCreate) {
                Use-PoetryPython `
                    -PoetryPython $Ctx.PoetryPythonPath `
                    -PythonExe    $Ctx.SelectedPython.Exe `
                    -ProjectRoot  $Ctx.ProjectRoot
            }
        }
    
    }
}


# ---------------------------------------------------------------------------
# Step 8 helpers - lock file metadata and synchronization
# ---------------------------------------------------------------------------
function Get-PmLockFileName {
<#
.SYNOPSIS
    Returns the name of the lock file produced by the active package manager.
    Used for logging; the orchestrator never parses the lock file itself.
#>
    param([hashtable] $Ctx)
    Assert-SupportedPm -Ctx $Ctx

    switch ($Ctx.PackageManager) {
        'uv'     { return 'uv.lock' }
        'poetry' { return 'poetry.lock' }
    }
}

function Invoke-PmLockDeps {
<#
.SYNOPSIS
    Synchronizes the lock file with the current pyproject.toml without
    upgrading already-pinned packages.
#>
    param([hashtable] $Ctx)
    Assert-SupportedPm -Ctx $Ctx

    switch ($Ctx.PackageManager) {
        'uv' {
            Invoke-UvLock `
                -ProjectRoot $Ctx.ProjectRoot `
                -UvExe       $Ctx.UvInfo.Exe
        }
        'poetry' {
            Invoke-PoetryLock `
                -PoetryPython $Ctx.PoetryPythonPath `
                -ProjectRoot  $Ctx.ProjectRoot
        }
    }
}


# ---------------------------------------------------------------------------
# Step 9 - Install (reproducible) or update (re-resolve) dependencies
# ---------------------------------------------------------------------------
function Invoke-PmInstallDeps {
<#
.SYNOPSIS
    Installs exact versions from the lock file into the active .venv.

    UV:     'uv sync [--all-extras]'            (--all-extras omitted when IncludeDev=false)
    Poetry: 'poetry install [--without dev]'
#>
    param(
        [hashtable] $Ctx,
        [bool]      $IncludeDev = $true
    )
    Assert-SupportedPm -Ctx $Ctx

    switch ($Ctx.PackageManager) {
        'uv' {
            Invoke-UvSync `
                -ProjectRoot $Ctx.ProjectRoot `
                -UvExe       $Ctx.UvInfo.Exe `
                -IncludeDev  $IncludeDev
        }
        'poetry' {
            Invoke-PoetryInstall `
                -PoetryPython $Ctx.PoetryPythonPath `
                -ProjectRoot  $Ctx.ProjectRoot `
                -IncludeDev   $IncludeDev
        }
    }
}

function Invoke-PmUpdateDeps {
<#
.SYNOPSIS
    Re-resolves all dependencies to the latest versions allowed by
    pyproject.toml constraints and rewrites the lock file.

    UV:     'uv sync --upgrade [--all-extras]'
    Poetry: 'poetry update [--without dev]'
#>
    param(
        [hashtable] $Ctx,
        [bool]      $IncludeDev = $true
    )
    Assert-SupportedPm -Ctx $Ctx

    switch ($Ctx.PackageManager) {
        'uv' {
            Invoke-UvSyncUpgrade `
                -ProjectRoot $Ctx.ProjectRoot `
                -UvExe       $Ctx.UvInfo.Exe `
                -IncludeDev  $IncludeDev
        }
        'poetry' {
            Invoke-PoetryUpdate `
                -PoetryPython $Ctx.PoetryPythonPath `
                -ProjectRoot  $Ctx.ProjectRoot `
                -IncludeDev   $IncludeDev
        }
    }
}


function Invoke-PmUpdateSelectedDeps {
<#
.SYNOPSIS
    Re-resolves only the named packages to the latest versions allowed by
    pyproject.toml and rewrites the lock file for those entries only.

.DESCRIPTION
    All other locked versions are left untouched.  This is the correct way to
    refresh a Git-branch-ref dependency (e.g. an Azure DevOps library tracked
    on 'main') without upgrading the full environment.

    UV:     'uv sync --upgrade-package <name> ...'
    Poetry: 'poetry update <name> ...'

.PARAMETER Packages
    One or more package names to upgrade.
#>
    param(
        [hashtable] $Ctx,
        [Parameter(Mandatory=$true)][string[]] $Packages,
        [bool]      $IncludeDev = $true
    )
    Assert-SupportedPm -Ctx $Ctx

    switch ($Ctx.PackageManager) {
        'uv' {
            Invoke-UvSyncUpgradePackage `
                -ProjectRoot $Ctx.ProjectRoot `
                -UvExe       $Ctx.UvInfo.Exe `
                -Packages    $Packages `
                -IncludeDev  $IncludeDev
        }
        'poetry' {
            Invoke-PoetryUpdatePackage `
                -PoetryPython $Ctx.PoetryPythonPath `
                -ProjectRoot  $Ctx.ProjectRoot `
                -Packages     $Packages `
                -IncludeDev   $IncludeDev
        }
    }
}


Export-ModuleMember -Function `
    Invoke-PmEnsureRuntime, `
    Get-PmShimPath, `
    Invoke-PmConfigure, `
    Invoke-PmCleanEnvs, `
    Invoke-PmPrepareVenv, `
    Get-PmLockFileName, `
    Invoke-PmLockDeps, `
    Invoke-PmInstallDeps, `
    Invoke-PmUpdateDeps, `
    Invoke-PmUpdateSelectedDeps
