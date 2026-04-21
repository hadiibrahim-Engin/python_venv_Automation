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
    Handles uv availability checks, installation via the official astral.sh
    installer, virtual-environment creation, and dependency sync.

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
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'NativeCommand.psm1')  -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Filesystem.psm1')     -Force -DisableNameChecking -ErrorAction Stop


# ---------------------------------------------------------------------------
# Discovery helpers
# ---------------------------------------------------------------------------

function Get-UvExe {
<#
.SYNOPSIS
    Returns the full path to the uv executable, or $null when not found.
    Checks PATH first, then common pip/astral.sh install locations.
#>
    $cmd = Get-Command 'uv' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Fallback: astral.sh default on Linux, and pip posix_user install on Linux
    $posixFallback = Resolve-Path '~/.local/bin/uv' -ErrorAction SilentlyContinue
    if ($posixFallback -and (Test-Path -LiteralPath $posixFallback.Path -PathType Leaf)) {
        return $posixFallback.Path
    }

    # Fallback: pip --user install on Windows lands in %APPDATA%\Python\Scripts\ or
    # %APPDATA%\Python\PythonXXX\Scripts\ depending on the pip version.
    if ($env:OS -eq 'Windows_NT' -and $env:APPDATA) {
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
    Ensures uv is available; installs it via the official installer if missing.

.DESCRIPTION
    Uses a safe two-step install: download the installer script to a temp file,
    then execute it in a separate PowerShell process.  This isolates the
    installer from the current session and avoids Invoke-Expression on
    downloaded content.

.PARAMETER NonInteractive
    Throw on failure instead of prompting.

.PARAMETER PinnedVersion
    When specified, installs exactly this uv version (e.g. '0.6.14').
    When omitted, installs the latest release.

.OUTPUTS
    PSCustomObject { Source; Version; Exe }
#>
    param(
        [bool]   $NonInteractive = $false,
        [string] $PinnedVersion  = ''
    )

    $exe = Get-UvExe
    if ($exe) {
        $version = Get-UvVersion
        return [pscustomobject]@{ Source = 'existing'; Version = $version; Exe = $exe }
    }

    # Auto-install via pip - cross-platform, no web script download required.
    $versionSpec  = if ($PinnedVersion) { "uv==$PinnedVersion" } else { 'uv' }
    $versionLabel = if ($PinnedVersion) { "v$PinnedVersion" } else { 'latest' }
    Write-Banner "uv not found. Installing ($versionLabel) via pip ..." 'WARN'

    # Find any Python on PATH to run pip with.
    $pythonExe = Get-CommandSource 'python'
    if (-not $pythonExe) {
        $pythonExe = Get-CommandSource 'python3'
    }
    if (-not $pythonExe) {
        $msg = "uv is not installed and no Python interpreter was found on PATH to install it with.`nInstall Python first, then re-run setup."
        if ($NonInteractive) { throw $msg }
        Exit-WithError -Message $msg
    }

    try {
        $result = Invoke-NativeCommand `
            -Executable $pythonExe `
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
    Add-PythonScriptsDirToPath -PythonExe $pythonExe
    $exe = Get-UvExe

    if (-not $exe) {
        throw "uv installation via pip completed but executable could not be located.`nRestart your shell and re-run setup."
    }

    $version = Get-UvVersion
    Write-Banner "uv installed via pip. Version: $version" 'SUCCESS'
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
        -Executable $UvExe `
        -Arguments  @('venv', '--python', $PythonExe, $VenvDir) `
        -ThrowOnError `
        -FailureMessage "'uv venv' failed to create virtual environment." | Out-Null
}

function Invoke-UvSync {
<#
.SYNOPSIS
    Runs 'uv sync' to install exact versions from uv.lock into .venv.
    Equivalent to 'poetry install'.  Creates uv.lock if it does not exist.
#>
    param(
        [Parameter(Mandatory=$true)][string] $ProjectRoot,
        [Parameter(Mandatory=$true)][string] $UvExe,
        [bool] $IncludeDev = $true
    )
    $uvArgs = @('sync')
    if ($IncludeDev) { $uvArgs += '--all-extras' }

    Invoke-NativeCommand `
        -Executable       $UvExe `
        -Arguments        $uvArgs `
        -WorkingDirectory $ProjectRoot `
        -ThrowOnError `
        -FailureMessage   "'uv sync' failed -- see output above." | Out-Null
}

function Invoke-UvSyncUpgrade {
<#
.SYNOPSIS
    Runs 'uv sync --upgrade' to re-resolve all dependencies to the latest
    versions allowed by pyproject.toml and rewrite uv.lock.
    Equivalent to 'poetry update'.
#>
    param(
        [Parameter(Mandatory=$true)][string] $ProjectRoot,
        [Parameter(Mandatory=$true)][string] $UvExe,
        [bool] $IncludeDev = $true
    )
    $uvArgs = @('sync', '--upgrade')
    if ($IncludeDev) { $uvArgs += '--all-extras' }

    Invoke-NativeCommand `
        -Executable       $UvExe `
        -Arguments        $uvArgs `
        -WorkingDirectory $ProjectRoot `
        -ThrowOnError `
        -FailureMessage   "'uv sync --upgrade' failed -- see output above." | Out-Null
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
    Invoke-UvLock