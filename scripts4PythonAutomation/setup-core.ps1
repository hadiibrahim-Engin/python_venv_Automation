#Requires -Version 5.1
# =============================================================================
# Script  : setup-core.ps1   (BACKWARD-COMPATIBILITY WRAPPER)
# Author  : Hadi Ibrahim
#
# This file used to be the main entry point. It is now a thin compatibility
# wrapper around the distributable PythonVenvAutomation module so that existing
# command lines keep working unchanged:
#
#   .\scripts4PythonAutomation\setup-core.ps1
#   .\scripts4PythonAutomation\setup-core.ps1 -DryRun
#   .\scripts4PythonAutomation\setup-core.ps1 -Mode update-venv
#   .\scripts4PythonAutomation\setup-core.ps1 -ForceRecreateVenv
#
# The recommended interface is the global 'devsetup' command (see README).
#
# Behavior:
#   1. Import the installed PythonVenvAutomation module; if that fails, fall back
#      to the local module shipped in this repository (resolved via $PSScriptRoot).
#   2. Forward all parameters to Invoke-PythonVenvSetup.
#   3. Preserve the legacy project-root semantics (the repository root, i.e. the
#      parent of scripts4PythonAutomation) and parent-shell activation.
# =============================================================================

param(
    [Parameter()] [string] $PythonExePath,
    [Parameter()] [switch] $UpdateDependencies,
    [Parameter()] [switch] $PinExact,
    [Parameter()] [switch] $ExcludeDev,
    [Parameter()] [switch] $DryRun,
    [Parameter()] [switch] $ListMode,
    [Parameter()] [ValidateSet('uv','poetry','auto')] [string] $PackageManager = 'auto',
    [Parameter()] [ValidateSet('setup','update-venv','venv-update','refresh-venv')] [string] $Mode = 'setup',
    [Parameter()] [switch] $ContinueOnPrecheckFailure,
    [Parameter()] [Alias('RecreateVenv')] [switch] $ForceRecreateVenv,
    [Parameter()] [switch] $NonInteractive,
    [Parameter()] [object] $EnableCodeSigning = $true,
    [Parameter()] [string] $DigiCertUtilityExe = $(if ($env:DIGICERT_UTILITY_EXE) { $env:DIGICERT_UTILITY_EXE } else { 'C:\Program Files\DigiCertUtility\DigiCertUtil.exe' }),
    [Parameter()] [switch] $KernelDriverSigning,
    [Parameter()] [switch] $SignPoetryOnly,
    [Parameter()] [object] $RequirePmShimSigning = $true,
    [Parameter()] [string] $PinnedPoetryVersion = '',
    [Parameter()] [string] $PinnedUvVersion = '',
    [Parameter()] [switch] $AllowPythonInstall,
    [Parameter()] [switch] $SkipPythonInstall,
    [Parameter()] [string] $UpgradePackage = '',
    [Parameter()] [switch] $UnblockScripts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# VS Code isolation: the PowerShell extension opens files passed to Import-Module
# in the editor. Re-launch in a plain subprocess not connected to the extension.
# The SETUP_SUBPROCESS guard prevents infinite recursion.
if (($env:TERM_PROGRAM -eq 'vscode' -or $env:VSCODE_PID) -and -not $env:SETUP_SUBPROCESS) {
    $env:SETUP_SUBPROCESS = '1'
    $ps = if (Get-Command 'pwsh' -ErrorAction SilentlyContinue) {
        (Get-Command 'pwsh').Source
    } else {
        "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    }
    # Reconstruct the original arguments from the bound parameters so the child
    # process receives exactly what the user passed.
    $forwardArgs = @('-NoProfile', '-File', $MyInvocation.MyCommand.Path)
    foreach ($name in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$name]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $forwardArgs += "-$name" }
        } else {
            $forwardArgs += @("-$name", "$value")
        }
    }
    & "$ps" @forwardArgs
    $childExitCode = $LASTEXITCODE

    # Re-apply activation in the parent shell (child activation does not persist).
    if ($childExitCode -eq 0 -and -not $DryRun) {
        $activateScript = Join-Path $PSScriptRoot 'activate-venv.ps1'
        if (Test-Path $activateScript -PathType Leaf) {
            try { . $activateScript } catch {
                Write-Host ("[WARN] [POST] [Activation] Could not activate .venv in parent shell: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                Write-Host "Run manually: . .\scripts4PythonAutomation\activate-venv.ps1" -ForegroundColor Yellow
            }
        }
    }

    $env:SETUP_SUBPROCESS = $null
    exit $childExitCode
}

# Import the installed module; fall back to the local repo copy via $PSScriptRoot.
try {
    Import-Module PythonVenvAutomation -ErrorAction Stop
} catch {
    $localManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'PythonVenvAutomation\PythonVenvAutomation.psd1'
    if (-not (Test-Path -LiteralPath $localManifest -PathType Leaf)) {
        Write-Host "Could not import PythonVenvAutomation (installed or local at $localManifest)." -ForegroundColor Red
        if (-not $NonInteractive) { Read-Host "`nPress Enter to exit" }
        exit 1
    }
    Import-Module $localManifest -Force -ErrorAction Stop
}

# Legacy semantics: the project being set up is the repository root (the parent
# of scripts4PythonAutomation), regardless of the caller's current directory.
$legacyProjectRoot = (Split-Path $PSScriptRoot -Parent)

try {
    $forward = @{}
    foreach ($name in $PSBoundParameters.Keys) { $forward[$name] = $PSBoundParameters[$name] }
    if (-not $forward.ContainsKey('ProjectRoot')) { $forward['ProjectRoot'] = $legacyProjectRoot }

    Invoke-PythonVenvSetup @forward | Out-Null
    exit 0
} catch {
    # Invoke-PythonVenvSetup / Start-Setup already printed the failure detail.
    exit 1
}
