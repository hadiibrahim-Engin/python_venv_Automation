function Enter-DevSetupUpdateLock {
    <#
    .SYNOPSIS
        Tries to acquire the update lock; clears stale locks older than 10 min.

    .DESCRIPTION
        Returns $true if the lock was acquired (or a stale lock was reclaimed),
        $false if another live process holds it. Prevents two terminals from
        updating the module on disk at the same time and corrupting state.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string] $Path,
        [int]    $StaleMinutes = 10,
        [int]    $WaitSeconds = 5
    )

    if (-not $Path) { $Path = Get-DevSetupUpdateLockPath }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $age = (Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime
            if ($age.TotalMinutes -ge $StaleMinutes) {
                # Stale lock from a crashed/abandoned run - reclaim it.
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            } else {
                Start-Sleep -Milliseconds 250
                continue
            }
        }
        try {
            # Atomic-ish create: CreateNew throws if the file already exists.
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(("pid={0};time={1}" -f $PID, (Get-Date).ToString('o')))
                $fs.Write($bytes, 0, $bytes.Length)
            } finally {
                $fs.Dispose()
            }
            return $true
        } catch {
            Start-Sleep -Milliseconds 250
        }
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Exit-DevSetupUpdateLock {
    [CmdletBinding()]
    param([string] $Path)
    if (-not $Path) { $Path = Get-DevSetupUpdateLockPath }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Install-PythonVenvAutomationVersion {
    <#
    .SYNOPSIS
        Installs/updates the module from the configured repository.

    .DESCRIPTION
        Prefers PSResourceGet (Install-PSResource) and falls back to PowerShellGet
        (Install-Module) on Windows PowerShell 5.1. Always CurrentUser scope - no
        admin rights required.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ModuleName,
        [Parameter(Mandatory)] [string] $RepositoryName,
        [version] $RequiredVersion,
        [bool]    $AllowPrerelease = $false
    )

    if (Get-Command -Name 'Install-PSResource' -ErrorAction SilentlyContinue) {
        $params = @{ Name = $ModuleName; Repository = $RepositoryName; Scope = 'CurrentUser'; TrustRepository = $true; ErrorAction = 'Stop' }
        if ($RequiredVersion) { $params['Version'] = "$RequiredVersion" }
        if ($AllowPrerelease) { $params['Prerelease'] = $true }
        Install-PSResource @params
    } elseif (Get-Command -Name 'Install-Module' -ErrorAction SilentlyContinue) {
        $params = @{ Name = $ModuleName; Repository = $RepositoryName; Scope = 'CurrentUser'; Force = $true; ErrorAction = 'Stop' }
        if ($RequiredVersion) { $params['RequiredVersion'] = "$RequiredVersion" }
        if ($AllowPrerelease) { $params['AllowPrerelease'] = $true }
        Install-Module @params
    } else {
        throw 'Neither Install-PSResource nor Install-Module is available to install the module.'
    }
}

function Update-PythonVenvAutomationIfNeeded {
    <#
    .SYNOPSIS
        Checks installed vs. available version and installs/updates if required.

    .DESCRIPTION
        The programmatic counterpart of the shim's pre-import bootstrap check.
        Used by Update-PythonVenvAutomation (manual self-update) and covered by
        mock-based tests. Honors the configured policy, offline/timeout behavior,
        and serializes concurrent updates with a lock file.

        Returns a result hashtable: Updated (bool), Action, Target, Reason.

    .PARAMETER Config
        Runtime config hashtable (see Get-DevSetupRuntimeConfig). When omitted,
        the config is loaded from disk.

    .PARAMETER Force
        Force the check even if AutoUpdateEnabled is $false (manual self-update).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [hashtable] $Config,
        [switch]    $Force
    )

    if (-not $Config) { $Config = Get-DevSetupRuntimeConfig }

    $moduleName  = $Config.ModuleName
    $repoName    = $Config.RepositoryName
    $policy      = if ($Force) { if ($Config.AutoUpdatePolicy -eq 'Disabled') { 'LatestStable' } else { $Config.AutoUpdatePolicy } } else { $Config.AutoUpdatePolicy }
    $allowPre    = [bool]$Config.AllowPrerelease
    $offlineOk   = [bool]$Config.AllowOfflineContinue
    $timeout     = [int]$Config.UpdateTimeoutSeconds
    $required    = $null
    if ($Config.RequiredVersion) { try { $required = [version]$Config.RequiredVersion } catch { $required = $null } }

    if (-not $Force -and -not [bool]$Config.AutoUpdateEnabled) {
        return @{ Updated = $false; Action = 'none'; Target = $null; Reason = 'Auto-update disabled in config.' }
    }
    if (-not $Force -and $policy -eq 'Disabled') {
        return @{ Updated = $false; Action = 'none'; Target = $null; Reason = 'Auto-update policy is Disabled.' }
    }

    $installed = Get-InstalledPythonVenvAutomationVersion -ModuleName $moduleName

    # Pinned needs to know if the EXACT version exists locally.
    $pinnedInstalled = $false
    if ($policy -eq 'Pinned' -and $required) {
        $pinnedInstalled = [bool](Get-Module -ListAvailable -Name $moduleName -ErrorAction SilentlyContinue |
            Where-Object { [version]$_.Version -eq $required })
    }

    $available = Get-AvailablePythonVenvAutomationVersion -ModuleName $moduleName -RepositoryName $repoName -AllowPrerelease $allowPre -TimeoutSeconds $timeout

    $decision = Test-PythonVenvAutomationVersion -Policy $policy -Installed $installed -Available $available -RequiredVersion $required -PinnedInstalled $pinnedInstalled -AllowOfflineContinue $offlineOk

    switch ($decision.Action) {
        'fail' {
            throw ("PythonVenvAutomation update required but cannot proceed: {0}" -f $decision.Reason)
        }
        'none' {
            if ($decision.Reason -match 'Could not check') { Write-Warning $decision.Reason }
            return @{ Updated = $false; Action = 'none'; Target = $decision.Target; Reason = $decision.Reason }
        }
        default {
            # install or update
            Write-Host 'Checking PythonVenvAutomation version...'
            Write-Host ("Installed version: {0}" -f $(if ($installed) { $installed } else { '(none)' }))
            Write-Host ("Available version: {0}" -f $(if ($decision.Target) { $decision.Target } else { '(unknown)' }))

            $lockAcquired = Enter-DevSetupUpdateLock
            if (-not $lockAcquired) {
                Write-Warning 'Another process is updating PythonVenvAutomation. Continuing with the installed version.'
                return @{ Updated = $false; Action = 'none'; Target = $installed; Reason = 'Update lock held by another process.' }
            }
            try {
                # Re-check inside the lock: another terminal may have just updated.
                $installed2 = Get-InstalledPythonVenvAutomationVersion -ModuleName $moduleName
                if ($policy -eq 'Pinned' -and $required) {
                    $pinnedInstalled = [bool](Get-Module -ListAvailable -Name $moduleName -ErrorAction SilentlyContinue |
                        Where-Object { [version]$_.Version -eq $required })
                    if ($pinnedInstalled) {
                        return @{ Updated = $false; Action = 'none'; Target = $required; Reason = 'Pinned version already present.' }
                    }
                } elseif ($installed2 -and $decision.Target -and $installed2 -ge $decision.Target) {
                    return @{ Updated = $false; Action = 'none'; Target = $installed2; Reason = 'Already up to date (updated by another process).' }
                }

                Write-Host ("Updating PythonVenvAutomation to {0}..." -f $decision.Target)
                $reqForInstall = if ($policy -eq 'Pinned') { $required } else { $null }
                Install-PythonVenvAutomationVersion -ModuleName $moduleName -RepositoryName $repoName -RequiredVersion $reqForInstall -AllowPrerelease $allowPre
                Write-Host 'Update complete.'
                return @{ Updated = $true; Action = $decision.Action; Target = $decision.Target; Reason = $decision.Reason }
            } finally {
                Exit-DevSetupUpdateLock
            }
        }
    }
}
