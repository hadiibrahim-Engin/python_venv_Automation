#Requires -Version 5.1
# =============================================================================
# DevSetup.Bootstrap.ps1
# -----------------------------------------------------------------------------
# Self-contained helper dot-sourced by the generated command shim BEFORE the
# PythonVenvAutomation module is imported. It performs the auto-update check so
# the freshly installed module files are the ones loaded for the actual run.
#
# It is intentionally standalone (no dependency on the module being importable)
# and is copied verbatim by New-DevSetupShim - it contains no command-name
# placeholder; the command name is passed in by the shim at call time.
# =============================================================================

function Get-DevSetupBootConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ConfigPath)

    $config = @{
        ModuleName           = 'PythonVenvAutomation'
        RepositoryName       = 'CompanyPS'
        RepositoryUri        = 'https://REPLACE_WITH_INTERNAL_NUGET_FEED/v3/index.json'
        CommandName          = 'devsetup'
        AutoUpdateEnabled    = $true
        AutoUpdatePolicy     = 'LatestStable'
        RequiredVersion      = $null
        AllowPrerelease      = $false
        AllowOfflineContinue = $true
        UpdateTimeoutSeconds  = 15
    }
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
                foreach ($p in $parsed.PSObject.Properties) { $config[$p.Name] = $p.Value }
            }
        } catch {
            Write-Warning ("Could not read runtime config: {0}. Using defaults." -f $_.Exception.Message)
        }
    }
    return $config
}

function Get-DevSetupBootInstalledVersion {
    param([Parameter(Mandatory)] [string] $ModuleName)
    $m = Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($m) { return [version]$m.Version }
    return $null
}

function Get-DevSetupBootAvailableVersion {
    param(
        [Parameter(Mandatory)] [string] $ModuleName,
        [Parameter(Mandatory)] [string] $RepositoryName,
        [bool] $AllowPrerelease = $false,
        [int]  $TimeoutSeconds = 15
    )
    $finder = {
        param($ModuleName, $RepositoryName, $AllowPrerelease)
        $ErrorActionPreference = 'Stop'
        if (Get-Command 'Find-PSResource' -ErrorAction SilentlyContinue) {
            $r = Find-PSResource -Name $ModuleName -Repository $RepositoryName -Prerelease:$AllowPrerelease -ErrorAction Stop |
                Sort-Object Version -Descending | Select-Object -First 1
            if ($r) { return [string]$r.Version }
        } elseif (Get-Command 'Find-Module' -ErrorAction SilentlyContinue) {
            $p = @{ Name = $ModuleName; Repository = $RepositoryName; ErrorAction = 'Stop' }
            if ($AllowPrerelease) { $p['AllowPrerelease'] = $true }
            $r = Find-Module @p | Sort-Object Version -Descending | Select-Object -First 1
            if ($r) { return [string]$r.Version }
        } else {
            throw 'No repository query cmdlet available.'
        }
        return $null
    }
    try {
        $job = Start-Job -ScriptBlock $finder -ArgumentList $ModuleName, $RepositoryName, $AllowPrerelease
        if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            Write-Warning ("Repository check exceeded {0}s timeout." -f $TimeoutSeconds)
            return $null
        }
        $raw = Receive-Job $job -ErrorAction Stop
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warning ("Could not query repository '{0}': {1}" -f $RepositoryName, $_.Exception.Message)
        return $null
    }
    if ($raw) {
        $stable = ([string]$raw -split '-', 2)[0]
        try { return [version]$stable } catch { return $null }
    }
    return $null
}

function Get-DevSetupBootDecision {
    param(
        [Parameter(Mandatory)] [string] $Policy,
        [version] $Installed,
        [version] $Available,
        [version] $RequiredVersion,
        [bool]    $PinnedInstalled = $false,
        [bool]    $AllowOfflineContinue = $true
    )
    function _d { param($a, $t, $r) @{ Action = $a; Target = $t; Reason = $r } }

    switch ($Policy) {
        'Disabled' { return _d 'none' $null 'Auto-update disabled.' }
        'Pinned' {
            if (-not $RequiredVersion) { return _d 'fail' $null 'Pinned policy requires RequiredVersion.' }
            if ($PinnedInstalled) { return _d 'none' $RequiredVersion 'Pinned version present.' }
            if ($null -eq $Available) { return _d 'fail' $RequiredVersion 'Pinned version missing and repository unreachable.' }
            return _d 'install' $RequiredVersion ("Installing pinned version {0}." -f $RequiredVersion)
        }
        'MinimumRequired' {
            if (-not $RequiredVersion) { return _d 'fail' $null 'MinimumRequired policy requires RequiredVersion.' }
            if ($null -eq $Installed) {
                if ($null -eq $Available) { return _d 'fail' $RequiredVersion 'No module installed and repository unreachable.' }
                return _d 'install' $RequiredVersion ("Installing required minimum {0}." -f $RequiredVersion)
            }
            if ($Installed -lt $RequiredVersion) {
                if ($null -eq $Available) { return _d 'fail' $RequiredVersion 'Below required minimum and repository unreachable.' }
                return _d 'update' $RequiredVersion ("Updating {0} -> at least {1}." -f $Installed, $RequiredVersion)
            }
            return _d 'none' $Installed 'Installed satisfies required minimum.'
        }
        default {
            # LatestStable
            if ($null -eq $Installed) {
                if ($null -eq $Available) { return _d 'fail' $null 'No module installed and repository unreachable.' }
                return _d 'install' $Available ("Installing latest stable {0}." -f $Available)
            }
            if ($null -eq $Available) {
                if ($AllowOfflineContinue) { return _d 'none' $Installed ("Could not check for updates. Continuing with installed {0}." -f $Installed) }
                return _d 'fail' $null 'Repository unreachable and offline continue disabled.'
            }
            if ($Available -gt $Installed) { return _d 'update' $Available ("Newer version available: {0} -> {1}." -f $Installed, $Available) }
            return _d 'none' $Installed 'Installed version is current.'
        }
    }
}

function Enter-DevSetupBootLock {
    param([Parameter(Mandatory)] [string] $Path, [int] $StaleMinutes = 10, [int] $WaitSeconds = 5)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $age = (Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime
            if ($age.TotalMinutes -ge $StaleMinutes) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
            else { Start-Sleep -Milliseconds 250; continue }
        }
        try {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $fs.Dispose()
            return $true
        } catch { Start-Sleep -Milliseconds 250 }
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Exit-DevSetupBootLock {
    param([Parameter(Mandatory)] [string] $Path)
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Install-DevSetupBootModule {
    param(
        [Parameter(Mandatory)] [string] $ModuleName,
        [Parameter(Mandatory)] [string] $RepositoryName,
        [version] $RequiredVersion,
        [bool] $AllowPrerelease = $false
    )
    if (Get-Command 'Install-PSResource' -ErrorAction SilentlyContinue) {
        $p = @{ Name = $ModuleName; Repository = $RepositoryName; Scope = 'CurrentUser'; TrustRepository = $true; ErrorAction = 'Stop' }
        if ($RequiredVersion) { $p['Version'] = "$RequiredVersion" }
        if ($AllowPrerelease) { $p['Prerelease'] = $true }
        Install-PSResource @p
    } elseif (Get-Command 'Install-Module' -ErrorAction SilentlyContinue) {
        $p = @{ Name = $ModuleName; Repository = $RepositoryName; Scope = 'CurrentUser'; Force = $true; ErrorAction = 'Stop' }
        if ($RequiredVersion) { $p['RequiredVersion'] = "$RequiredVersion" }
        if ($AllowPrerelease) { $p['AllowPrerelease'] = $true }
        Install-Module @p
    } else {
        throw 'No module install cmdlet available (Install-PSResource / Install-Module).'
    }
}

function Invoke-DevSetupBootAutoUpdate {
    <#
    .SYNOPSIS
        Runs the pre-import auto-update check. Returns $true if the module was
        installed/updated (so the shim should relaunch), otherwise $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $CommandName,
        [Parameter(Mandatory)] [string] $ConfigPath,
        [switch] $Force
    )

    $config = Get-DevSetupBootConfig -ConfigPath $ConfigPath
    $policy = "$($config.AutoUpdatePolicy)"

    if (-not $Force) {
        if (-not [bool]$config.AutoUpdateEnabled) { return $false }
        if ($policy -eq 'Disabled') { return $false }
    } elseif ($policy -eq 'Disabled') {
        $policy = 'LatestStable'
    }

    $moduleName = "$($config.ModuleName)"
    $repoName   = "$($config.RepositoryName)"
    $allowPre   = [bool]$config.AllowPrerelease
    $offlineOk  = [bool]$config.AllowOfflineContinue
    $timeout    = [int]$config.UpdateTimeoutSeconds
    $required   = $null
    if ($config.RequiredVersion) { try { $required = [version]$config.RequiredVersion } catch { $required = $null } }

    $installed = Get-DevSetupBootInstalledVersion -ModuleName $moduleName
    $pinnedInstalled = $false
    if ($policy -eq 'Pinned' -and $required) {
        $pinnedInstalled = [bool](Get-Module -ListAvailable -Name $moduleName -ErrorAction SilentlyContinue |
            Where-Object { [version]$_.Version -eq $required })
    }

    $available = Get-DevSetupBootAvailableVersion -ModuleName $moduleName -RepositoryName $repoName -AllowPrerelease $allowPre -TimeoutSeconds $timeout
    $decision  = Get-DevSetupBootDecision -Policy $policy -Installed $installed -Available $available -RequiredVersion $required -PinnedInstalled $pinnedInstalled -AllowOfflineContinue $offlineOk

    if ($decision.Action -eq 'fail') { throw ("Cannot run {0}: {1}" -f $CommandName, $decision.Reason) }
    if ($decision.Action -eq 'none') {
        if ($decision.Reason -match 'Could not check') { Write-Warning $decision.Reason }
        return $false
    }

    Write-Host 'Checking PythonVenvAutomation version...'
    Write-Host ("Installed version: {0}" -f $(if ($installed) { $installed } else { '(none)' }))
    Write-Host ("Available version: {0}" -f $(if ($decision.Target) { $decision.Target } else { '(unknown)' }))

    $lockPath = Join-Path (Split-Path -Parent $ConfigPath) 'update.lock'
    if (-not (Enter-DevSetupBootLock -Path $lockPath)) {
        Write-Warning 'Another process is updating. Continuing with the installed version.'
        return $false
    }
    try {
        # Re-check under the lock in case another terminal already updated.
        $installed2 = Get-DevSetupBootInstalledVersion -ModuleName $moduleName
        if ($policy -eq 'Pinned' -and $required) {
            if (Get-Module -ListAvailable -Name $moduleName -ErrorAction SilentlyContinue | Where-Object { [version]$_.Version -eq $required }) {
                return $false
            }
        } elseif ($installed2 -and $decision.Target -and $installed2 -ge $decision.Target) {
            return $false
        }
        Write-Host ("Updating PythonVenvAutomation to {0}..." -f $decision.Target)
        $reqForInstall = if ($policy -eq 'Pinned') { $required } else { $null }
        Install-DevSetupBootModule -ModuleName $moduleName -RepositoryName $repoName -RequiredVersion $reqForInstall -AllowPrerelease $allowPre
        return $true
    } finally {
        Exit-DevSetupBootLock -Path $lockPath
    }
}
