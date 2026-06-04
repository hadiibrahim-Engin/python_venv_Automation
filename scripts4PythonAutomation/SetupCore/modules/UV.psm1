#Requires -Version 5.1
# =============================================================================
# Module  : UV.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    uv package-manager bootstrap and command helpers.

.DESCRIPTION
    Handles uv availability checks, pip-based installation through the selected
    Python interpreter, virtual-environment creation, and dependency sync.

    uv is the default package manager.  Poetry remains available via the
    -PackageManager poetry CLI argument.

    Key equivalences:
        uv sync              ≈ poetry install   (uses uv.lock)
        uv sync --upgrade    ≈ poetry update    (re-resolves, rewrites uv.lock)
        uv lock              ≈ poetry lock
        uv venv --python <p> ≈ poetry env use   (creates .venv with specific Python)
#>

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Compat.psm1')         -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'UI.psm1')             -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Path.psm1')           -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'NativeCommand.psm1')  -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Filesystem.psm1')     -Force -DisableNameChecking -ErrorAction Stop


# ---------------------------------------------------------------------------
# Discovery helpers
# ---------------------------------------------------------------------------

function Get-UvExe {
<#
.SYNOPSIS
    Returns the full path to the uv executable, or $null when not found.
    Checks PATH first, then common Windows pip install locations.
#>
    $cmd = Get-Command 'uv' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Fallback: pip --user install on Windows lands in %APPDATA%\Python\Scripts\ or
    # %APPDATA%\Python\PythonXXX\Scripts\ depending on the pip version.
    if ($env:APPDATA) {
        foreach ($pattern in @(
            (Join-Path $env:APPDATA 'Python\Scripts\uv.exe'),
            (Join-Path $env:APPDATA 'Python\Python*\Scripts\uv.exe')
        )) {
            $found = Get-Item $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }

    return $null
}

function Test-UvAvailable {
    return ($null -ne (Get-UvExe))
}

function Get-UvVersion {
    $exe = Get-UvExe
    if (-not $exe) { return $null }
    try {
        $r = Invoke-NativeCommand -Executable $exe -Arguments @('--version') -Quiet -NoLog
        if ($r.Succeeded) { return $r.StdOut.Trim() }
    } catch { }
    return $null
}


# ---------------------------------------------------------------------------
# Runtime bootstrap
# ---------------------------------------------------------------------------

function Initialize-UvRuntime {
<#
.SYNOPSIS
    Ensures uv is available; installs it with the selected Python if missing.

.DESCRIPTION
    Uses pip through the already-selected project interpreter so tool bootstrap
    does not accidentally depend on a different Python from PATH.

.PARAMETER PythonExe
    Selected project Python used to install uv if the executable is missing.

.PARAMETER NonInteractive
    Throw on failure instead of prompting.

.PARAMETER PinnedVersion
    When specified, installs exactly this uv version (e.g. '0.6.14').
    When omitted, installs the latest release.

.OUTPUTS
    PSCustomObject { Source; Version; Exe }
#>
    param(
        [Parameter(Mandatory=$true)][string] $PythonExe,
        [bool]   $NonInteractive = $false,
        [string] $PinnedVersion  = ''
    )

    $exe = Get-UvExe
    if ($exe) {
        Add-ToolDirsToPath -Directories @((Split-Path $exe -Parent)) -Reason 'uv CLI' | Out-Null
        $version = Get-UvVersion
        return [pscustomobject]@{ Source = 'existing'; Version = $version; Exe = $exe }
    }

    # Auto-install via pip - cross-platform, no web script download required.
    $versionSpec  = if ($PinnedVersion) { "uv==$PinnedVersion" } else { 'uv' }
    $versionLabel = if ($PinnedVersion) { "v$PinnedVersion" } else { 'latest' }
    Write-Banner "uv not found. Installing ($versionLabel) via pip ..." 'WARN'

    if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
        $msg = "uv is not installed and the selected Python interpreter cannot be used to install it: $PythonExe"
        if ($NonInteractive) { throw $msg }
        Exit-WithError -Message $msg
    }

    try {
        $result = Invoke-NativeCommand `
            -Executable $PythonExe `
            -Arguments  @('-m', 'pip', 'install', '--quiet', $versionSpec) `
            -FailureMessage "pip install uv failed."
        if (-not $result.Succeeded) {
            throw "pip install uv exited with code $($result.ExitCode)."
        }
    } catch {
        $msg = "Failed to install uv via pip: $($_.Exception.Message)"
        if ($NonInteractive) { throw $msg }
        Exit-WithError -Message $msg
    }

    # Refresh PATH so the newly installed uv executable is visible,
    # then re-run Get-UvExe which checks PATH + known fallback locations.
    Add-PythonScriptsDirToPath -PythonExe $PythonExe
    $exe = Get-UvExe

    if (-not $exe) {
        throw "uv installation via pip completed but executable could not be located.`nRestart your shell and re-run setup."
    }

    $version = Get-UvVersion
    Write-Banner "uv installed via pip. Version: $version" 'SUCCESS'
    Write-Host ("  uv executable: {0}" -f $exe) -ForegroundColor Green
    Write-Host ("  uv install dir: {0}" -f (Split-Path $exe -Parent)) -ForegroundColor Green
    return [pscustomobject]@{ Source = 'installed'; Version = $version; Exe = $exe }
}


# ---------------------------------------------------------------------------
# Project operations
# ---------------------------------------------------------------------------

function Invoke-UvVenv {
<#
.SYNOPSIS
    Creates the project .venv at VenvDir using the selected Python interpreter.
    Equivalent to 'poetry env use <python>' + venv creation.
#>
    param(
        [Parameter(Mandatory=$true)][string] $PythonExe,
        [Parameter(Mandatory=$true)][string] $VenvDir,
        [Parameter(Mandatory=$true)][string] $UvExe
    )
    Invoke-NativeCommand `
        -Executable  $UvExe `
        -Arguments   @('venv', '--python', $PythonExe, $VenvDir) `
        -PassThrough `
        -ThrowOnError `
        -FailureMessage "'uv venv' failed to create virtual environment." | Out-Null
}

function Invoke-UvSync {
<#
.SYNOPSIS
    Runs 'uv sync' to install exact versions from uv.lock into .venv (PinExact mode).
    Equivalent to 'poetry install'.  Creates uv.lock if it does not exist.

.DESCRIPTION
    With [dependency-groups] (PEP 735), uv includes the 'dev' group by default.
    --all-extras is also passed when IncludeDev=$true so any
    [project.optional-dependencies] extras are installed.
    Pass IncludeDev=$false to add --no-dev and skip the dev group.
#>
    param(
        [Parameter(Mandatory=$true)][string] $ProjectRoot,
        [Parameter(Mandatory=$true)][string] $UvExe,
        [bool] $IncludeDev = $true
    )
    $uvArgs = @('sync')
    if ($IncludeDev) {
        $uvArgs += '--all-extras'   # [project.optional-dependencies] extras
        # [dependency-groups.dev] is included by uv by default — no extra flag needed.
    } else {
        $uvArgs += '--no-dev'       # excludes the dev dependency group
    }

    Invoke-NativeCommand `
        -Executable       $UvExe `
        -Arguments        $uvArgs `
        -WorkingDirectory $ProjectRoot `
        -PassThrough `
        -ThrowOnError `
        -FailureMessage   "'uv sync' failed -- see output above." | Out-Null
}

function Invoke-UvSyncUpgrade {
<#
.SYNOPSIS
    Runs 'uv sync --upgrade' to re-resolve all dependencies to the latest
    versions allowed by pyproject.toml and rewrite uv.lock.
    Equivalent to 'poetry update'.  This is the DEFAULT setup behaviour.
#>
    param(
        [Parameter(Mandatory=$true)][string] $ProjectRoot,
        [Parameter(Mandatory=$true)][string] $UvExe,
        [bool] $IncludeDev = $true
    )
    $uvArgs = @('sync', '--upgrade')
    if ($IncludeDev) {
        $uvArgs += '--all-extras'
    } else {
        $uvArgs += '--no-dev'
    }

    Invoke-NativeCommand `
        -Executable       $UvExe `
        -Arguments        $uvArgs `
        -WorkingDirectory $ProjectRoot `
        -PassThrough `
        -ThrowOnError `
        -FailureMessage   "'uv sync --upgrade' failed -- see output above." | Out-Null
}

function Invoke-UvSyncUpgradePackage {
<#
.SYNOPSIS
    Runs 'uv sync --upgrade-package <name> ...' to re-resolve only the named
    packages (and their transitive dependencies) to the latest versions allowed
    by pyproject.toml, then rewrites uv.lock for those entries only.

.DESCRIPTION
    All other locked versions are left untouched.  This is the correct way to
    refresh a Git-branch-ref dependency (e.g. an Azure DevOps library pinned to
    'main') without upgrading every package in the environment.

    Typical usage:
        Invoke-UvSyncUpgradePackage -ProjectRoot $root -UvExe $uv -Packages @('my-lib')

.PARAMETER Packages
    One or more package names to upgrade.  Each name is passed as a separate
    '--upgrade-package <name>' argument.
#>
    param(
        [Parameter(Mandatory=$true)][string]   $ProjectRoot,
        [Parameter(Mandatory=$true)][string]   $UvExe,
        [Parameter(Mandatory=$true)][string[]] $Packages,
        [bool] $IncludeDev = $true
    )
    $uvArgs = @('sync')
    foreach ($pkg in $Packages) {
        $uvArgs += @('--upgrade-package', $pkg)
    }
    if ($IncludeDev) {
        $uvArgs += '--all-extras'
    } else {
        $uvArgs += '--no-dev'
    }

    Invoke-NativeCommand `
        -Executable       $UvExe `
        -Arguments        $uvArgs `
        -WorkingDirectory $ProjectRoot `
        -PassThrough `
        -ThrowOnError `
        -FailureMessage   "'uv sync --upgrade-package' failed -- see output above." | Out-Null
}

function Invoke-UvLock {
<#
.SYNOPSIS
    Runs 'uv lock' to synchronize uv.lock with the current pyproject.toml.
    Creates uv.lock if it does not exist; updates it for additions/removals
    without upgrading already-pinned packages.
    Equivalent to 'poetry lock --no-update'.
#>
    param(
        [Parameter(Mandatory=$true)][string] $ProjectRoot,
        [Parameter(Mandatory=$true)][string] $UvExe
    )
    Invoke-NativeCommand `
        -Executable       $UvExe `
        -Arguments        @('lock') `
        -WorkingDirectory $ProjectRoot `
        -PassThrough `
        -ThrowOnError `
        -FailureMessage   "'uv lock' failed -- see output above." | Out-Null
}

Export-ModuleMember -Function `
    Get-UvExe, `
    Test-UvAvailable, `
    Get-UvVersion, `
    Initialize-UvRuntime, `
    Invoke-UvVenv, `
    Invoke-UvSync, `
    Invoke-UvSyncUpgrade, `
    Invoke-UvSyncUpgradePackage, `
    Invoke-UvLock
