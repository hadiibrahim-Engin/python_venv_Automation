function Invoke-PythonVenvSetup {
    <#
    .SYNOPSIS
        Public entry point that wraps the existing Start-Setup engine.

    .DESCRIPTION
        Preserves the full option surface of the legacy setup-core.ps1 and the
        existing setup behavior. It performs the same argument normalization the
        old entry point did (boolean coercion, non-interactive/CI resolution,
        -UpgradePackage parsing) and then calls Start-Setup. The setup pipeline
        itself is unchanged.

        ProjectRoot defaults to the current directory, which is the project the
        user wants to set up when invoking the global command.

    .EXAMPLE
        Invoke-PythonVenvSetup
    .EXAMPLE
        Invoke-PythonVenvSetup -Mode update-venv
    .EXAMPLE
        Invoke-PythonVenvSetup -DryRun -PackageManager uv
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $ProjectRoot,

        [Parameter()]
        [string] $PythonExePath,

        [Parameter()]
        [switch] $UpdateDependencies,

        [Parameter()]
        [switch] $PinExact,

        [Parameter()]
        [switch] $ExcludeDev,

        [Parameter()]
        [switch] $DryRun,

        [Parameter()]
        [switch] $ListMode,

        [Parameter()]
        [ValidateSet('uv', 'poetry', 'auto')]
        [string] $PackageManager = 'auto',

        [Parameter()]
        [ValidateSet('setup', 'update-venv', 'venv-update', 'refresh-venv')]
        [string] $Mode = 'setup',

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

        [Parameter()]
        [switch] $AllowPythonInstall,

        [Parameter()]
        [switch] $SkipPythonInstall,

        [Parameter()]
        [string] $UpgradePackage = '',

        [Parameter()]
        [switch] $UnblockScripts
    )

    Set-StrictMode -Version Latest

    if (-not $Script:PythonVenvAutomationEngineLoaded) {
        throw ("The Python setup engine (Start-Setup) is not available. Expected it under the module's engine\ folder or the source-tree scripts4PythonAutomation\Setup-Core.psm1. " +
               'This automation is Windows-only; the engine cannot load on a non-Windows host.')
    }

    # --- Resolve project root (defaults to the caller's current directory) ---
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }

    # --- Normalize arguments (ports the legacy setup-core.ps1 logic) ---------
    $resolvedPythonExePath  = if ($PSBoundParameters.ContainsKey('PythonExePath')) { $PythonExePath } else { $null }
    $resolvedNonInteractive = [bool]$NonInteractive -or [bool]$DryRun -or ($env:CI -match '^(1|true|yes)$')
    $resolvedEnableCodeSigning    = Convert-DevSetupBool -Value $EnableCodeSigning -Name 'EnableCodeSigning'
    $resolvedRequirePmShimSigning = Convert-DevSetupBool -Value $RequirePmShimSigning -Name 'RequirePmShimSigning'

    $resolvedAllowPythonInstall = if ($PSBoundParameters.ContainsKey('AllowPythonInstall')) { [bool]$AllowPythonInstall } else { $true }
    if ($SkipPythonInstall) { $resolvedAllowPythonInstall = $false }

    # -UpgradePackage: comma/semicolon-separated -> trimmed, unique string[].
    [string[]] $resolvedUpgradePackages = @()
    if ($UpgradePackage) {
        $resolvedUpgradePackages = @($UpgradePackage -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    }

    if ($UnblockScripts) {
        # Unblock the engine/module files if download metadata is blocking imports.
        $unblockRoots = @($Script:PythonVenvAutomationModuleRoot)
        if ($Script:PythonVenvAutomationEnginePath) {
            $unblockRoots += (Split-Path -Parent $Script:PythonVenvAutomationEnginePath)
        }
        foreach ($root in ($unblockRoots | Where-Object { $_ } | Select-Object -Unique)) {
            Get-ChildItem -Path $root -Recurse -Include '*.ps1', '*.psm1', '*.psd1' -ErrorAction SilentlyContinue |
                ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
        }
    }

    $setupParams = @{
        ProjectRoot          = $ProjectRoot
        ForceRecreateVenv    = [bool]$ForceRecreateVenv
        SkipPoetryInstall    = $false
        NonInteractive       = $resolvedNonInteractive
        EnableCodeSigning    = $resolvedEnableCodeSigning
        DigiCertUtilityExe   = $DigiCertUtilityExe
        KernelDriverSigning  = [bool]$KernelDriverSigning
        SignPoetryOnly       = [bool]$SignPoetryOnly
        RequirePmShimSigning = $resolvedRequirePmShimSigning
        UpdateDependencies   = [bool]$UpdateDependencies
        PinExact             = [bool]$PinExact
        IncludeDev           = (-not [bool]$ExcludeDev)
        ListMode             = [bool]$ListMode
        PackageManager       = $PackageManager
        Mode                 = $Mode
        PinnedPoetryVersion  = $PinnedPoetryVersion
        PinnedUvVersion      = $PinnedUvVersion
        AllowPythonInstall   = $resolvedAllowPythonInstall
        UpgradePackages      = $resolvedUpgradePackages
    }
    if ($DryRun)                    { $setupParams.DryRun = $true }
    if ($resolvedPythonExePath)     { $setupParams.PythonExePath = $resolvedPythonExePath }
    if ($ContinueOnPrecheckFailure) { $setupParams.StopOnPrecheckFailure = $false }

    Start-Setup @setupParams
}

function Convert-DevSetupBool {
    <#
    .SYNOPSIS
        Coerces user-supplied boolean-ish values (ported from setup-core.ps1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Value,
        [Parameter(Mandatory)] [string] $Name
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
