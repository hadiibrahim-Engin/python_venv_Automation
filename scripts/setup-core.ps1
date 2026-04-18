#Requires -Version 5.1
# =============================================================================
# Script  : setup-core.ps1

# Author  : Hadi Ibrahim
#
# Entry point for the Python environment setup pipeline.
# Run directly from a PowerShell console (pwsh or powershell.exe):
#
#   .\scripts\setup-core.ps1                              # auto-detects uv or poetry
#   .\scripts\setup-core.ps1 -PackageManager uv            # force UV
#   .\scripts\setup-core.ps1 -PackageManager poetry        # force Poetry
#   .\scripts\setup-core.ps1 -UpdateDependencies           # re-resolve + upgrade all deps
#   .\scripts\setup-core.ps1 -ExcludeDev                   # production deps only
#   .\scripts\setup-core.ps1 -DryRun                       # preview pipeline, no changes
#   .\scripts\setup-core.ps1 -ListMode                     # pick Python interactively
#   .\scripts\setup-core.ps1 -PythonExePath "C:\Python311\python.exe"
#
# If PowerShell blocks execution due to ExecutionPolicy, run once with:
#   powershell.exe -ExecutionPolicy Bypass -File .\scripts\setup-core.ps1
# =============================================================================

param(
    [Parameter()]
    [string] $PythonExePath,

    [Parameter()]
    [switch] $UpdateDependencies,

    [Parameter()]
    [switch] $ExcludeDev,

    [Parameter()]
    [switch] $DryRun,

    [Parameter()]
    [switch] $ListMode,

    [Parameter()]
    [ValidateSet('uv','poetry','auto')]
    [string] $PackageManager = 'auto',

    # By default setup stops when any precheck fails (even auto-fixed non-critical ones).
    # Pass this switch to allow setup to continue past precheck failures.
    [Parameter()]
    [switch] $ContinueOnPrecheckFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The Python interpreter prompt was moved inside Start-Setup (after prechecks).
# Here we only capture explicit CLI overrides so they can be forwarded to the subprocess.
$resolvedPythonExePath = if ($PSBoundParameters.ContainsKey('PythonExePath')) { $PythonExePath } else { $null }
$resolvedListMode      = [bool]$ListMode

# VS Code isolation
# VS Code's PowerShell extension opens every file passed to Import-Module in the
# editor automatically.  Re-launch in a plain powershell.exe subprocess that is
# not connected to the extension so the module files stay closed.
# The SETUP_SUBPROCESS guard prevents infinite recursion.
if (($env:TERM_PROGRAM -eq 'vscode' -or $env:VSCODE_PID) -and -not $env:SETUP_SUBPROCESS) {
    $env:SETUP_SUBPROCESS = '1'
    $ps = if (Get-Command 'pwsh' -ErrorAction SilentlyContinue) {
        (Get-Command 'pwsh').Source
    } else {
        "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    }
    $forwardArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path)
    if ($resolvedPythonExePath) {
        $forwardArgs += @('-PythonExePath', $resolvedPythonExePath)
    }
    if ($UpdateDependencies) {
        $forwardArgs += @('-UpdateDependencies')
    }
    if ($ExcludeDev) {
        $forwardArgs += @('-ExcludeDev')
    }
    if ($DryRun) {
        $forwardArgs += @('-DryRun')
    }
    if ($resolvedListMode) {
        $forwardArgs += @('-ListMode')
    }
    # Only forward PackageManager when the user explicitly set it.
    # 'auto' is the default — the subprocess detects it independently.
    if ($PackageManager -ne 'auto') {
        $forwardArgs += @('-PackageManager', $PackageManager)
    }
    if ($ContinueOnPrecheckFailure) {
        $forwardArgs += @('-ContinueOnPrecheckFailure')
    }
    & "$ps" @forwardArgs
    $childExitCode = $LASTEXITCODE

    # Activation done inside the detached child process does not persist back
    # to this original shell. Re-apply activation here on success.
    if ($childExitCode -eq 0) {
        $activateScript = Join-Path $PSScriptRoot 'activate-venv.ps1'
        if (Test-Path $activateScript -PathType Leaf) {
            try {
                . $activateScript
            } catch {
                Write-Host ("[WARN] [POST] [Activation] Could not activate .venv in parent shell: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                Write-Host "Run manually: . .\scripts\activate-venv.ps1" -ForegroundColor Yellow
            }
        }
    }

    $env:SETUP_SUBPROCESS = $null
    exit $childExitCode
}

# Unblock all module files in this directory tree.
# Files extracted from a zip or cloned via browser download carry a Zone.Identifier
# NTFS stream that causes PowerShell to refuse loading them under RemoteSigned / AllSigned policy.
Get-ChildItem -Path $PSScriptRoot -Recurse -Include '*.ps1','*.psm1','*.psd1' -ErrorAction SilentlyContinue |
    ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }

# Compute project root (scripts\ is the module location; project root is its parent)
$ProjectRoot = (Split-Path $PSScriptRoot -Parent)

# Import the root module
$rootModule = Join-Path $PSScriptRoot 'Setup-Core.psm1'
if (-not (Test-Path $rootModule -PathType Leaf)) {
    Write-Host "Could not find root module at: $rootModule" -ForegroundColor Red
    Read-Host "`nPress Enter to exit"
    exit 1
}

Import-Module $rootModule -Force

try {
    $setupParams = @{
        ProjectRoot        = $ProjectRoot
        ForceRecreateVenv  = $true
        SkipPoetryInstall  = $false
        NonInteractive     = $false
        UpdateDependencies = [bool]$UpdateDependencies
        IncludeDev         = (-not [bool]$ExcludeDev)
        ListMode           = $resolvedListMode
        PackageManager     = $PackageManager
    }
    if ($DryRun)                     { $setupParams.DryRun = $true }
    if ($resolvedPythonExePath)      { $setupParams.PythonExePath = $resolvedPythonExePath }
    if ($ContinueOnPrecheckFailure)  { $setupParams.StopOnPrecheckFailure = $false }

    Start-Setup @setupParams | Out-Null
    exit 0
} catch {
    if (Get-Command -Name Get-SetupErrorDetails -ErrorAction SilentlyContinue) {
        $details = Get-SetupErrorDetails -ErrorRecord $_
        Write-Host ''
        Write-Host 'Setup failed.' -ForegroundColor Red
        Write-Host ("Message         : {0}" -f $details.Message) -ForegroundColor Red
        Write-Host ("Module/Function : {0}" -f $details.Command) -ForegroundColor Red
        Write-Host ("Location        : {0}" -f $details.Location) -ForegroundColor Red
        Write-Host ("Category/ErrorId: {0} / {1}" -f $details.Category, $details.ErrorId) -ForegroundColor DarkRed
        if ($details.Stack) {
            Write-Host 'Stack trace:' -ForegroundColor DarkRed
            Write-Host $details.Stack -ForegroundColor DarkGray
        }
    }
    exit 1
}
