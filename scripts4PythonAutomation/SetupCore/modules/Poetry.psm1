#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Poetry bootstrap and command helpers for setup.

.DESCRIPTION
    Handles Poetry availability checks, isolated Poetry runtime provisioning,
    Poetry configuration, environment selection, and dependency installation.
    Poetry is used as the project's virtualenv manager (virtualenvs.in-project).
#>

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'UI.psm1')            -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'NativeCommand.psm1') -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Filesystem.psm1')    -Force -DisableNameChecking -ErrorAction Stop

<#
.SYNOPSIS
    Executes a Poetry-related command through a Python interpreter.

.DESCRIPTION
    Uses Invoke-NativeCommand for consistent native process handling.
    Fails only on non-zero process exit code.
#>
function Invoke-PoetryCommand {
    param(
        [Parameter(Mandatory=$true)][string] $Executable,
        [Parameter(Mandatory=$true)][string[]] $Arguments,
        [Parameter(Mandatory=$true)][string] $FailureMessage,
        [switch] $Quiet
    )
    $normalizedArgs = @($Arguments)

    # When a poetry shim executable is used directly, drop the python-style
    # '-m poetry' prefix so we do not call: poetry.exe -m poetry ...
    if ($Executable -match '(^|[\\/])poetry(\.exe)?$') {
        if ($normalizedArgs.Count -ge 2 -and $normalizedArgs[0] -eq '-m' -and $normalizedArgs[1] -eq 'poetry') {
            if ($normalizedArgs.Count -gt 2) {
                $normalizedArgs = @($normalizedArgs[2..($normalizedArgs.Count - 1)])
            } else {
                $normalizedArgs = @()
            }
        }
    }

    Invoke-NativeCommand -Executable $Executable -Arguments $normalizedArgs -Quiet:$Quiet -ThrowOnError -FailureMessage $FailureMessage | Out-Null
}

<#
.SYNOPSIS
    Checks whether Poetry is importable from a specific Python executable.
#>
function Test-PoetryAvailable {
    param([Parameter(Mandatory=$true)][string] $PythonExe)
    $poetryAvailable = $true
    try {
        Invoke-PoetryCommand -Executable $PythonExe -Arguments @('-m', 'poetry', '--version') -FailureMessage 'Poetry unavailable in selected Python.' -Quiet
    } catch {
        $poetryAvailable = $false
    }
    $poetryAvailable
}

<#
.SYNOPSIS
    Resolves the path of the poetry.exe CLI shim, checking both Poetry 1.2+
    and legacy install locations.

.DESCRIPTION
    Poetry 1.2+ installs the shim to %USERPROFILE%\.local\bin\poetry.exe.
    Older versions used %APPDATA%\Python\Scripts\poetry.exe. Returns the
    first one that exists, or $null when neither is present.
#>
function Get-PoetryShimPath {
    # Check PATH first - works everywhere after pipx/pip install.
    $cmd = Get-Command 'poetry' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Known install locations (null-safe: skip when env var is absent on macOS/Linux).
    $userProfile = [System.Environment]::GetFolderPath('UserProfile')
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($userProfile) {
        $candidates.Add((Join-Path $userProfile '.local/bin/poetry'))       # pipx / astral on macOS/Linux
        $candidates.Add((Join-Path $userProfile '.local\bin\poetry.exe'))   # pipx on Windows
    }
    if ($env:APPDATA) {
        $candidates.Add((Join-Path $env:APPDATA 'Python\Scripts\poetry.exe'))  # legacy pip install
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    return $null
}

<#
.SYNOPSIS
    Adds the poetry shim's directory to PATH (current process and User scope).
#>
function Add-PoetryShimToPath {
    param([Parameter(Mandatory=$true)][string] $ShimPath)

    $poetryBinDir = [System.IO.Path]::GetFullPath((Split-Path $ShimPath -Parent))
    if (-not $poetryBinDir -or -not (Test-Path -LiteralPath $poetryBinDir -PathType Container)) { return }

    if ($env:Path.IndexOf($poetryBinDir, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $env:Path = "$poetryBinDir;$env:Path"
    }
    try {
        $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath.IndexOf($poetryBinDir, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            [System.Environment]::SetEnvironmentVariable('Path', "$poetryBinDir;$userPath", 'User')
        }
    } catch { }
}

<#
.SYNOPSIS
    Builds the standard poetry runtime info object returned by
    Initialize-PoetryRuntime.
#>
function New-PoetryRuntimeInfo {
    param(
        [Parameter(Mandatory=$true)][string] $PoetryPython,
        [Parameter(Mandatory=$true)][string] $Source,
        [string] $ShimPath,
        [string] $RuntimeDir,
        [string] $PoetryVersion
    )
    [pscustomobject]@{
        PoetryPython = $PoetryPython
        ShimPath     = $ShimPath
        RuntimeDir   = $RuntimeDir
        Source       = $Source
        PoetryVersion = $PoetryVersion
    }
}

<#
.SYNOPSIS
    Resolves the Poetry version string for a given runtime.

.OUTPUTS
    String with normalized poetry version output or $null.
#>
function Get-PoetryVersion {
    param([Parameter(Mandatory=$true)][string] $PoetryPython)

    try {
        $result = Invoke-NativeCommand -Executable $PoetryPython -Arguments @('-m', 'poetry', '--version') -Quiet
        if (-not $result.Succeeded) { return $null }

        $out = if ($result.StdOut) { $result.StdOut.Trim() } else { '' }
        if (-not $out) { return $null }
        return ($out -replace '\s+', ' ')
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
    Ensures a Poetry-capable Python runtime is available.

.DESCRIPTION
    Returns a pscustomobject describing the Poetry runtime with fields
    PoetryPython, ShimPath, RuntimeDir, and Source.

    Fast paths (in order):
      1. Existing isolated Poetry runtime at %APPDATA%\pypoetry\venv - if
         present and functional, return it without re-installing.
      2. Poetry importable from the selected project Python (e.g. installed
         via pip in that interpreter).
      3. Otherwise, download the official installer
         (https://install.python-poetry.org) and run it.
#>
function Initialize-PoetryRuntime {
    param(
        [Parameter(Mandatory=$true)][string] $PythonExe,
        [bool]   $NonInteractive = $false,
        [string] $PinnedVersion  = ''   # e.g. '1.8.3'; empty = install latest
    )

    # Step-level logging is handled by the orchestrator (Start-Setup).

    # Fast path 1 is Windows-only (isolated runtime in %APPDATA%\pypoetry\venv).
    $runtimeDir    = if ($env:APPDATA) { [System.IO.Path]::GetFullPath((Join-Path $env:APPDATA 'pypoetry\venv')) } else { $null }
    $runtimePython = if ($runtimeDir)  { [System.IO.Path]::GetFullPath((Join-Path $runtimeDir 'Scripts\python.exe')) } else { $null }

    # Fast path 1: existing isolated Poetry runtime already present.
    if ($runtimePython -and (Test-Path -LiteralPath $runtimePython -PathType Leaf)) {
        if (Test-PoetryAvailable -PythonExe $runtimePython) {
            $shim = Get-PoetryShimPath
            if ($shim) { Add-PoetryShimToPath -ShimPath $shim }
            $version = Get-PoetryVersion -PoetryPython $runtimePython
            return (New-PoetryRuntimeInfo -PoetryPython $runtimePython -Source 'existing' -ShimPath $shim -RuntimeDir $runtimeDir -PoetryVersion $version)
        }
    }

    # Fast path 2: Poetry importable from the selected project Python.
    if (Test-PoetryAvailable -PythonExe $PythonExe) {
        $version = Get-PoetryVersion -PoetryPython $PythonExe
        return (New-PoetryRuntimeInfo -PoetryPython $PythonExe -Source 'project-python' -ShimPath (Get-PoetryShimPath) -RuntimeDir $null -PoetryVersion $version)
    }

    # Fast path 3: existing poetry shim is callable.
    $existingShim = Get-PoetryShimPath
    if ($existingShim -and (Test-Path -LiteralPath $existingShim -PathType Leaf)) {
        try {
            $shimResult = Invoke-NativeCommand -Executable $existingShim -Arguments @('--version') -Quiet
            if ($shimResult.Succeeded) {
                $shimVersion = if ($shimResult.StdOut) { ($shimResult.StdOut -replace '\s+', ' ').Trim() } else { $null }
                Add-PoetryShimToPath -ShimPath $existingShim
                return (New-PoetryRuntimeInfo -PoetryPython $existingShim -Source 'shim-existing' -ShimPath $existingShim -RuntimeDir $null -PoetryVersion $shimVersion)
            }
        } catch { }
    }

    # Auto-install: pipx (preferred, isolated) → pip fallback.
    $versionSpec  = if ($PinnedVersion) { "poetry==$PinnedVersion" } else { 'poetry' }
    $versionLabel = if ($PinnedVersion) { "v$PinnedVersion" } else { 'latest' }
    $installed    = $false

    $pipxCmd = Get-Command 'pipx' -ErrorAction SilentlyContinue
    if ($pipxCmd) {
        Write-Banner "Poetry not found. Installing ($versionLabel) via pipx ..." 'WARN'
        try {
            $r = Invoke-NativeCommand -Executable $pipxCmd.Source -Arguments @('install', $versionSpec) -FailureMessage "pipx install poetry failed."
            $installed = $r.Succeeded
        } catch { $installed = $false }

        if ($installed) {
            # pipx installs to ~/.local/bin - add to PATH if not already there.
            $localBin = Join-Path ([System.Environment]::GetFolderPath('UserProfile')) '.local/bin'
            if ((Test-Path $localBin -PathType Container) -and ($env:PATH.IndexOf($localBin, [StringComparison]::OrdinalIgnoreCase) -lt 0)) {
                $env:PATH = "$localBin$([System.IO.Path]::PathSeparator)$env:PATH"
            }
        }
    }

    if (-not $installed) {
        Write-Banner "Poetry not found. Installing ($versionLabel) via pip ..." 'WARN'
        try {
            $r = Invoke-NativeCommand -Executable $PythonExe -Arguments @('-m', 'pip', 'install', '--quiet', $versionSpec) -FailureMessage "pip install poetry failed."
            $installed = $r.Succeeded
        } catch { $installed = $false }

        if ($installed) {
            Add-PythonScriptsDirToPath -PythonExe $PythonExe
        }
    }

    if (-not $installed) {
        $msg = "Failed to install Poetry via pipx and pip.`nInstall manually: https://python-poetry.org/docs/#installation"
        if ($NonInteractive) { throw $msg }
        Exit-WithError -Message $msg
    }

    # Re-check: prefer the shim (works for both pipx and pip installs).
    $shim = Get-PoetryShimPath
    if ($shim) {
        $version = Get-PoetryVersion -PoetryPython $shim
        Write-Banner "Poetry installed. Version: $version" 'SUCCESS'
        return (New-PoetryRuntimeInfo -PoetryPython $shim -Source 'installed' -ShimPath $shim -RuntimeDir $null -PoetryVersion $version)
    }

    # Shim still not found - try via the project Python (pip install case).
    if (Test-PoetryAvailable -PythonExe $PythonExe) {
        $version = Get-PoetryVersion -PoetryPython $PythonExe
        Write-Banner "Poetry installed. Version: $version" 'SUCCESS'
        return (New-PoetryRuntimeInfo -PoetryPython $PythonExe -Source 'installed' -ShimPath $null -RuntimeDir $null -PoetryVersion $version)
    }

    $msg = "Poetry installation completed but Poetry could not be located.`nRestart your shell and re-run setup."
    if ($NonInteractive) { throw $msg }
    Exit-WithError -Message $msg
}

<#
.SYNOPSIS
    Configures Poetry to create project-local virtual environments.

.PARAMETER Local
    When set, passes `--local` so Poetry writes the config to
    <ProjectRoot>\poetry.toml instead of the user's global
    %APPDATA%\pypoetry\config.toml. Useful for tests that must not pollute
    the dev machine's global Poetry configuration.
#>
function Set-PoetryConfiguration {
    param(
        [Parameter(Mandatory=$true)][string] $PoetryPython,
        [string] $ProjectRoot,
        [switch] $Local
    )
    Write-Host '  Configuring Poetry: virtualenvs.in-project=true, virtualenvs.create=true' -ForegroundColor DarkGray

    $base = @('-m', 'poetry')
    if ($Local) {
        if (-not $ProjectRoot) {
            throw 'Set-PoetryConfiguration -Local requires -ProjectRoot to be specified.'
        }
        $base += @('-C', $ProjectRoot)
    }

    $tail = @('config')
    if ($Local) { $tail += '--local' }

    Invoke-PoetryCommand -Executable $PoetryPython -Arguments ($base + $tail + @('virtualenvs.in-project', 'true')) -FailureMessage 'Failed to configure Poetry (virtualenvs.in-project).'
    Invoke-PoetryCommand -Executable $PoetryPython -Arguments ($base + $tail + @('virtualenvs.create', 'true')) -FailureMessage 'Failed to configure Poetry (virtualenvs.create).'
}

<#
.SYNOPSIS
    Best-effort removal of Poetry environment associations for the project.
#>
function Remove-PoetryEnvs {
    param(
        [Parameter(Mandatory=$true)][string] $PoetryPython,
        [string] $ProjectRoot
    )
    try {
        $poetryArgs = @('-m', 'poetry')
        if ($ProjectRoot) { $poetryArgs += @('-C', $ProjectRoot) }
        $poetryArgs += @('env', 'remove', '--all')
        Invoke-PoetryCommand -Executable $PoetryPython -Arguments $poetryArgs -FailureMessage 'Failed to remove existing Poetry environments.' -Quiet
    } catch { }
}

<#
.SYNOPSIS
    Pins Poetry to use the selected Python executable for the project.
#>
function Use-PoetryPython {
    param(
        [Parameter(Mandatory=$true)][string] $PoetryPython,
        [Parameter(Mandatory=$true)][string] $PythonExe,
        [Parameter(Mandatory=$true)][string] $ProjectRoot
    )
    # Pass the path raw. Invoke-NativeCommand uses Start-Process -ArgumentList,
    # which handles quoting correctly. Adding literal quotes would inject them
    # into the argument string and make Poetry see `"C:\path\python.exe"` with
    # embedded quote characters, breaking path existence checks.
    Invoke-PoetryCommand -Executable $PoetryPython -Arguments @('-m', 'poetry', '-C', $ProjectRoot, 'env', 'use', $PythonExe) -FailureMessage ("Poetry 'env use' failed for: {0}. Project root: {1}" -f $PythonExe, $ProjectRoot)
}

<#
.SYNOPSIS
    Regenerates poetry.lock to be consistent with the current pyproject.toml.

.DESCRIPTION
    Runs 'poetry lock', which resolves any changes made to pyproject.toml
    (added/removed/changed dependencies) and rewrites the lock file WITHOUT
    upgrading already-locked packages (no-upgrade is the default in all
    Poetry versions; --no-update was removed in Poetry 2.x).

    This fixes the common error:
      "pyproject.toml changed significantly since poetry.lock was last generated.
       Run 'poetry lock' to fix the lock file."

    Always run this before 'poetry install' when pyproject.toml may have changed.
    It is a no-op if the lock file is already consistent.
#>
function Invoke-PoetryLock {
    param(
        [Parameter(Mandatory=$true)][string] $PoetryPython,
        [Parameter(Mandatory=$true)][string] $ProjectRoot
    )
    Invoke-PoetryCommand `
        -Executable     $PoetryPython `
        -Arguments      @('-m', 'poetry', '-C', $ProjectRoot, 'lock') `
        -FailureMessage "'poetry lock' failed -- see output above."
}

<#
.SYNOPSIS
    Runs `poetry install` in the target project.

.DESCRIPTION
    Uses the existing poetry.lock to install exact pinned versions.
    This is the standard path for reproducible installs - every developer
    and CI run gets identical package versions.
#>
function Invoke-PoetryInstall {
    param(
        [Parameter(Mandatory=$true)][string] $PoetryPython,
        [Parameter(Mandatory=$true)][string] $ProjectRoot,
        [bool] $IncludeDev = $true
    )
    $poetryArgs = @('-m', 'poetry', '-C', $ProjectRoot, 'install')
    if (-not $IncludeDev) { $poetryArgs += @('--without', 'dev') }
    Invoke-PoetryCommand -Executable $PoetryPython -Arguments $poetryArgs -FailureMessage "'poetry install' failed -- see output above."
}

<#
.SYNOPSIS
    Runs `poetry update` in the target project.

.DESCRIPTION
    Re-resolves all dependencies to the latest versions allowed by
    pyproject.toml constraints and rewrites poetry.lock. This is the
    Poetry-recommended way to intentionally refresh dependencies - it is
    equivalent to deleting poetry.lock and re-running install, but without
    the manual file deletion step.

    Use this only when you deliberately want to upgrade to newer compatible
    versions. For normal setup, use Invoke-PoetryInstall instead.
#>
function Invoke-PoetryUpdate {
    param(
        [Parameter(Mandatory=$true)][string] $PoetryPython,
        [Parameter(Mandatory=$true)][string] $ProjectRoot,
        [bool] $IncludeDev = $true
    )
    $poetryArgs = @('-m', 'poetry', '-C', $ProjectRoot, 'update')
    if (-not $IncludeDev) { $poetryArgs += @('--without', 'dev') }
    Invoke-PoetryCommand -Executable $PoetryPython -Arguments $poetryArgs -FailureMessage "'poetry update' failed -- see output above."
}

Export-ModuleMember -Function `
    Invoke-PoetryCommand, `
    Test-PoetryAvailable, `
    Get-PoetryShimPath, `
    Get-PoetryVersion, `
    Initialize-PoetryRuntime, `
    Set-PoetryConfiguration, `
    Remove-PoetryEnvs, `
    Use-PoetryPython, `
    Invoke-PoetryLock, `
    Invoke-PoetryInstall, `
    Invoke-PoetryUpdate