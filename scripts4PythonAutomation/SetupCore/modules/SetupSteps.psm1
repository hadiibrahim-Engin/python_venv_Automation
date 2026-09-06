#Requires -Version 5.1
# =============================================================================
# Module  : SetupSteps.psm1
# Purpose : Named, testable actions used by the Start-Setup pipeline.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-SetupContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string] $ProjectRoot,
        [bool] $ForceRecreateVenv = $false,
        [bool] $SkipPoetryInstall = $false,
        [string] $PythonExePath,
        [bool] $NonInteractive = $false,
        [bool] $EnableCodeSigning = $true,
        [bool] $UpdateDependencies = $false,
        [bool] $PinExact = $false,
        [bool] $ListMode = $false,
        [ValidateSet('uv','poetry','auto')][string] $PackageManager = 'auto',
        [bool] $IncludeDev = $true,
        [string] $PinnedPoetryVersion = '',
        [string] $PinnedUvVersion = '',
        [bool] $AllowPythonInstall = $true,
        [ValidateSet('setup','update-venv','venv-update','refresh-venv')][string] $Mode = 'setup',
        [string[]] $UpgradePackages = @()
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
    @{
        ProjectRoot = $resolvedRoot; ProjectName = $null; RequiresPython = $null; ParsedConstraints = $null; SelectedPython = $null
        UvInfo = $null; PoetryInfo = $null; PoetryPythonPath = $null; PmPythonPath = $null
        VenvDir = Join-Path $resolvedRoot '.venv'; SitePackagesDir = $null; SignResult = $null
        VscodeSettingsFile = Join-Path (Join-Path $resolvedRoot '.vscode') 'settings.json'
        NonInteractive = $NonInteractive; ForceRecreateVenv = $ForceRecreateVenv; SkipPoetryInstall = $SkipPoetryInstall
        PythonExePath = $PythonExePath; UpdateDependencies = $UpdateDependencies; ListMode = $ListMode
        PackageManager = $PackageManager; PmSource = $null; PmDetectionReport = $null
        EnableCodeSigning = $EnableCodeSigning; NetworkAvailable = $true; IncludeDev = $IncludeDev
        PinnedPoetryVersion = $PinnedPoetryVersion; PinnedUvVersion = $PinnedUvVersion; AllowPythonInstall = $AllowPythonInstall
        UpgradePackages = @($UpgradePackages); PinExact = $PinExact; VenvBackupPath = $null; PrechecksWouldAbort = $false; Mode = $Mode
    }
}

function Invoke-PackageManagerDetectionStep {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    Invoke-PmDetection -Ctx $Ctx
}

function Invoke-PrecheckStep {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][hashtable] $Ctx, [Parameter(Mandatory=$true)][string] $DigiCertUtilityExe, [bool] $StopOnPrecheckFailure = $false, [bool] $DryRun = $false)
    $prechecks = Invoke-Prechecks -EnableCodeSigning $Ctx.EnableCodeSigning -DigiCertExe $DigiCertUtilityExe -NonInteractive ([bool]$Ctx.NonInteractive) -Ctx $Ctx -StopOnNonCritical $StopOnPrecheckFailure -ReportOnly $DryRun
    if (-not $prechecks.ContinueSetup) {
        if ($DryRun) { $Ctx.PrechecksWouldAbort = $true }
        else { throw (New-SetupException -Message 'Setup aborted: critical prechecks failed.' -ErrorCode 'PRECHECK_FAILED' -Step 'PRECHECK' -Context @{ ProjectRoot = $Ctx.ProjectRoot }) }
    }
    $prechecks
}

function Invoke-ProjectMetadataStep {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    $meta = Get-ProjectMetadata -ProjectRoot $Ctx.ProjectRoot
    $Ctx.ProjectName = $meta.ProjectName; $Ctx.RequiresPython = $meta.RequiresPython
    $Ctx.ParsedConstraints = ConvertTo-VersionConstraints -ConstraintStr $Ctx.RequiresPython
    $meta
}

function Invoke-PythonDetectionStep {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    if (-not $PSCmdlet.ShouldProcess($Ctx.ProjectRoot, 'Resolve/select Python interpreter; installation may occur if required')) { return $null }
    $Ctx.SelectedPython = Resolve-SelectedPython -Constraints $Ctx.ParsedConstraints -RequiresPythonRaw $Ctx.RequiresPython -VenvDir $Ctx.VenvDir -ExplicitPythonExePath $Ctx.PythonExePath -AllowInstall:([bool]$Ctx.AllowPythonInstall) -NonInteractive:([bool]$Ctx.NonInteractive) -ListMode:([bool]$Ctx.ListMode)
    $Ctx.SelectedPython
}

function Invoke-PackageManagerRuntimeStep {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    if ($PSCmdlet.ShouldProcess($Ctx.ProjectRoot, "Ensure $($Ctx.PackageManager) runtime")) { Invoke-PmEnsureRuntime -Ctx $Ctx }
}

function Invoke-PackageManagerSigningStep {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param([Parameter(Mandatory=$true)][hashtable] $Ctx, [bool] $RequirePmShimSigning = $true)
    $pmShimPath = Get-PmShimPath -Ctx $Ctx
    if (-not $Ctx.EnableCodeSigning -or -not $pmShimPath) { return $null }
    if (-not $PSCmdlet.ShouldProcess($pmShimPath, 'Validate/sign package-manager executable')) { return $null }
    $result = Set-PoetryShimSignature -ShimPath $pmShimPath -Confirm:$false
    if ($RequirePmShimSigning -and ((@($result.Failed).Count -gt 0) -or ($result.Signed -lt 1))) {
        throw (New-SetupException -Message ("{0} executable signing failed." -f $Ctx.PackageManager) -ErrorCode 'PM_SIGNING_FAILED' -Step 'PM-SIGN' -Context @{ Path = $pmShimPath })
    }
    $result
}

function Invoke-PackageManagerConfigureStep {
    [CmdletBinding(SupportsShouldProcess=$true)] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    if ($PSCmdlet.ShouldProcess($Ctx.ProjectRoot, "Configure $($Ctx.PackageManager) defaults")) { Invoke-PmConfigure -Ctx $Ctx }
}

function Invoke-PackageManagerCleanupStep {
    [CmdletBinding(SupportsShouldProcess=$true)] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    if ($PSCmdlet.ShouldProcess($Ctx.ProjectRoot, 'Clean stale environment associations')) { Invoke-PmCleanEnvs -Ctx $Ctx }
}

function Invoke-VenvBackupStep {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    if (-not $Ctx.ForceRecreateVenv) { return $null }
    if (-not $PSCmdlet.ShouldProcess($Ctx.VenvDir, 'Backup and remove existing virtual environment')) { return $null }
    $Ctx.VenvBackupPath = New-VenvBackup -VenvDir $Ctx.VenvDir
    Remove-VenvIfExists -VenvDir $Ctx.VenvDir -NonInteractive ([bool]$Ctx.NonInteractive)
    $Ctx.VenvBackupPath
}

function Invoke-VenvPrepareStep {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    if ($PSCmdlet.ShouldProcess($Ctx.VenvDir, 'Create or update virtual environment')) { Invoke-PmPrepareVenv -Ctx $Ctx }
}

function Invoke-VenvValidationStep {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    Confirm-VenvExists -VenvDir $Ctx.VenvDir
}

function Invoke-VenvRuntimeCopyStep {
    [CmdletBinding(SupportsShouldProcess=$true)] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    if ($PSCmdlet.ShouldProcess($Ctx.VenvDir, "Copy $($Ctx.SelectedPython.DllName) into virtual environment")) {
        Copy-PythonDllToVenv -DllSourceDir $Ctx.SelectedPython.Directory -VenvDir $Ctx.VenvDir -DllName $Ctx.SelectedPython.DllName
    }
}

function Invoke-LockSyncStep {
    [CmdletBinding(SupportsShouldProcess=$true)] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    if ($Ctx.PinExact) {
        if ($PSCmdlet.ShouldProcess($Ctx.ProjectRoot, 'Synchronize dependency lock file')) { Invoke-PmLockDeps -Ctx $Ctx }
        return 'pin-exact'
    }
    if ($Ctx.UpgradePackages -and $Ctx.UpgradePackages.Count -gt 0) { return 'selective-upgrade-deferred' }
    'upgrade-deferred'
}

function Invoke-DependencyInstallStep {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    if ($Ctx.SkipPoetryInstall) { return 'skipped' }
    if (-not $PSCmdlet.ShouldProcess($Ctx.VenvDir, 'Install/update project dependencies')) { return 'whatif' }
    if ($Ctx.PinExact) { Invoke-PmInstallDeps -Ctx $Ctx -IncludeDev $Ctx.IncludeDev; return 'pin-exact' }
    if ($Ctx.UpgradePackages -and $Ctx.UpgradePackages.Count -gt 0) { Invoke-PmUpdateSelectedDeps -Ctx $Ctx -Packages $Ctx.UpgradePackages -IncludeDev $Ctx.IncludeDev; return 'selective-upgrade' }
    Invoke-PmUpdateDeps -Ctx $Ctx -IncludeDev $Ctx.IncludeDev; 'upgrade-all'
}

function Invoke-VenvPathStep {
    [CmdletBinding(SupportsShouldProcess=$true)] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    $scripts = Join-Path $Ctx.VenvDir 'Scripts'
    if ($PSCmdlet.ShouldProcess($scripts, 'Persist project virtual-environment CLI directory on PATH')) { Add-ToolDirsToPath -Directories @($scripts) -Reason 'project .venv CLI' | Out-Null }
}

function Invoke-ProjectPthStep {
    [CmdletBinding(SupportsShouldProcess=$true)] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    $venvPythonExe = Get-VenvPythonExe -VenvDir $Ctx.VenvDir
    try { $spResult = & $venvPythonExe -c "import site; print(site.getsitepackages()[0])" 2>$null; $Ctx.SitePackagesDir = $spResult.Trim() }
    catch { $Ctx.SitePackagesDir = Join-Path $Ctx.VenvDir 'Lib\site-packages' }
    if ($PSCmdlet.ShouldProcess($Ctx.SitePackagesDir, 'Write project .pth file')) { Write-ProjectPth -ProjectRoot $Ctx.ProjectRoot -SitePackagesDir $Ctx.SitePackagesDir }
    $Ctx.SitePackagesDir
}

function Invoke-VSCodeStep {
    [CmdletBinding(SupportsShouldProcess=$true)] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    if ($PSCmdlet.ShouldProcess($Ctx.VscodeSettingsFile, 'Write VS Code interpreter setting')) { Write-VSCodeInterpreterSetting -VenvDir $Ctx.VenvDir -SettingsFile $Ctx.VscodeSettingsFile }
}

function Invoke-TclStep {
    [CmdletBinding(SupportsShouldProcess=$true)] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    if ($PSCmdlet.ShouldProcess($Ctx.VenvDir, 'Copy Tcl runtime')) { Copy-TclToVenv -PythonDir $Ctx.SelectedPython.Directory -VenvDir $Ctx.VenvDir }
}

function Invoke-SmartSigningStep {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param([Parameter(Mandatory=$true)][hashtable] $Ctx, [bool] $SignPoetryOnly = $false)
    if (-not $Ctx.EnableCodeSigning) { return $null }
    if (-not $PSCmdlet.ShouldProcess($Ctx.VenvDir, 'Validate Authenticode and sign only new/changed/invalid binaries')) { return $null }
    $Ctx.SignResult = Set-VenvScriptSignature -VenvDir $Ctx.VenvDir -PoetryOnly:$SignPoetryOnly -Confirm:$false
    $Ctx.SignResult
}

function Invoke-StaleCleanupStep {
    [CmdletBinding(SupportsShouldProcess=$true)] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    if ($PSCmdlet.ShouldProcess($Ctx.ProjectRoot, 'Remove stale venv quarantine/backup directories')) { Remove-StaleQuarantines -ProjectRoot $Ctx.ProjectRoot }
}

function Invoke-VenvBackupCleanupStep {
    [CmdletBinding(SupportsShouldProcess=$true)] param([Parameter(Mandatory=$true)][hashtable] $Ctx)
    if (-not $Ctx.VenvBackupPath) { return }
    if ($PSCmdlet.ShouldProcess($Ctx.VenvBackupPath, 'Remove successful virtual-environment backup')) { Remove-VenvBackup -BackupPath $Ctx.VenvBackupPath; $Ctx.VenvBackupPath = $null }
}

function Invoke-ExistingVenvUpdateStep {
<#
.SYNOPSIS
    Refreshes an existing .venv and performs an idempotent signing scan.
#>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param([Parameter(Mandatory=$true)][hashtable] $Ctx, [bool] $SignPoetryOnly = $false)

    Confirm-VenvExists -VenvDir $Ctx.VenvDir
    $venvPython = Get-VenvPythonExe -VenvDir $Ctx.VenvDir
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        throw (New-SetupException -Message ("Existing .venv Python was not found: {0}" -f $venvPython) -ErrorCode 'VENV_PYTHON_MISSING' -Step 'UPDATE-VENV' -Context @{ VenvDir = $Ctx.VenvDir })
    }
    if (-not $PSCmdlet.ShouldProcess($Ctx.VenvDir, 'Refresh existing virtual environment and signing state')) { return $null }

    $requirementsFile = Join-Path $Ctx.ProjectRoot 'requirements.txt'; $pyprojectFile = Join-Path $Ctx.ProjectRoot 'pyproject.toml'
    if ($Ctx.PmSource -eq 'default' -and (Test-Path -LiteralPath $requirementsFile -PathType Leaf)) { $Ctx.PackageManager = 'pip-requirements' }

    switch ($Ctx.PackageManager) {
        'uv' {
            $uvExe = Get-UvExe; if (-not $uvExe) { throw 'update-venv requires uv, but uv is not installed or discoverable.' }
            Add-ToolDirsToPath -Directories @((Split-Path $uvExe -Parent)) -Reason 'uv CLI' | Out-Null
            $Ctx.UvInfo = [pscustomobject]@{ Source='existing'; Version=Get-UvVersion; Exe=$uvExe }
            if ($Ctx.UpgradePackages -and $Ctx.UpgradePackages.Count -gt 0) { Invoke-PmUpdateSelectedDeps -Ctx $Ctx -Packages $Ctx.UpgradePackages -IncludeDev $Ctx.IncludeDev }
            elseif ($Ctx.UpdateDependencies -and -not $Ctx.PinExact) { Invoke-PmUpdateDeps -Ctx $Ctx -IncludeDev $Ctx.IncludeDev }
            else { Invoke-PmInstallDeps -Ctx $Ctx -IncludeDev $Ctx.IncludeDev }
        }
        'poetry' {
            $poetryRunner = Get-PoetryShimPath
            if ($poetryRunner) { Add-ToolDirsToPath -Directories @((Split-Path $poetryRunner -Parent)) -Reason 'Poetry CLI' | Out-Null }
            elseif (Test-PoetryAvailable -PythonExe $venvPython) { $poetryRunner = $venvPython }
            else { throw 'update-venv requires Poetry, but Poetry is not installed or discoverable.' }
            $Ctx.PoetryPythonPath = $poetryRunner; $Ctx.PmPythonPath = $poetryRunner
            if ($Ctx.UpgradePackages -and $Ctx.UpgradePackages.Count -gt 0) { Invoke-PmUpdateSelectedDeps -Ctx $Ctx -Packages $Ctx.UpgradePackages -IncludeDev $Ctx.IncludeDev }
            elseif ($Ctx.UpdateDependencies -and -not $Ctx.PinExact) { Invoke-PmUpdateDeps -Ctx $Ctx -IncludeDev $Ctx.IncludeDev }
            else { Invoke-PmInstallDeps -Ctx $Ctx -IncludeDev $Ctx.IncludeDev }
        }
        'pip-requirements' {
            $args = @('-m','pip','install'); if ($Ctx.UpdateDependencies -and -not $Ctx.PinExact) { $args += '--upgrade' }; $args += @('-r',$requirementsFile)
            Invoke-NativeCommand -Executable $venvPython -Arguments $args -WorkingDirectory $Ctx.ProjectRoot -PassThrough -ThrowOnError | Out-Null
        }
        default {
            if (Test-Path -LiteralPath $requirementsFile -PathType Leaf) { Invoke-NativeCommand -Executable $venvPython -Arguments @('-m','pip','install','-r',$requirementsFile) -WorkingDirectory $Ctx.ProjectRoot -PassThrough -ThrowOnError | Out-Null }
            elseif (Test-Path -LiteralPath $pyprojectFile -PathType Leaf) { Invoke-NativeCommand -Executable $venvPython -Arguments @('-m','pip','install','-e',$Ctx.ProjectRoot) -WorkingDirectory $Ctx.ProjectRoot -PassThrough -ThrowOnError | Out-Null }
            else { throw 'Could not detect a supported dependency system for update-venv mode.' }
        }
    }

    Add-ToolDirsToPath -Directories @((Join-Path $Ctx.VenvDir 'Scripts')) -Reason 'project .venv CLI' | Out-Null
    if ($Ctx.EnableCodeSigning) { $Ctx.SignResult = Set-VenvScriptSignature -VenvDir $Ctx.VenvDir -PoetryOnly:$SignPoetryOnly -Confirm:$false }
    [pscustomobject]@{ PackageManager=$Ctx.PackageManager; VenvDir=$Ctx.VenvDir; Signing=$Ctx.SignResult }
}

Export-ModuleMember -Function New-SetupContext, Invoke-PackageManagerDetectionStep, Invoke-PrecheckStep, Invoke-ProjectMetadataStep, Invoke-PythonDetectionStep, Invoke-PackageManagerRuntimeStep, Invoke-PackageManagerSigningStep, Invoke-PackageManagerConfigureStep, Invoke-PackageManagerCleanupStep, Invoke-VenvBackupStep, Invoke-VenvPrepareStep, Invoke-VenvValidationStep, Invoke-VenvRuntimeCopyStep, Invoke-LockSyncStep, Invoke-DependencyInstallStep, Invoke-VenvPathStep, Invoke-ProjectPthStep, Invoke-VSCodeStep, Invoke-TclStep, Invoke-SmartSigningStep, Invoke-StaleCleanupStep, Invoke-VenvBackupCleanupStep, Invoke-ExistingVenvUpdateStep
