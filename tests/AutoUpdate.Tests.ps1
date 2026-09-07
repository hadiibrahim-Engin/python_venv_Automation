#Requires -Version 5.1
# Auto-update logic tests. All version lookups / installs are mocked - no real
# Azure Artifacts or GitHub Packages contact, and the setup pipeline never runs.

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:ModuleName = 'PythonVenvAutomation'
    $script:Manifest   = Join-Path $RepoRoot "$ModuleName\$ModuleName.psd1"
    Import-Module $Manifest -Force
}

AfterAll {
    Remove-Module PythonVenvAutomation -Force -ErrorAction SilentlyContinue
}

Describe 'Test-PythonVenvAutomationVersion (pure policy decisions)' {
    It 'LatestStable: updates when a newer version is available' {
        $d = InModuleScope PythonVenvAutomation { Test-PythonVenvAutomationVersion -Policy LatestStable -Installed ([version]'1.1.0') -Available ([version]'1.2.0') }
        $d.Action | Should -Be 'update'
        "$($d.Target)" | Should -Be '1.2.0'
    }
    It 'LatestStable: no update when installed is current' {
        $d = InModuleScope PythonVenvAutomation { Test-PythonVenvAutomationVersion -Policy LatestStable -Installed ([version]'1.2.0') -Available ([version]'1.2.0') }
        $d.Action | Should -Be 'none'
    }
    It 'LatestStable: installs when nothing is installed' {
        $d = InModuleScope PythonVenvAutomation { Test-PythonVenvAutomationVersion -Policy LatestStable -Installed $null -Available ([version]'1.2.0') }
        $d.Action | Should -Be 'install'
    }
    It 'LatestStable: offline + installed acceptable -> continue' {
        $d = InModuleScope PythonVenvAutomation { Test-PythonVenvAutomationVersion -Policy LatestStable -Installed ([version]'1.1.0') -Available $null -AllowOfflineContinue $true }
        $d.Action | Should -Be 'none'
        $d.Reason | Should -Match 'Could not check'
    }
    It 'LatestStable: offline + nothing installed -> fail' {
        $d = InModuleScope PythonVenvAutomation { Test-PythonVenvAutomationVersion -Policy LatestStable -Installed $null -Available $null -AllowOfflineContinue $true }
        $d.Action | Should -Be 'fail'
    }
    It 'MinimumRequired: accepts versions greater than the minimum' {
        $d = InModuleScope PythonVenvAutomation { Test-PythonVenvAutomationVersion -Policy MinimumRequired -Installed ([version]'1.3.0') -Available ([version]'1.4.0') -RequiredVersion ([version]'1.2.0') }
        $d.Action | Should -Be 'none'
    }
    It 'MinimumRequired: updates when installed is below minimum' {
        $d = InModuleScope PythonVenvAutomation { Test-PythonVenvAutomationVersion -Policy MinimumRequired -Installed ([version]'1.1.0') -Available ([version]'1.4.0') -RequiredVersion ([version]'1.2.0') }
        $d.Action | Should -Be 'update'
    }
    It 'Pinned: installs the exact version when missing' {
        $d = InModuleScope PythonVenvAutomation { Test-PythonVenvAutomationVersion -Policy Pinned -Installed ([version]'1.3.0') -Available ([version]'1.4.0') -RequiredVersion ([version]'1.2.0') -PinnedInstalled $false }
        $d.Action | Should -Be 'install'
        "$($d.Target)" | Should -Be '1.2.0'
    }
    It 'Pinned: no action when the exact version is already installed' {
        $d = InModuleScope PythonVenvAutomation { Test-PythonVenvAutomationVersion -Policy Pinned -Installed ([version]'1.2.0') -Available ([version]'1.4.0') -RequiredVersion ([version]'1.2.0') -PinnedInstalled $true }
        $d.Action | Should -Be 'none'
    }
    It 'Disabled: never updates' {
        $d = InModuleScope PythonVenvAutomation { Test-PythonVenvAutomationVersion -Policy Disabled -Installed ([version]'1.0.0') -Available ([version]'9.9.9') }
        $d.Action | Should -Be 'none'
    }
}

Describe 'Update-PythonVenvAutomationIfNeeded (orchestration, mocked)' {
    BeforeEach {
        $script:cfg = @{
            ModuleName = 'PythonVenvAutomation'; RepositoryName = 'CompanyPS'
            AutoUpdateEnabled = $true; AutoUpdatePolicy = 'LatestStable'
            RequiredVersion = $null; AllowPrerelease = $false; AllowOfflineContinue = $true
            UpdateTimeoutSeconds = 5
        }
    }

    It 'installs/updates when a newer version is available' {
        InModuleScope PythonVenvAutomation -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Get-InstalledPythonVenvAutomationVersion { [version]'1.0.0' }
            Mock Get-AvailablePythonVenvAutomationVersion { [version]'1.1.0' }
            Mock Enter-DevSetupUpdateLock { $true }
            Mock Exit-DevSetupUpdateLock { }
            Mock Install-PythonVenvAutomationVersion { }
            $r = Update-PythonVenvAutomationIfNeeded -Config $Cfg
            $r.Updated | Should -BeTrue
            Should -Invoke Install-PythonVenvAutomationVersion -Times 1
        }
    }

    It 'does nothing when the installed version is current' {
        InModuleScope PythonVenvAutomation -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Get-InstalledPythonVenvAutomationVersion { [version]'2.0.0' }
            Mock Get-AvailablePythonVenvAutomationVersion { [version]'2.0.0' }
            Mock Install-PythonVenvAutomationVersion { }
            $r = Update-PythonVenvAutomationIfNeeded -Config $Cfg
            $r.Updated | Should -BeFalse
            Should -Invoke Install-PythonVenvAutomationVersion -Times 0
        }
    }

    It 'installs when nothing is installed' {
        InModuleScope PythonVenvAutomation -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Get-InstalledPythonVenvAutomationVersion { $null }
            Mock Get-AvailablePythonVenvAutomationVersion { [version]'1.0.0' }
            Mock Enter-DevSetupUpdateLock { $true }
            Mock Exit-DevSetupUpdateLock { }
            Mock Install-PythonVenvAutomationVersion { }
            $r = Update-PythonVenvAutomationIfNeeded -Config $Cfg
            $r.Updated | Should -BeTrue
        }
    }

    It 'continues offline with an acceptable installed version' {
        InModuleScope PythonVenvAutomation -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Get-InstalledPythonVenvAutomationVersion { [version]'1.0.0' }
            Mock Get-AvailablePythonVenvAutomationVersion { $null }
            Mock Install-PythonVenvAutomationVersion { }
            $r = Update-PythonVenvAutomationIfNeeded -Config $Cfg
            $r.Updated | Should -BeFalse
            Should -Invoke Install-PythonVenvAutomationVersion -Times 0
        }
    }

    It 'fails offline when nothing acceptable is installed' {
        InModuleScope PythonVenvAutomation -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            $Cfg.AllowOfflineContinue = $false
            Mock Get-InstalledPythonVenvAutomationVersion { $null }
            Mock Get-AvailablePythonVenvAutomationVersion { $null }
            { Update-PythonVenvAutomationIfNeeded -Config $Cfg } | Should -Throw
        }
    }

    It 'skips the install when the update lock is held by another process' {
        InModuleScope PythonVenvAutomation -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Get-InstalledPythonVenvAutomationVersion { [version]'1.0.0' }
            Mock Get-AvailablePythonVenvAutomationVersion { [version]'1.1.0' }
            Mock Enter-DevSetupUpdateLock { $false }
            Mock Install-PythonVenvAutomationVersion { }
            $r = Update-PythonVenvAutomationIfNeeded -Config $Cfg
            $r.Updated | Should -BeFalse
            Should -Invoke Install-PythonVenvAutomationVersion -Times 0
        }
    }

    It 'does not check when auto-update is disabled (and is not forced)' {
        InModuleScope PythonVenvAutomation -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            $Cfg.AutoUpdateEnabled = $false
            Mock Get-AvailablePythonVenvAutomationVersion { throw 'should not be called' }
            $r = Update-PythonVenvAutomationIfNeeded -Config $Cfg
            $r.Updated | Should -BeFalse
        }
    }
}

Describe 'Bootstrap (pre-import) decision + relaunch guard' {
    BeforeAll {
        $script:Boot = Join-Path $RepoRoot "$ModuleName\templates\DevSetup.Bootstrap.ps1"
        . $Boot
    }

    # The distribution-based decision matrix is covered in full by
    # Bootstrap.Tests.ps1; these two just pin the shim-facing contract.
    It 'does nothing when the installed version already matches the channel' {
        $d = Get-DevSetupBootDecision -InstalledVersion '1.2.0' -ChannelVersion '1.2.0' -MinimumSupportedVersion '1.0.0'
        $d.Action | Should -Be 'none'
    }
    It 'installs when nothing is installed yet' {
        $d = Get-DevSetupBootDecision -InstalledVersion $null -ChannelVersion '1.2.0' -MinimumSupportedVersion '1.0.0'
        $d.Action | Should -Be 'install'
    }
    It 'derives a loop-guard env var name from the command name' {
        # Mirrors the formula baked into the generated shim.
        $name = ('devsetup'.ToUpperInvariant() -replace '[^A-Z0-9]', '_') + '_AUTO_UPDATE_RELAUNCHED'
        $name | Should -Be 'DEVSETUP_AUTO_UPDATE_RELAUNCHED'
        $name2 = ('env-ctl'.ToUpperInvariant() -replace '[^A-Z0-9]', '_') + '_AUTO_UPDATE_RELAUNCHED'
        $name2 | Should -Be 'ENV_CTL_AUTO_UPDATE_RELAUNCHED'
    }
}
