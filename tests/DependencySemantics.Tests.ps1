#Requires -Version 5.1
<#
    Part O: a plain `devsetup` run must reach the project's desired state
    (lock-conform install). Upgrading every dependency is only ever allowed
    when the operator explicitly asks for it.
#>
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modules = Join-Path $repoRoot 'scripts4PythonAutomation/SetupCore/modules'
    foreach ($m in 'Errors', 'Constants', 'Logging', 'UI', 'Path', 'Versioning', 'Toml',
                   'NativeCommand', 'Config', 'Detection', 'Filesystem', 'Compat') {
        Import-Module (Join-Path $modules "$m.psm1") -Force -DisableNameChecking -Global
    }
    Import-Module (Join-Path $modules 'SetupSteps.psm1') -Force -DisableNameChecking -Global

    function New-Ctx {
        param(
            [bool] $UpdateDependencies = $false,
            [bool] $PinExact = $false,
            [string[]] $UpgradePackages = @()
        )
        @{
            VenvDir            = 'TestDrive:/proj/.venv'
            ProjectRoot        = 'TestDrive:/proj'
            IncludeDev         = $true
            SkipPoetryInstall  = $false
            PinExact           = $PinExact
            UpdateDependencies = $UpdateDependencies
            UpgradePackages    = $UpgradePackages
            PackageManager     = 'uv'
        }
    }
}
AfterAll { Remove-Module SetupSteps -Force -ErrorAction SilentlyContinue }

Describe 'Invoke-DependencyInstallStep - default is sync, not upgrade' {
    BeforeEach {
        Mock -ModuleName SetupSteps Invoke-PmInstallDeps { }
        Mock -ModuleName SetupSteps Invoke-PmUpdateDeps { }
        Mock -ModuleName SetupSteps Invoke-PmUpdateSelectedDeps { }
    }

    It 'a plain run installs from the lock file and never upgrades everything' {
        $result = Invoke-DependencyInstallStep -Ctx (New-Ctx) -Confirm:$false
        $result | Should -Be 'sync-locked'
        Should -Invoke -ModuleName SetupSteps Invoke-PmInstallDeps -Times 1 -Exactly
        Should -Invoke -ModuleName SetupSteps Invoke-PmUpdateDeps -Times 0 -Exactly
    }

    It 'upgrades everything only when UpdateDependencies is set' {
        $result = Invoke-DependencyInstallStep -Ctx (New-Ctx -UpdateDependencies $true) -Confirm:$false
        $result | Should -Be 'upgrade-all'
        Should -Invoke -ModuleName SetupSteps Invoke-PmUpdateDeps -Times 1 -Exactly
        Should -Invoke -ModuleName SetupSteps Invoke-PmInstallDeps -Times 0 -Exactly
    }

    It 'upgrades only the named packages when UpgradePackages is set' {
        $result = Invoke-DependencyInstallStep -Ctx (New-Ctx -UpgradePackages @('requests')) -Confirm:$false
        $result | Should -Be 'selective-upgrade'
        Should -Invoke -ModuleName SetupSteps Invoke-PmUpdateSelectedDeps -Times 1 -Exactly
        Should -Invoke -ModuleName SetupSteps Invoke-PmUpdateDeps -Times 0 -Exactly
    }

    It 'prefers selective upgrade over a blanket upgrade when both are requested' {
        $result = Invoke-DependencyInstallStep -Ctx (New-Ctx -UpdateDependencies $true -UpgradePackages @('requests')) -Confirm:$false
        $result | Should -Be 'selective-upgrade'
        Should -Invoke -ModuleName SetupSteps Invoke-PmUpdateDeps -Times 0 -Exactly
    }

    It 'PinExact installs exactly what the lock file pins' {
        $result = Invoke-DependencyInstallStep -Ctx (New-Ctx -PinExact $true) -Confirm:$false
        $result | Should -Be 'pin-exact'
        Should -Invoke -ModuleName SetupSteps Invoke-PmInstallDeps -Times 1 -Exactly
        Should -Invoke -ModuleName SetupSteps Invoke-PmUpdateDeps -Times 0 -Exactly
    }

    It 'honours -WhatIf and touches no package manager at all' {
        $result = Invoke-DependencyInstallStep -Ctx (New-Ctx) -WhatIf
        $result | Should -Be 'whatif'
        Should -Invoke -ModuleName SetupSteps Invoke-PmInstallDeps -Times 0 -Exactly
        Should -Invoke -ModuleName SetupSteps Invoke-PmUpdateDeps -Times 0 -Exactly
    }

    It 'skips entirely when SkipPoetryInstall is set' {
        $ctx = New-Ctx; $ctx.SkipPoetryInstall = $true
        Invoke-DependencyInstallStep -Ctx $ctx -Confirm:$false | Should -Be 'skipped'
        Should -Invoke -ModuleName SetupSteps Invoke-PmInstallDeps -Times 0 -Exactly
    }
}
