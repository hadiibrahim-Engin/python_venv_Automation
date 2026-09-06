#Requires -Version 5.1
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\Config.psm1'
    Import-Module $modulePath -Force
}
AfterAll { Remove-Module Config -Force -ErrorAction SilentlyContinue }

Describe 'Write-SetupConfig' {
    It 'writes values and preserves unknown keys' {
        $root = Join-Path $TestDrive 'project'
        New-Item -ItemType Directory -Path $root | Out-Null
        '{"Custom":"keep"}' | Set-Content -LiteralPath (Join-Path $root '.setup-config.json') -Encoding UTF8

        Write-SetupConfig -ProjectRoot $root -Values @{ PackageManager='uv' } -NonInteractive -Confirm:$false | Should -BeTrue
        $cfg = Get-Content -LiteralPath (Join-Path $root '.setup-config.json') -Raw | ConvertFrom-Json
        $cfg.Custom | Should -Be 'keep'
        $cfg.PackageManager | Should -Be 'uv'
    }

    It 'throws in non-interactive mode when persistence fails' {
        $root = Join-Path $TestDrive 'project2'
        New-Item -ItemType Directory -Path $root | Out-Null
        InModuleScope Config -Parameters @{ Root=$root } {
            Mock Set-Content { throw 'disk full' }
            { Write-SetupConfig -ProjectRoot $Root -Values @{ PackageManager='uv' } -NonInteractive -Confirm:$false } | Should -Throw '*Could not persist*'
        }
    }

    It 'can continue interactively without persistence only after explicit yes' {
        $root = Join-Path $TestDrive 'project3'
        New-Item -ItemType Directory -Path $root | Out-Null
        $oldCi = $env:CI
        try {
            $env:CI = $null
            InModuleScope Config -Parameters @{ Root=$root } {
                Mock Set-Content { throw 'read only' }
                Mock Read-Host { 'yes' }
                Write-SetupConfig -ProjectRoot $Root -Values @{ PackageManager='poetry' } -Confirm:$false | Should -BeFalse
            }
        }
        finally {
            $env:CI = $oldCi
        }
    }
}

Describe 'Read-SetupConfig fails loudly on a malformed file' {
    It 'throws CONFIG_INVALID instead of silently falling back to auto-detection' {
        $root = Join-Path $TestDrive 'badconfig'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root '.setup-config.json') -Value '{ not json' -Encoding UTF8
        Clear-SetupConfigCache

        $err = $null
        try { Read-SetupConfig -ProjectRoot $root } catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.ErrorCode | Should -Be 'CONFIG_INVALID'
    }

    It 'returns $null when there is simply no config file' {
        $root = Join-Path $TestDrive 'noconfig'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Clear-SetupConfigCache
        Read-SetupConfig -ProjectRoot $root | Should -BeNullOrEmpty
    }
}
