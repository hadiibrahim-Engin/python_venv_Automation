#Requires -Version 5.1
<#
.SYNOPSIS
    Activate the project virtual environment.

.DESCRIPTION
    Activates the in-project .venv virtual environment created by setup-core.ps1.
    Must be dot-sourced so that environment variables persist in the calling shell:

        . .\activate-venv.ps1

    Running it directly (.\activate-venv.ps1) activates only a transient
    subprocess and has no effect on the current shell.

.EXAMPLE
    . .\activate-venv.ps1
#>

# NOTE: Do NOT set Set-StrictMode or $ErrorActionPreference here.
# This script is designed to be dot-sourced; those settings would leak
# into the caller's session for the rest of the session.

# Activation must run in caller scope to preserve prompt/function changes.
$dotSourced = ($MyInvocation.InvocationName -eq '.') -or ($MyInvocation.Line -match '^\s*\.\s+')
if (-not $dotSourced) {
    Write-Host "ERROR: This script must be dot-sourced to persist activation in your shell." -ForegroundColor Red
    Write-Host "Use: . .\activate-venv.ps1" -ForegroundColor Yellow
    return
}

$projectDir = $PSScriptRoot
$venvCandidates = @(
    (Join-Path $projectDir '.venv'),
    (Join-Path (Split-Path $projectDir -Parent) '.venv')
)

$venvPath = $null
foreach ($candidate in $venvCandidates) {
    if ($candidate -and (Test-Path $candidate -PathType Container)) {
        $venvPath = $candidate
        break
    }
}

if (-not $venvPath) {
    # Keep a deterministic path in error output.
    $venvPath = $venvCandidates[0]
}

$onWindows      = $env:OS -eq 'Windows_NT'
$activateScript = if ($onWindows) {
    Join-Path $venvPath 'Scripts\Activate.ps1'
} else {
    Join-Path $venvPath 'bin/Activate.ps1'
}
$venvPython = if ($onWindows) {
    Join-Path $venvPath 'Scripts\python.exe'
} else {
    Join-Path $venvPath 'bin/python'
}

if (-not (Test-Path $venvPath)) {
    Write-Host "ERROR: .venv not found at: $venvPath" -ForegroundColor Red
    Write-Host "Run setup-core.ps1 first to create the virtual environment." -ForegroundColor Yellow
    return   # 'return' instead of 'exit' -- exit would kill the caller's shell
}

if (-not (Test-Path $activateScript)) {
    Write-Host "ERROR: Activation script not found at: $activateScript" -ForegroundColor Red
    return
}

Write-Host "Activating virtual environment: $projectDir" -ForegroundColor Cyan
. $activateScript

Write-Host ""
$pythonCmd = Get-Command 'python' -ErrorAction SilentlyContinue
$venvPythonOnPath = $pythonCmd -and $pythonCmd.Source -and $pythonCmd.Source.StartsWith($venvPath, [System.StringComparison]::OrdinalIgnoreCase)

if (-not $env:VIRTUAL_ENV -or -not $venvPythonOnPath) {
    Write-Host "ERROR: Activation did not update this shell as expected." -ForegroundColor Red
    Write-Host "VIRTUAL_ENV: $env:VIRTUAL_ENV" -ForegroundColor DarkYellow
    if ($pythonCmd) {
        Write-Host "python resolves to: $($pythonCmd.Source)" -ForegroundColor DarkYellow
    } else {
        Write-Host "python command not found on PATH." -ForegroundColor DarkYellow
    }
    return
}

Write-Host "Virtual environment activated successfully!" -ForegroundColor Green
Write-Host ""

if (Test-Path $venvPython -PathType Leaf) {
    try {
        $pyVersion = & $venvPython --version 2>&1
        Write-Host "Python  : $pyVersion" -ForegroundColor Cyan
    } catch {
        Write-Host "Python version check failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host "Project : $projectDir" -ForegroundColor Cyan
Write-Host "Venv    : $venvPath" -ForegroundColor Cyan
Write-Host ""