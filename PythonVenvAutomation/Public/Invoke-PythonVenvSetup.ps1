function Invoke-PythonVenvSetup {
<#
.SYNOPSIS
    Public entry point for Python environment automation.

.DESCRIPTION
    Resolves project-level configuration, performs safe Git synchronization,
    then invokes the refactored Start-Setup pipeline. Existing call patterns are
    preserved while adding structured logging and stricter validation.

.EXAMPLE
    Invoke-PythonVenvSetup

.EXAMPLE
    Invoke-PythonVenvSetup -Mode update-venv -LogLevel DEBUG

.EXAMPLE
    Invoke-PythonVenvSetup -ForceGitPull -Confirm
#>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        [Parameter()][ValidateScript({ -not $_ -or (Test-Path -LiteralPath $_ -PathType Container) })][string] $ProjectRoot,
        [Parameter()][string] $PythonExePath,
        [Parameter()][switch] $UpdateDependencies,
        [Parameter()][switch] $PinExact,
        [Parameter()][switch] $ExcludeDev,
        [Parameter()][switch] $DryRun,
        [Parameter()][switch] $ListMode,
        [Parameter()][ValidateSet('uv','poetry','auto')][string] $PackageManager = 'auto',
        [Parameter()][ValidateSet('setup','update-venv','venv-update','refresh-venv')][string] $Mode = 'setup',
        [Parameter()][switch] $ContinueOnPrecheckFailure,
        [Parameter()][Alias('RecreateVenv')][switch] $ForceRecreateVenv,
        [Parameter()][switch] $NonInteractive,
        [Parameter()][object] $EnableCodeSigning = $true,
        [Parameter()][string] $DigiCertUtilityExe = '',
        [Parameter()][switch] $KernelDriverSigning,
        [Parameter()][switch] $SignPoetryOnly,
        [Parameter()][object] $RequirePmShimSigning = $true,
        [Parameter()][string] $PinnedPoetryVersion = '',
        [Parameter()][string] $PinnedUvVersion = '',
        [Parameter()][switch] $AllowPythonInstall,
        [Parameter()][switch] $SkipPythonInstall,
        [Parameter()][string] $UpgradePackage = '',
        [Parameter()][switch] $UnblockScripts,
        [Parameter()][switch] $SkipGitPull,
        [Parameter()][switch] $ForceGitPull,
        [Parameter()][ValidateSet('DEBUG','INFO','WARN','ERROR')][string] $LogLevel = 'INFO'
    )

    Set-StrictMode -Version Latest
    if (-not $Script:PythonVenvAutomationEngineLoaded) {
        throw "The Python setup engine (Start-Setup) is not available."
    }

    $constants = Get-SetupConstants
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }
    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

    $resolvedPythonExePath = if ($PSBoundParameters.ContainsKey('PythonExePath')) { $PythonExePath } else { $null }
    $resolvedNonInteractive = [bool]$NonInteractive -or [bool]$DryRun -or [bool]$WhatIfPreference -or ($env:CI -match '^(1|true|yes)$')
    $resolvedEnableCodeSigning = Convert-DevSetupBool -Value $EnableCodeSigning -Name 'EnableCodeSigning'
    $resolvedRequirePmShimSigning = Convert-DevSetupBool -Value $RequirePmShimSigning -Name 'RequirePmShimSigning'
    $resolvedAllowPythonInstall = if ($PSBoundParameters.ContainsKey('AllowPythonInstall')) { [bool]$AllowPythonInstall } else { $true }
    if ($SkipPythonInstall) { $resolvedAllowPythonInstall = $false }

    if (-not $DigiCertUtilityExe) {
        $DigiCertUtilityExe = if ($env:DIGICERT_UTILITY_EXE) { $env:DIGICERT_UTILITY_EXE } else { [string]$constants.CodeSigning.DefaultDigiCertUtilityExe }
    }

    [string[]]$resolvedUpgradePackages = @()
    if ($UpgradePackage) {
        $resolvedUpgradePackages = @($UpgradePackage -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    }

    if ($UnblockScripts) {
        $roots = @($Script:PythonVenvAutomationModuleRoot)
        if ($Script:PythonVenvAutomationEnginePath) { $roots += (Split-Path -Parent $Script:PythonVenvAutomationEnginePath) }
        foreach ($root in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
            Get-ChildItem -Path $root -Recurse -Include '*.ps1','*.psm1','*.psd1' -ErrorAction SilentlyContinue |
                ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
        }
    }

    # Project configuration. CLI values remain authoritative.
    $autoGitPull = $true
    $gitPullStrategy = [string]$constants.Git.DefaultPullStrategy
    $effectiveLogLevel = $LogLevel
    $setupConfigPath = Join-Path $ProjectRoot ([string]$constants.ConfigFileName)
    if (Test-Path -LiteralPath $setupConfigPath -PathType Leaf) {
        try {
            $cfg = Get-Content -LiteralPath $setupConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($cfg.PSObject.Properties.Name -contains 'AutoGitPull') {
                if ($cfg.AutoGitPull -isnot [bool]) { throw 'AutoGitPull must be a JSON boolean.' }
                $autoGitPull = [bool]$cfg.AutoGitPull
            }
            if ($cfg.PSObject.Properties.Name -contains 'GitPullStrategy' -and $cfg.GitPullStrategy) {
                $strategy = ([string]$cfg.GitPullStrategy).Trim()
                if ($strategy.Length -gt [int]$constants.Input.MaxStrategyTextLength) { throw 'GitPullStrategy is too long.' }
                switch ($strategy.ToLowerInvariant()) {
                    'skipifdirty' { $gitPullStrategy = 'SkipIfDirty' }
                    'errorifdirty' { $gitPullStrategy = 'ErrorIfDirty' }
                    default { throw "Invalid GitPullStrategy '$strategy'." }
                }
            }
            if (-not $PSBoundParameters.ContainsKey('LogLevel') -and $cfg.PSObject.Properties.Name -contains 'LogLevel' -and $cfg.LogLevel) {
                $candidateLevel = ([string]$cfg.LogLevel).ToUpperInvariant()
                if ($candidateLevel -notin @('DEBUG','INFO','WARN','ERROR')) { throw "Invalid LogLevel '$candidateLevel'." }
                $effectiveLogLevel = $candidateLevel
            }
        } catch {
            throw "Invalid $($constants.ConfigFileName): $($_.Exception.Message)"
        }
    }

    if ($SkipGitPull) { $autoGitPull = $false }
    if ($autoGitPull -or $ForceGitPull) {
        $engineRoot = Split-Path -Parent $Script:PythonVenvAutomationEnginePath
        $gitSyncModule = @(
            (Join-Path $engineRoot 'SetupCore\modules\GitSync.psm1'),
            (Join-Path $engineRoot 'modules\GitSync.psm1')
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $gitSyncModule) { throw 'Git synchronization is enabled, but GitSync.psm1 was not found.' }
        Microsoft.PowerShell.Core\Import-Module -FullyQualifiedName $gitSyncModule -Force -DisableNameChecking -Global -ErrorAction Stop

        $gitParams = @{
            RepositoryPath = $ProjectRoot
            SkipIfDirty = ($gitPullStrategy -eq 'SkipIfDirty')
            Force = [bool]$ForceGitPull
            TimeoutSeconds = [int]$constants.Git.FetchTimeoutSeconds
            WhatIf = ([bool]$DryRun -or [bool]$WhatIfPreference)
        }
        if ($PSBoundParameters.ContainsKey('Confirm')) { $gitParams.Confirm = [bool]$PSBoundParameters['Confirm'] }
        Invoke-SafeGitPull @gitParams | Out-Null
    }

    $setupParams = @{
        ProjectRoot = $ProjectRoot
        ForceRecreateVenv = [bool]$ForceRecreateVenv
        SkipPoetryInstall = $false
        NonInteractive = $resolvedNonInteractive
        EnableCodeSigning = $resolvedEnableCodeSigning
        DigiCertUtilityExe = $DigiCertUtilityExe
        KernelDriverSigning = [bool]$KernelDriverSigning
        SignPoetryOnly = [bool]$SignPoetryOnly
        RequirePmShimSigning = $resolvedRequirePmShimSigning
        UpdateDependencies = [bool]$UpdateDependencies
        PinExact = [bool]$PinExact
        IncludeDev = (-not [bool]$ExcludeDev)
        ListMode = [bool]$ListMode
        PackageManager = $PackageManager
        Mode = $Mode
        PinnedPoetryVersion = $PinnedPoetryVersion
        PinnedUvVersion = $PinnedUvVersion
        AllowPythonInstall = $resolvedAllowPythonInstall
        UpgradePackages = $resolvedUpgradePackages
        LogLevel = $effectiveLogLevel
    }
    if ($DryRun) { $setupParams.DryRun = $true }
    if ($WhatIfPreference) { $setupParams.WhatIf = $true }
    if ($resolvedPythonExePath) { $setupParams.PythonExePath = $resolvedPythonExePath }
    if ($ContinueOnPrecheckFailure) { $setupParams.StopOnPrecheckFailure = $false }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $setupParams.Confirm = [bool]$PSBoundParameters['Confirm'] }

    Start-Setup @setupParams
}

function Convert-DevSetupBool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Value,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Name
    )

    if ($Value -is [bool]) { return $Value }
    if ($Value -is [int]) {
        if ($Value -eq 0) { return $false }
        if ($Value -eq 1) { return $true }
    }

    $constants = Get-SetupConstants
    $text = ([string]$Value).Trim()
    if ($text.Length -gt [int]$constants.Input.MaxBooleanTextLength) {
        throw ("Invalid boolean value for -{0}: input is too long." -f $Name)
    }
    switch ($text.ToLowerInvariant()) {
        'true' { return $true }; '1' { return $true }; 'yes' { return $true }; 'on' { return $true }
        'false' { return $false }; '0' { return $false }; 'no' { return $false }; 'off' { return $false }
        default { throw ("Invalid boolean value for -{0}: '{1}'." -f $Name, $Value) }
    }
}
