#Requires -Version 5.1
<#
.SYNOPSIS
    Root orchestration module for PythonVenvAutomation.

.DESCRIPTION
    Loads SetupCore modules and exposes Start-Setup. The former monolithic
    orchestration body is decomposed into named functions in SetupSteps.psm1 and
    executed through SetupPipeline.psm1. Timing, dry-run handling, structured
    errors and structured logging are centralized.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulesDir = Join-Path (Join-Path $PSScriptRoot 'SetupCore') 'modules'
if (-not (Test-Path -LiteralPath (Join-Path $modulesDir 'Compat.psm1') -PathType Leaf)) {
    throw "Cannot continue without SetupCore modules directory: $modulesDir"
}

$import = 'Microsoft.PowerShell.Core\Import-Module'
$moduleLoadOrder = @(
    'Compat',
    'Constants',
    'Errors',
    'Logging',
    'UI',
    'Path',
    'Versioning',
    'Toml',
    'TomlParser',
    'NativeCommand',
    'Config',
    'Detection',
    'Filesystem',
    'PythonDiscovery',
    'Venv',
    'VSCode',
    'Tcl',
    'Poetry',
    'UV',
    'PackageManager',
    'Redaction',
    'SupportCodes',
    'PyProjectHealth',
    'Diagnostics',
    'Prechecks',
    'CodeSigning',
    'GitSync',
    'SetupPipeline',
    'SetupSteps'
)
foreach ($moduleName in $moduleLoadOrder) {
    & $import -FullyQualifiedName (Join-Path $modulesDir "$moduleName.psm1") -Force -DisableNameChecking -Global -ErrorAction Stop
}

function Invoke-SetupModeSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][hashtable] $Ctx)

    if ($Ctx.NonInteractive -or $Ctx.Mode -ne 'setup' -or $Ctx.PythonExePath -or $Ctx.ListMode) { return }

    Write-Host ''
    Write-Host '+------------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '|  What should Setup do?                                    |' -ForegroundColor Cyan
    Write-Host '+------------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '|  [Enter]   Full setup, semi-auto Python selection          |' -ForegroundColor DarkGray
    Write-Host '|  [u]       Update existing .venv only                      |' -ForegroundColor DarkGray
    Write-Host '|  [l]       Full setup, list all Pythons and choose one     |' -ForegroundColor DarkGray
    Write-Host '|  <path>    Full setup, explicit path to python.exe         |' -ForegroundColor DarkGray
    Write-Host '+------------------------------------------------------------+' -ForegroundColor Cyan

    $inputText = Read-Host 'Choice (Enter = full setup)'
    $inputText = if ($inputText) { $inputText.Trim() } else { '' }
    if ($inputText.Length -gt 1024) {
        throw (New-SetupException -Message 'Interactive setup input is unexpectedly long.' -ErrorCode 'INPUT_TOO_LONG' -Step 'MODE' -Context @{})
    }

    $normalized = $inputText.ToLowerInvariant()
    if ($normalized -in @('u','update','update-venv','venv-update','refresh-venv')) {
        $Ctx.Mode = 'update-venv'
    } elseif ($normalized -in @('l','list')) {
        $Ctx.ListMode = $true
    } elseif (-not [string]::IsNullOrWhiteSpace($inputText)) {
        $candidate = $inputText.Trim('"').Trim("'")
        try { $candidate = [System.IO.Path]::GetFullPath($candidate) } catch { }
        $Ctx.PythonExePath = $candidate
    }
}

function New-SetupLoggingCallbacks {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        OnStart = {
            param($step)
            $script:setupCurrentStep = $step.Name
            $script:setupCurrentModule = $step.Module
            Write-LogStepStart -Step $step.Name -Module $step.Module -Message $step.Message
            Write-StructuredLog -Level INFO -Step $step.Name -Module $step.Module -Message $step.Message -NoConsole
        }
        OnResult = {
            param($step, $status, $message, $duration)
            $uiStatus = switch ($status) { 'SKIPPED' { 'WARN' } default { $status } }
            Write-LogStepResult -Step $step.Name -Module $step.Module -Status $uiStatus -Message $message -DurationSec $duration
            $level = switch ($status) { 'ERROR' { 'ERROR' }; 'WARN' { 'WARN' }; default { 'INFO' } }
            Write-StructuredLog -Level $level -Step $step.Name -Module $step.Module -Message $message -Context @{ DurationSec = $duration; Status = $status } -NoConsole
        }
        OnDetail = {
            param($key, $value)
            Write-LogDetail -Key $key -Value $value
        }
    }
}

function New-FullSetupPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable] $Ctx,
        [Parameter(Mandatory=$true)][string] $DigiCertUtilityExe,
        [bool] $KernelDriverSigning = $false,
        [bool] $RequirePmShimSigning = $true,
        [bool] $StopOnPrecheckFailure = $false,
        [bool] $SignPoetryOnly = $false,
        [bool] $DryRun = $false
    )

    $steps = [System.Collections.Generic.List[object]]::new()
    $steps.Add((New-SetupPipelineStep -Name 'PRECHECK' -Module 'Prechecks' -Message 'Run pre-setup checks' -ReadOnly -ErrorCode 'PRECHECK_FAILED' -Action {
        Invoke-PrecheckStep -Ctx $Ctx -DigiCertUtilityExe $DigiCertUtilityExe -StopOnPrecheckFailure:$StopOnPrecheckFailure -DryRun:$DryRun | Out-Null
    }))
    $steps.Add((New-SetupPipelineStep -Name 'METADATA' -Module 'Toml' -Message 'Parse project metadata' -ReadOnly -ErrorCode 'PROJECT_METADATA_FAILED' -Action {
        Invoke-ProjectMetadataStep -Ctx $Ctx | Out-Null
    }))
    # Python resolution is intentionally mutating-capable because it may install
    # Python when AllowPythonInstall is true. Therefore it is NOT ReadOnly and
    # is skipped by DryRun/WhatIf.
    $steps.Add((New-SetupPipelineStep -Name 'PYTHON' -Module 'PythonDiscovery' -Message 'Resolve compatible Python interpreter' -ErrorCode 'PYTHON_RESOLUTION_FAILED' -Action {
        Invoke-PythonDetectionStep -Ctx $Ctx -Confirm:$false | Out-Null
        if ($Ctx.EnableCodeSigning -and -not $DryRun) {
            Set-CodeSignerDefaults -DigiCertUtilityExe $DigiCertUtilityExe -KernelDriverSigning $KernelDriverSigning
        }
    }))
    $steps.Add((New-SetupPipelineStep -Name 'PM-RUNTIME' -Module 'PackageManager' -Message 'Ensure package-manager runtime' -ErrorCode 'PM_RUNTIME_FAILED' -Action {
        Invoke-PackageManagerRuntimeStep -Ctx $Ctx -Confirm:$false | Out-Null
    }))
    $steps.Add((New-SetupPipelineStep -Name 'PM-SIGN' -Module 'CodeSigning' -Message 'Validate/sign package-manager executable' -Mandatory:$RequirePmShimSigning -ErrorCode 'PM_SIGNING_FAILED' -Action {
        Invoke-PackageManagerSigningStep -Ctx $Ctx -RequirePmShimSigning:$RequirePmShimSigning -Confirm:$false | Out-Null
    }))
    $steps.Add((New-SetupPipelineStep -Name 'PM-CONFIG' -Module 'PackageManager' -Message 'Configure package-manager defaults' -ErrorCode 'PM_CONFIG_FAILED' -Action {
        Invoke-PackageManagerConfigureStep -Ctx $Ctx -Confirm:$false | Out-Null
    }))
    $steps.Add((New-SetupPipelineStep -Name 'PM-CLEAN' -Module 'PackageManager' -Message 'Clean stale environment associations' -Mandatory:$false -ErrorCode 'PM_CLEANUP_FAILED' -Action {
        Invoke-PackageManagerCleanupStep -Ctx $Ctx -Confirm:$false | Out-Null
    }))
    if ($Ctx.ForceRecreateVenv) {
        $steps.Add((New-SetupPipelineStep -Name 'VENV-BACKUP' -Module 'Venv' -Message 'Backup and remove existing .venv' -ErrorCode 'VENV_BACKUP_FAILED' -Action {
            Invoke-VenvBackupStep -Ctx $Ctx -Confirm:$false | Out-Null
        }))
    }
    $steps.Add((New-SetupPipelineStep -Name 'VENV-PREPARE' -Module 'Venv' -Message 'Prepare project virtual environment' -ErrorCode 'VENV_PREPARE_FAILED' -Action {
        Invoke-VenvPrepareStep -Ctx $Ctx -Confirm:$false | Out-Null
    }))
    $steps.Add((New-SetupPipelineStep -Name 'VENV-VALIDATE' -Module 'Venv' -Message 'Validate virtual environment' -ReadOnly -ErrorCode 'VENV_INVALID' -Action {
        Invoke-VenvValidationStep -Ctx $Ctx
    }))
    $steps.Add((New-SetupPipelineStep -Name 'VENV-RUNTIME' -Module 'Venv' -Message 'Copy Python runtime DLL' -ErrorCode 'VENV_RUNTIME_COPY_FAILED' -Action {
        Invoke-VenvRuntimeCopyStep -Ctx $Ctx -Confirm:$false
    }))
    $steps.Add((New-SetupPipelineStep -Name 'LOCK' -Module 'PackageManager' -Message 'Synchronize dependency lock state' -ErrorCode 'LOCK_SYNC_FAILED' -Action {
        Invoke-LockSyncStep -Ctx $Ctx -Confirm:$false | Out-Null
    }))
    $steps.Add((New-SetupPipelineStep -Name 'DEPENDENCIES' -Module 'PackageManager' -Message 'Install/update project dependencies' -ErrorCode 'DEPENDENCY_INSTALL_FAILED' -Action {
        Invoke-DependencyInstallStep -Ctx $Ctx -Confirm:$false | Out-Null
    }))
    $steps.Add((New-SetupPipelineStep -Name 'VENV-PATH' -Module 'Path' -Message 'Persist project .venv CLI tools on PATH' -Mandatory:$false -ErrorCode 'PATH_UPDATE_FAILED' -Action {
        Invoke-VenvPathStep -Ctx $Ctx -Confirm:$false
    }))
    $steps.Add((New-SetupPipelineStep -Name 'PROJECT-PTH' -Module 'Venv' -Message 'Write project .pth into site-packages' -ErrorCode 'PTH_WRITE_FAILED' -Action {
        Invoke-ProjectPthStep -Ctx $Ctx -Confirm:$false | Out-Null
    }))
    $steps.Add((New-SetupPipelineStep -Name 'VSCODE' -Module 'VSCode' -Message 'Pin venv interpreter in VS Code settings' -ErrorCode 'VSCODE_WRITE_FAILED' -Action {
        Invoke-VSCodeStep -Ctx $Ctx -Confirm:$false
    }))
    $steps.Add((New-SetupPipelineStep -Name 'TCL' -Module 'Tcl' -Message 'Copy Tcl runtime into .venv' -Mandatory:$false -ErrorCode 'TCL_COPY_FAILED' -Action {
        Invoke-TclStep -Ctx $Ctx -Confirm:$false
    }))
    $steps.Add((New-SetupPipelineStep -Name 'SMART-SIGNING' -Module 'CodeSigning' -Message 'Validate signatures and sign only new/changed binaries' -Mandatory:$false -ErrorCode 'VENV_SIGNING_FAILED' -Action {
        Invoke-SmartSigningStep -Ctx $Ctx -SignPoetryOnly:$SignPoetryOnly -Confirm:$false | Out-Null
    }))
    $steps.Add((New-SetupPipelineStep -Name 'CLEANUP' -Module 'Filesystem' -Message 'Clean stale quarantine and backup directories' -Mandatory:$false -ErrorCode 'CLEANUP_FAILED' -Action {
        Invoke-StaleCleanupStep -Ctx $Ctx -Confirm:$false | Out-Null
        Invoke-VenvBackupCleanupStep -Ctx $Ctx -Confirm:$false
    }))
    @($steps)
}

function Start-Setup {
<#
.SYNOPSIS
    Executes the Python environment setup pipeline.

.DESCRIPTION
    The setup process is an ordered pipeline of named, independently testable
    steps. `-WhatIf` is treated like `-DryRun` for mutating pipeline steps,
    while read-only discovery/precheck steps continue to run.

.EXAMPLE
    Start-Setup -ProjectRoot C:\src\project

.EXAMPLE
    Start-Setup -ProjectRoot C:\src\project -Mode update-venv

.EXAMPLE
    Start-Setup -ProjectRoot C:\src\project -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        [Parameter()][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string] $ProjectRoot = (Get-Location).Path,
        [Parameter()][bool] $ForceRecreateVenv = $false,
        [Parameter()][bool] $SkipPoetryInstall = $false,
        [Parameter()][string] $PythonExePath,
        [Parameter()][bool] $NonInteractive = $false,
        [Parameter()][bool] $EnableCodeSigning = $true,
        [Parameter()][string] $DigiCertUtilityExe = '',
        [Parameter()][bool] $KernelDriverSigning = $false,
        [Parameter()][bool] $SignPoetryOnly = $false,
        [Parameter()][bool] $RequirePmShimSigning = $true,
        [Parameter()][bool] $UpdateDependencies = $false,
        [Parameter()][bool] $PinExact = $false,
        [Parameter()][bool] $ListMode = $false,
        [Parameter()][ValidateSet('uv','poetry','auto')][string] $PackageManager = 'auto',
        [Parameter()][bool] $IncludeDev = $true,
        [Parameter()][switch] $DryRun,
        [Parameter()][string] $PinnedPoetryVersion = '',
        [Parameter()][string] $PinnedUvVersion = '',
        [Parameter()][bool] $AllowPythonInstall = $true,
        [Parameter()][ValidateSet('setup','update-venv','venv-update','refresh-venv')][string] $Mode = 'setup',
        [Parameter()][string[]] $UpgradePackages = @(),
        [Parameter()][bool] $StopOnPrecheckFailure = $false,
        [Parameter()][ValidateSet('DEBUG','INFO','WARN','ERROR')][string] $LogLevel = 'INFO'
    )

    $ctx = $null
    $script:setupCurrentStep = 'INIT'
    $script:setupCurrentModule = 'Core'
    $effectiveDryRun = [bool]$DryRun -or [bool]$WhatIfPreference

    try {
        if (-not (Get-IsWindows)) {
            throw (New-SetupException -Message 'This setup automation is Windows-only.' -ErrorCode 'PLATFORM_UNSUPPORTED' -Step 'INIT' -Context @{})
        }

        $constants = Get-SetupConstants
        if (-not $DigiCertUtilityExe) {
            $DigiCertUtilityExe = if ($env:DIGICERT_UTILITY_EXE) { $env:DIGICERT_UTILITY_EXE } else { [string]$constants.CodeSigning.DefaultDigiCertUtilityExe }
        }
        if (-not (Test-Path -LiteralPath $DigiCertUtilityExe -PathType Leaf)) {
            throw (New-SetupException -Message 'DigiCert Utility not found. Please install or set environment variable.' -ErrorCode 'DIGICERT_NOT_FOUND' -Step 'INIT' -Context @{ DigiCertUtilityExe = $DigiCertUtilityExe })
        }

        $correlationId = Start-StructuredLogSession -LogLevel $LogLevel
        Write-StructuredLog -Level INFO -Step 'INIT' -Module 'Core' -Message 'Python environment setup started.' -Context @{ ProjectRoot = $ProjectRoot; Mode = $Mode; DryRun = $effectiveDryRun } -NoConsole

        $env:VIRTUAL_ENV = $null
        $env:POETRY_ACTIVE = $null
        $env:CONDA_PREFIX = $null

        $ctx = New-SetupContext `
            -ProjectRoot $ProjectRoot `
            -ForceRecreateVenv:$ForceRecreateVenv `
            -SkipPoetryInstall:$SkipPoetryInstall `
            -PythonExePath $PythonExePath `
            -NonInteractive:$NonInteractive `
            -EnableCodeSigning:$EnableCodeSigning `
            -UpdateDependencies:$UpdateDependencies `
            -PinExact:$PinExact `
            -ListMode:$ListMode `
            -PackageManager $PackageManager `
            -IncludeDev:$IncludeDev `
            -PinnedPoetryVersion $PinnedPoetryVersion `
            -PinnedUvVersion $PinnedUvVersion `
            -AllowPythonInstall:$AllowPythonInstall `
            -Mode $Mode `
            -UpgradePackages $UpgradePackages

        $callbacks = New-SetupLoggingCallbacks
        $detectStep = New-SetupPipelineStep -Name 'DETECT' -Module 'Detection' -Message 'Detect package manager from project files' -ReadOnly -ErrorCode 'PM_DETECTION_FAILED' -Action {
            Invoke-PackageManagerDetectionStep -Ctx $ctx
        }
        Invoke-SetupPipelineStep -Step $detectStep -DryRun:$effectiveDryRun -OnStart $callbacks.OnStart -OnResult $callbacks.OnResult -OnDetail $callbacks.OnDetail | Out-Null

        Invoke-SetupModeSelection -Ctx $ctx

        if ($ctx.Mode -in @('update-venv','venv-update','refresh-venv')) {
            if ($ctx.EnableCodeSigning -and -not $effectiveDryRun) {
                Set-CodeSignerDefaults -DigiCertUtilityExe $DigiCertUtilityExe -KernelDriverSigning $KernelDriverSigning
            }
            $updateStep = New-SetupPipelineStep -Name 'UPDATE-VENV' -Module 'Venv' -Message 'Refresh existing .venv and validate signing state' -ErrorCode 'VENV_UPDATE_FAILED' -Action {
                Invoke-ExistingVenvUpdateStep -Ctx $ctx -SignPoetryOnly:$SignPoetryOnly -Confirm:$false
            }
            Invoke-SetupPipelineStep -Step $updateStep -DryRun:$effectiveDryRun -OnStart $callbacks.OnStart -OnResult $callbacks.OnResult -OnDetail $callbacks.OnDetail | Out-Null
        } else {
            $steps = New-FullSetupPipeline -Ctx $ctx -DigiCertUtilityExe $DigiCertUtilityExe -KernelDriverSigning:$KernelDriverSigning -RequirePmShimSigning:$RequirePmShimSigning -StopOnPrecheckFailure:$StopOnPrecheckFailure -SignPoetryOnly:$SignPoetryOnly -DryRun:$effectiveDryRun
            Invoke-SetupPipeline -Steps $steps -DryRun:$effectiveDryRun -OnStart $callbacks.OnStart -OnResult $callbacks.OnResult -OnDetail $callbacks.OnDetail | Out-Null
        }

        if (-not $effectiveDryRun) {
            $configValues = @{ PinnedPoetryVersion = $ctx.PinnedPoetryVersion; PinnedUvVersion = $ctx.PinnedUvVersion }
            if ($ctx.PmSource -eq 'cli') { $configValues.PackageManager = $ctx.PackageManager }
            Write-SetupConfig -ProjectRoot $ctx.ProjectRoot -Values $configValues -NonInteractive:$ctx.NonInteractive -Confirm:$false | Out-Null
        }

        Write-StructuredLog -Level INFO -Step 'DONE' -Module 'Core' -Message 'Setup completed.' -Context @{ Mode = $ctx.Mode } -NoConsole
        $doneMessage = if ($effectiveDryRun) { 'Dry run completed' } else { 'Setup completed successfully' }
        Write-LogStepResult -Step 'DONE' -Module 'Core' -Status 'OK' -Message $doneMessage

        if (-not $effectiveDryRun) {
            try { Invoke-VenvActivation -ProjectRoot $ctx.ProjectRoot } catch { Write-Warning $_.Exception.Message }
        }

        $logContext = Get-StructuredLogContext
        [pscustomobject]@{
            ProjectRoot = $ctx.ProjectRoot
            ProjectName = $ctx.ProjectName
            RequiresPython = $ctx.RequiresPython
            PythonVersion = if ($ctx.SelectedPython) { $ctx.SelectedPython.Version } else { $null }
            PythonExe = if ($ctx.SelectedPython) { $ctx.SelectedPython.Exe } else { $null }
            PackageManager = $ctx.PackageManager
            PmSource = $ctx.PmSource
            VenvDir = $ctx.VenvDir
            SitePackages = $ctx.SitePackagesDir
            Mode = $ctx.Mode
            CorrelationId = $correlationId
            LogFile = $logContext.LogFilePath
            Signing = if ($ctx.SignResult) {
                [pscustomobject]@{
                    Total = $ctx.SignResult.Total
                    Signed = $ctx.SignResult.Signed
                    NewlySigned = $ctx.SignResult.NewlySigned
                    Skipped = $ctx.SignResult.Skipped
                    Failed = @($ctx.SignResult.Failed).Count
                }
            } else { $null }
        }
    }
    catch {
        $setupError = ConvertTo-SetupException -ErrorRecord $_ -ErrorCode 'SETUP_FAILED' -Step $script:setupCurrentStep -Context @{ Module = $script:setupCurrentModule }
        try { Write-StructuredLog -Level ERROR -Step $setupError.Step -Module $script:setupCurrentModule -Message $setupError.Message -Context @{ ErrorCode = $setupError.ErrorCode } -NoConsole } catch { }

        Write-Host ''
        Write-Host ('+' + ('-' * 94) + '+') -ForegroundColor Red
        Write-Host ("| [FATAL] Pipeline stopped at step {0} (module: {1})" -f $setupError.Step, $script:setupCurrentModule) -ForegroundColor Red
        Write-Host ("|   - error_code : {0}" -f $setupError.ErrorCode) -ForegroundColor Red
        Write-Host ("|   - message    : {0}" -f $setupError.Message) -ForegroundColor Red
        Write-Host ('+' + ('-' * 94) + '+') -ForegroundColor Red

        if ($ctx -and $ctx.VenvBackupPath) {
            try { Restore-VenvBackup -BackupPath $ctx.VenvBackupPath -VenvDir $ctx.VenvDir } catch { Write-Warning ("Rollback failed: {0}" -f $_.Exception.Message) }
        }
        throw $setupError
    }
}

Export-ModuleMember -Function Start-Setup
