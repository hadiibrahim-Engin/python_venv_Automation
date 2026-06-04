#Requires -Version 5.1
# Generated-shim dispatch tests. The shim runs in a child PowerShell against a
# STUB PythonVenvAutomation module (tests/fixtures) that records the dispatched
# parameters as JSON. The real setup pipeline is never executed, and auto-update
# is disabled in the test runtime config so no network call is made.

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:ModuleName = 'PythonVenvAutomation'
    $script:Manifest   = Join-Path $RepoRoot "$ModuleName\$ModuleName.psd1"
    $script:FixturesDir = Join-Path $PSScriptRoot 'fixtures'   # contains the stub module folder
    Import-Module $Manifest -Force

    # Build an isolated bin + runtime config with auto-update disabled.
    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("shim-run-" + [guid]::NewGuid().ToString('N'))
    $script:Bin  = Join-Path $Root 'bin'
    New-Item -ItemType Directory -Path $Bin -Force | Out-Null
    $script:Shims = InModuleScope PythonVenvAutomation -Parameters @{ Bin = $Bin } {
        param($Bin) New-DevSetupShim -BinDirectory $Bin -Force
    }
    @{
        ModuleName = 'PythonVenvAutomation'; RepositoryName = 'CompanyPS'
        CommandName = 'devsetup'; AutoUpdateEnabled = $false; AutoUpdatePolicy = 'Disabled'
        AllowOfflineContinue = $true; UpdateTimeoutSeconds = 5
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'config.json') -Encoding UTF8

    $script:PwshExe = (Get-Process -Id $PID).Path

    function script:Invoke-Shim {
        param([string[]] $ShimArgs)
        $origMod = $env:PSModulePath
        $env:PSModulePath = $script:FixturesDir + [System.IO.Path]::PathSeparator + $origMod
        try {
            $out = & $script:PwshExe -NoProfile -ExecutionPolicy Bypass -File $script:Shims.PsShimPath @ShimArgs 2>&1
        } finally {
            $env:PSModulePath = $origMod
        }
        return ($out | ForEach-Object { "$_" })
    }

    function script:Get-Dispatch {
        param([string[]] $ShimArgs)
        $lines = script:Invoke-Shim -ShimArgs $ShimArgs
        $json = ($lines | Where-Object { $_ -match '^\s*\{.*"Cmd"' } | Select-Object -Last 1)
        if (-not $json) { throw ("No dispatch JSON in output: " + ($lines -join ' | ')) }
        return ($json | ConvertFrom-Json)
    }
}

AfterAll {
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Module PythonVenvAutomation -Force -ErrorAction SilentlyContinue
}

Describe 'Friendly command mapping' {
    It 'help prints usage without dispatching to setup' {
        $lines = script:Invoke-Shim -ShimArgs @('help')
        ($lines -join "`n") | Should -Match 'devsetup - Python project environment setup automation'
        ($lines -join "`n") | Should -Not -Match '"Cmd":"Invoke"'
    }

    It 'no command -> plain setup' {
        $d = script:Get-Dispatch -ShimArgs @('--no-self-update')
        $d.Cmd | Should -Be 'Invoke'
        ($d.PSObject.Properties.Name -contains 'Mode') | Should -BeFalse
    }

    It 'dry -> -DryRun' {
        $d = script:Get-Dispatch -ShimArgs @('dry', '--no-self-update')
        $d.DryRun | Should -BeTrue
    }

    It 'update -> -Mode update-venv' {
        $d = script:Get-Dispatch -ShimArgs @('update', '--no-self-update')
        $d.Mode | Should -Be 'update-venv'
    }

    It 'upgrade -> -Mode update-venv -UpdateDependencies' {
        $d = script:Get-Dispatch -ShimArgs @('upgrade', '--no-self-update')
        $d.Mode | Should -Be 'update-venv'
        $d.UpdateDependencies | Should -BeTrue
    }

    It 'rebuild -> -ForceRecreateVenv' {
        $d = script:Get-Dispatch -ShimArgs @('rebuild', '--no-self-update')
        $d.ForceRecreateVenv | Should -BeTrue
    }

    It 'prod -> -ExcludeDev' {
        $d = script:Get-Dispatch -ShimArgs @('prod', '--no-self-update')
        $d.ExcludeDev | Should -BeTrue
    }

    It 'list-python -> -ListMode' {
        $d = script:Get-Dispatch -ShimArgs @('list-python', '--no-self-update')
        $d.ListMode | Should -BeTrue
    }

    It 'self-update -> Update-PythonVenvAutomation' {
        $lines = script:Invoke-Shim -ShimArgs @('self-update')
        ($lines -join "`n") | Should -Match '"Cmd":"Update"'
    }
}

Describe 'Raw passthrough after --' {
    It 'forwards raw params after -- (setup)' {
        $d = script:Get-Dispatch -ShimArgs @('--no-self-update', '--', '-PackageManager', 'uv', '-NonInteractive')
        $d.PackageManager | Should -Be 'uv'
        $d.NonInteractive | Should -BeTrue
    }

    It 'forwards raw params after -- combined with a friendly command' {
        $d = script:Get-Dispatch -ShimArgs @('update', '--no-self-update', '--', '-UpgradePackage', 'requests')
        $d.Mode | Should -Be 'update-venv'
        $d.UpgradePackage | Should -Be 'requests'
    }
}

Describe 'Shim-level flags are consumed, not forwarded' {
    It 'does not forward --no-self-update to Invoke-PythonVenvSetup' {
        $d = script:Get-Dispatch -ShimArgs @('dry', '--no-self-update')
        # The stub would have failed binding an unknown param; reaching a clean
        # dispatch with only DryRun proves the flag was consumed by the shim.
        $d.DryRun | Should -BeTrue
        ($d.PSObject.Properties.Name) | Should -Not -Contain 'no-self-update'
    }
}
