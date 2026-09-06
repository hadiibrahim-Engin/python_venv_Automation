#Requires -Version 5.1
# =============================================================================
# Script : setup-core.ps1 (backward-compatibility wrapper)
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
    [Parameter()] [string] $DigiCertUtilityExe = '',
    [Parameter()] [switch] $KernelDriverSigning,
    [Parameter()] [switch] $SignPoetryOnly,
    [Parameter()] [object] $RequirePmShimSigning = $true,
    [Parameter()] [string] $PinnedPoetryVersion = '',
    [Parameter()] [string] $PinnedUvVersion = '',
    [Parameter()] [switch] $AllowPythonInstall,
    [Parameter()] [switch] $SkipPythonInstall,
    [Parameter()] [string] $UpgradePackage = '',
    [Parameter()] [switch] $UnblockScripts,
    [Parameter()] [switch] $SkipGitPull,
    [Parameter()] [switch] $ForceGitPull,
    [Parameter()] [ValidateSet('DEBUG','INFO','WARN','ERROR')] [string] $LogLevel = 'INFO'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (($env:TERM_PROGRAM -eq 'vscode' -or $env:VSCODE_PID) -and -not $env:SETUP_SUBPROCESS) {
    $env:SETUP_SUBPROCESS = '1'
    $ps = if (Get-Command 'pwsh' -ErrorAction SilentlyContinue) { (Get-Command 'pwsh').Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
    $forwardArgs = @('-NoProfile','-File',$MyInvocation.MyCommand.Path)
    foreach ($name in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$name]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $forwardArgs += "-$name" }
        } else { $forwardArgs += @("-$name","$value") }
    }
    & "$ps" @forwardArgs
    $childExitCode = $LASTEXITCODE
    if ($childExitCode -eq 0 -and -not $DryRun) {
        $activateScript = Join-Path $PSScriptRoot 'activate-venv.ps1'
        if (Test-Path -LiteralPath $activateScript -PathType Leaf) {
            try { . $activateScript } catch { Write-Warning ("Could not activate .venv in parent shell: {0}" -f $_.Exception.Message) }
        }
    }
    $env:SETUP_SUBPROCESS = $null
    exit $childExitCode
}

try { Import-Module PythonVenvAutomation -ErrorAction Stop }
catch {
    $localManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'PythonVenvAutomation\PythonVenvAutomation.psd1'
    if (-not (Test-Path -LiteralPath $localManifest -PathType Leaf)) {
        Write-Host "Could not import PythonVenvAutomation (installed or local at $localManifest)." -ForegroundColor Red
        exit 1
    }
    Import-Module $localManifest -Force -ErrorAction Stop
}

$legacyProjectRoot = Split-Path $PSScriptRoot -Parent
try {
    $forward = @{}
    foreach ($name in $PSBoundParameters.Keys) { $forward[$name] = $PSBoundParameters[$name] }
    $forward.ProjectRoot = $legacyProjectRoot
    Invoke-PythonVenvSetup @forward | Out-Null
    exit 0
} catch { exit 1 }
