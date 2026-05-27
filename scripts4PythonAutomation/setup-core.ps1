#Requires -Version 5.1
# =============================================================================
# Script  : setup-core.ps1

# Author  : Hadi Ibrahim
#
# Windows-only entry point for the Python environment setup pipeline.
# Run directly from a PowerShell console (pwsh or powershell.exe):
#
#   .\scripts4PythonAutomation\setup-core.ps1                                           # auto-detect PM; upgrade ALL deps (default)
#   .\scripts4PythonAutomation\setup-core.ps1 -PackageManager uv                        # force UV
#   .\scripts4PythonAutomation\setup-core.ps1 -PackageManager poetry                    # force Poetry
#   .\scripts4PythonAutomation\setup-core.ps1 -PinExact                                 # install exact lock-file versions (reproducible/CI)
#   .\scripts4PythonAutomation\setup-core.ps1 -UpgradePackage "my-lib"                  # upgrade one package only (e.g. Azure DevOps Git dep)
#   .\scripts4PythonAutomation\setup-core.ps1 -UpgradePackage "my-lib,other-lib"        # upgrade multiple packages only
#   .\scripts4PythonAutomation\setup-core.ps1 -ExcludeDev                               # production deps only
#   .\scripts4PythonAutomation\setup-core.ps1 -UpdateDependencies                       # (backward-compat alias for default; now a no-op)
#   .\scripts4PythonAutomation\setup-core.ps1 -DryRun                       # preview pipeline, no changes
#   .\scripts4PythonAutomation\setup-core.ps1 -ListMode                     # pick Python interactively
#   .\scripts4PythonAutomation\setup-core.ps1 -PythonExePath "C:\Python311\python.exe"
#   .\scripts4PythonAutomation\setup-core.ps1 -ForceRecreateVenv            # rebuild .venv
#   .\scripts4PythonAutomation\setup-core.ps1 -NonInteractive               # CI-safe, no prompts
#   .\scripts4PythonAutomation\setup-core.ps1 -SkipPythonInstall            # disable auto-install fallback
#
# If PowerShell blocks execution because files came from a browser or zip,
# run once with -UnblockScripts after reviewing the project contents.
# =============================================================================

param(
    [Parameter()]
    [string] $PythonExePath,

    # Kept for backward compatibility.  The default behaviour is now to upgrade
    # all dependencies automatically.  Use -PinExact to opt out.
    [Parameter()]
    [switch] $UpdateDependencies,

    # When set, installs the exact versions recorded in the lock file without
    # attempting to upgrade anything.  Use for reproducible / CI builds where
    # you need the identical package set on every run.
    [Parameter()]
    [switch] $PinExact,

    [Parameter()]
    [switch] $ExcludeDev,

    [Parameter()]
    [switch] $DryRun,

    [Parameter()]
    [switch] $ListMode,

    [Parameter()]
    [ValidateSet('uv','poetry','auto')]
    [string] $PackageManager = 'auto',

    # Critical prechecks always stop setup. This switch keeps compatibility with
    # older command lines; non-critical diagnostics already continue by default.
    [Parameter()]
    [switch] $ContinueOnPrecheckFailure,

    [Parameter()]
    [Alias('RecreateVenv')]
    [switch] $ForceRecreateVenv,

    [Parameter()]
    [switch] $NonInteractive,

    [Parameter()]
    [object] $EnableCodeSigning = $true,

    [Parameter()]
    [string] $DigiCertUtilityExe = $(if ($env:DIGICERT_UTILITY_EXE) { $env:DIGICERT_UTILITY_EXE } else { 'C:\Program Files\DigiCertUtility\DigiCertUtil.exe' }),

    [Parameter()]
    [switch] $KernelDriverSigning,

    [Parameter()]
    [switch] $SignPoetryOnly,

    [Parameter()]
    [object] $RequirePmShimSigning = $true,

    [Parameter()]
    [string] $PinnedPoetryVersion = '',

    [Parameter()]
    [string] $PinnedUvVersion = '',

    # Automatic Python installation downloads and runs a python.org installer.
    # Kept for backward compatibility; auto-install is now enabled by default.
    [Parameter()]
    [switch] $AllowPythonInstall,

    # Explicit opt-out for environments where setup must never install Python.
    [Parameter()]
    [switch] $SkipPythonInstall,

    # One or more package names to re-resolve to the latest allowed versions
    # while leaving every other locked version untouched.
    # Comma-separated string (e.g. "my-lib,another-lib") or repeated flag.
    # Use this to refresh an Azure DevOps Git-branch-ref dependency without
    # upgrading everything.  Ignored when -UpdateDependencies is also set.
    [Parameter()]
    [string] $UpgradePackage = '',

    # Only use this when files were downloaded from a browser/zip and PowerShell
    # refuses to load them because of Zone.Identifier metadata.
    [Parameter()]
    [switch] $UnblockScripts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-SetupBool {
    param(
        [Parameter(Mandatory=$true)][object] $Value,
        [Parameter(Mandatory=$true)][string] $Name
    )

    if ($Value -is [bool]) { return $Value }
    if ($Value -is [int]) {
        if ($Value -eq 0) { return $false }
        if ($Value -eq 1) { return $true }
    }

    $text = ([string]$Value).Trim()
    switch -Regex ($text) {
        '^(true|1|yes|on)$'  { return $true }
        '^(false|0|no|off)$' { return $false }
    }

    throw ("Invalid boolean value for -{0}: '{1}'. Use true/false, 1/0, yes/no, or on/off." -f $Name, $Value)
}

# The Python interpreter prompt was moved inside Start-Setup (after prechecks).
# Here we only capture explicit CLI overrides so they can be forwarded to the subprocess.
$resolvedPythonExePath = if ($PSBoundParameters.ContainsKey('PythonExePath')) { $PythonExePath } else { $null }
$resolvedListMode      = [bool]$ListMode
$resolvedNonInteractive = [bool]$NonInteractive -or [bool]$DryRun -or ($env:CI -match '^(1|true|yes)$')
$resolvedEnableCodeSigning = Convert-SetupBool -Value $EnableCodeSigning -Name 'EnableCodeSigning'
$resolvedRequirePmShimSigning = Convert-SetupBool -Value $RequirePmShimSigning -Name 'RequirePmShimSigning'
$resolvedAllowPythonInstall = if ($PSBoundParameters.ContainsKey('AllowPythonInstall')) { [bool]$AllowPythonInstall } else { $true }
if ($SkipPythonInstall) { $resolvedAllowPythonInstall = $false }

# Parse -UpgradePackage: accept comma-separated string, split, trim, deduplicate.
# Two-step assignment avoids a PowerShell 5.1 quirk: 'if/else { @() }' block
# expressions output nothing to the pipeline, so the variable would receive
# $null instead of an empty array, causing .Count to throw under StrictMode.
[string[]] $resolvedUpgradePackages = @()
if ($UpgradePackage) {
    $resolvedUpgradePackages = @($UpgradePackage -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
}

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
    $forwardArgs = @('-NoProfile', '-File', $MyInvocation.MyCommand.Path)
    if ($resolvedPythonExePath) {
        $forwardArgs += @('-PythonExePath', $resolvedPythonExePath)
    }
    if ($UpdateDependencies) {
        $forwardArgs += @('-UpdateDependencies')
    }
    if ($PinExact) {
        $forwardArgs += @('-PinExact')
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
    if ($ForceRecreateVenv) {
        $forwardArgs += @('-ForceRecreateVenv')
    }
    if ($resolvedNonInteractive) {
        $forwardArgs += @('-NonInteractive')
    }
    if ($PSBoundParameters.ContainsKey('EnableCodeSigning')) {
        $forwardArgs += @('-EnableCodeSigning', $resolvedEnableCodeSigning)
    }
    if ($PSBoundParameters.ContainsKey('DigiCertUtilityExe')) {
        $forwardArgs += @('-DigiCertUtilityExe', $DigiCertUtilityExe)
    }
    if ($KernelDriverSigning) {
        $forwardArgs += @('-KernelDriverSigning')
    }
    if ($SignPoetryOnly) {
        $forwardArgs += @('-SignPoetryOnly')
    }
    if ($PSBoundParameters.ContainsKey('RequirePmShimSigning')) {
        $forwardArgs += @('-RequirePmShimSigning', $resolvedRequirePmShimSigning)
    }
    if ($PinnedPoetryVersion) {
        $forwardArgs += @('-PinnedPoetryVersion', $PinnedPoetryVersion)
    }
    if ($PinnedUvVersion) {
        $forwardArgs += @('-PinnedUvVersion', $PinnedUvVersion)
    }
    if (-not $resolvedAllowPythonInstall) {
        $forwardArgs += @('-SkipPythonInstall')
    }
    if ($resolvedUpgradePackages -and $resolvedUpgradePackages.Count -gt 0) {
        # Flatten back to a comma-separated string for the subprocess so it
        # is a single argument that the child's param block can parse again.
        $forwardArgs += @('-UpgradePackage', ($resolvedUpgradePackages -join ','))
    }
    if ($UnblockScripts) {
        $forwardArgs += @('-UnblockScripts')
    }
    & "$ps" @forwardArgs
    $childExitCode = $LASTEXITCODE

    # Activation done inside the detached child process does not persist back
    # to this original shell. Re-apply activation here on success.
    if ($childExitCode -eq 0 -and -not $DryRun) {
        $activateScript = Join-Path $PSScriptRoot 'activate-venv.ps1'
        if (Test-Path $activateScript -PathType Leaf) {
            try {
                . $activateScript
            } catch {
                Write-Host ("[WARN] [POST] [Activation] Could not activate .venv in parent shell: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                Write-Host "Run manually: . .\scripts4PythonAutomation\activate-venv.ps1" -ForegroundColor Yellow
            }
        }
    }

    $env:SETUP_SUBPROCESS = $null
    exit $childExitCode
}

if ($UnblockScripts) {
    # Files extracted from a zip or browser download can carry a Zone.Identifier
    # NTFS stream. Unblocking is explicit so setup does not silently lower policy.
    $scriptFiles = @(Get-ChildItem -Path $PSScriptRoot -Recurse -Include '*.ps1','*.psm1','*.psd1' -ErrorAction SilentlyContinue)
    foreach ($file in $scriptFiles) {
        Write-Host ("Unblocking script file: {0}" -f $file.FullName) -ForegroundColor DarkYellow
        Unblock-File -LiteralPath $file.FullName -ErrorAction SilentlyContinue
    }
}

# Compute project root (scripts4PythonAutomation\ is the module location; project root is its parent)
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
        ForceRecreateVenv  = [bool]$ForceRecreateVenv
        SkipPoetryInstall  = $false
        NonInteractive     = $resolvedNonInteractive
        EnableCodeSigning  = $resolvedEnableCodeSigning
        DigiCertUtilityExe = $DigiCertUtilityExe
        KernelDriverSigning = [bool]$KernelDriverSigning
        SignPoetryOnly     = [bool]$SignPoetryOnly
        RequirePmShimSigning = $resolvedRequirePmShimSigning
        UpdateDependencies = [bool]$UpdateDependencies
        PinExact           = [bool]$PinExact
        IncludeDev         = (-not [bool]$ExcludeDev)
        ListMode           = $resolvedListMode
        PackageManager     = $PackageManager
        PinnedPoetryVersion = $PinnedPoetryVersion
        PinnedUvVersion    = $PinnedUvVersion
        AllowPythonInstall = $resolvedAllowPythonInstall
        UpgradePackages    = $resolvedUpgradePackages
    }
    if ($DryRun)                     { $setupParams.DryRun = $true }
    if ($resolvedPythonExePath)      { $setupParams.PythonExePath = $resolvedPythonExePath }
    if ($ContinueOnPrecheckFailure)  { $setupParams.StopOnPrecheckFailure = $false }

    Start-Setup @setupParams | Out-Null
    exit 0
} catch {
    # Start-Setup already prints the step error and final fatal summary.
    # Keep the wrapper quiet so the same exception is not rendered twice.
    exit 1
}
