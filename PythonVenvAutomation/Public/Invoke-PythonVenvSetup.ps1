function Invoke-PythonVenvSetup {
    <#
    .SYNOPSIS
        Public entry point that wraps the existing Start-Setup engine.

    .DESCRIPTION
        Preserves the full option surface of the legacy setup-core.ps1 and the
        existing setup behavior. It performs argument normalization, optionally
        performs a safe Git synchronization before setup, and then calls
        Start-Setup.

        Git synchronization is conservative by default: dirty repositories are
        skipped, only fast-forward pulls are allowed, and destructive reset is
        only possible with the explicit -ForceGitPull switch.

        ProjectRoot defaults to the current directory, which is the project the
        user wants to set up when invoking the global command.

    .PARAMETER SkipGitPull
        Disables the pre-setup Git synchronization for this run, regardless of
        the project config.

    .PARAMETER ForceGitPull
        Explicitly allows GitSync to reset tracked local changes/commits to the
        configured upstream. This is the only path that enables destructive
        Git alignment. Untracked files are never deleted automatically.

    .EXAMPLE
        Invoke-PythonVenvSetup

    .EXAMPLE
        Invoke-PythonVenvSetup -Mode update-venv

    .EXAMPLE
        Invoke-PythonVenvSetup -DryRun -PackageManager uv

    .EXAMPLE
        Invoke-PythonVenvSetup -ForceGitPull -Confirm
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
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
        [switch] $UnblockScripts,

        [Parameter()]
        [switch] $SkipGitPull,

        [Parameter()]
        [switch] $ForceGitPull
    )

    Set-StrictMode -Version Latest

    if (-not $Script:PythonVenvAutomationEngineLoaded) {
        throw ("The Python setup engine (Start-Setup) is not available. Expected it under the module's engine\ folder or the source-tree scripts4PythonAutomation\Setup-Core.psm1. " +
               'This automation is Windows-only; the engine cannot load on a non-Windows host.')
    }

    # --- Resolve project root (defaults to the caller's current directory) ---
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
        throw "Project root does not exist: $ProjectRoot"
    }
    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

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

    # -----------------------------------------------------------------------
    # PHASE 1 / STEP 0: safe Git synchronization.
    #
    # Backward compatibility note: this repository already uses
    # `.setup-config.json` (dash), so the new keys are added to that file rather
    # than introducing the requested `.setup.config.json` spelling and silently
    # splitting configuration across two files.
    # -----------------------------------------------------------------------
    $autoGitPull = $true
    $gitPullStrategy = 'SkipIfDirty'
    $setupConfigPath = Join-Path $ProjectRoot '.setup-config.json'

    if (Test-Path -LiteralPath $setupConfigPath -PathType Leaf) {
        try {
            $setupConfig = Get-Content -LiteralPath $setupConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

            if ($setupConfig.PSObject.Properties.Name -contains 'AutoGitPull') {
                if ($setupConfig.AutoGitPull -isnot [bool]) {
                    throw "AutoGitPull must be a JSON boolean (true/false), not '$($setupConfig.AutoGitPull)'."
                }
                $autoGitPull = [bool]$setupConfig.AutoGitPull
            }

            if ($setupConfig.PSObject.Properties.Name -contains 'GitPullStrategy' -and $setupConfig.GitPullStrategy) {
                $strategyText = ([string]$setupConfig.GitPullStrategy).Trim()
                if ($strategyText.Length -gt 32) {
                    throw 'GitPullStrategy exceeds the maximum allowed length of 32 characters.'
                }
                switch ($strategyText.ToLowerInvariant()) {
                    'skipifdirty'  { $gitPullStrategy = 'SkipIfDirty' }
                    'errorifdirty' { $gitPullStrategy = 'ErrorIfDirty' }
                    default {
                        throw "Invalid GitPullStrategy '$strategyText'. Allowed values: SkipIfDirty, ErrorIfDirty."
                    }
                }
            }
        }
        catch {
            throw "Invalid .setup-config.json Git synchronization configuration: $($_.Exception.Message)"
        }
    }

    if ($SkipGitPull) { $autoGitPull = $false }

    if ($autoGitPull -or $ForceGitPull) {
        $engineRoot = Split-Path -Parent $Script:PythonVenvAutomationEnginePath
        $gitSyncCandidates = @(
            (Join-Path $engineRoot 'SetupCore\modules\GitSync.psm1'),
            (Join-Path $engineRoot 'modules\GitSync.psm1')
        )
        $gitSyncModule = $gitSyncCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $gitSyncModule) {
            throw "Git synchronization is enabled, but GitSync.psm1 could not be found next to the setup engine. Checked: $($gitSyncCandidates -join ', ')"
        }

        Microsoft.PowerShell.Core\Import-Module -FullyQualifiedName $gitSyncModule -Force -DisableNameChecking -Global -ErrorAction Stop

        $skipIfDirty = ($gitPullStrategy -eq 'SkipIfDirty')
        $gitParams = @{
            RepositoryPath = $ProjectRoot
            SkipIfDirty    = $skipIfDirty
            Force          = [bool]$ForceGitPull
            TimeoutSeconds = 10
            WhatIf         = [bool]$DryRun
        }
        if ($PSBoundParameters.ContainsKey('Confirm')) {
            $gitParams.Confirm = [bool]$PSBoundParameters['Confirm']
        }

        $gitResult = Invoke-SafeGitPull @gitParams
        Write-Verbose ("GitSync result: status={0}; branch={1}; upstream={2}; ahead={3}; behind={4}; dirty={5}" -f
            $gitResult.Status, $gitResult.Branch, $gitResult.Upstream, $gitResult.Ahead, $gitResult.Behind, $gitResult.Dirty)
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
        Coerces user-supplied boolean-ish values without evaluating regex input.
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
    if ($text.Length -gt 10) {
        throw ("Invalid boolean value for -{0}: input is longer than 10 characters." -f $Name)
    }

    switch ($text.ToLowerInvariant()) {
        'true'  { return $true }
        '1'     { return $true }
        'yes'   { return $true }
        'on'    { return $true }
        'false' { return $false }
        '0'     { return $false }
        'no'    { return $false }
        'off'   { return $false }
        default {
            throw ("Invalid boolean value for -{0}: '{1}'. Use true/false, 1/0, yes/no, or on/off." -f $Name, $Value)
        }
    }
}
