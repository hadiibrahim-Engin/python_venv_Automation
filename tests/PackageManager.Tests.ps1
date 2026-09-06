#Requires -Version 5.1
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modules = Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules'
    Import-Module (Join-Path $modules 'Detection.psm1') -Force
}
AfterAll { Remove-Module Detection -Force -ErrorAction SilentlyContinue }

Describe 'Resolve-PackageManager' {
    It 'prefers an explicit CLI choice' {
        $root = Join-Path $TestDrive 'cli'
        New-Item -ItemType Directory -Path $root | Out-Null
        $result = Resolve-PackageManager -CliChoice uv -ProjectRoot $root
        $result.PackageManager | Should -Be 'uv'
        $result.Source | Should -Be 'cli'
    }

    It 'uses a persisted explicit package-manager choice before detection' {
        $root = Join-Path $TestDrive 'config'
        New-Item -ItemType Directory -Path $root | Out-Null
        '{"PackageManager":"poetry"}' | Set-Content -LiteralPath (Join-Path $root '.setup-config.json') -Encoding UTF8
        InModuleScope Detection { Clear-SetupConfigCache }
        $result = Resolve-PackageManager -CliChoice auto -ProjectRoot $root
        $result.PackageManager | Should -Be 'poetry'
        $result.Source | Should -Be 'config-file'
    }

    It 'detects uv from an uv-specific pyproject section' {
        $root = Join-Path $TestDrive 'uv'
        New-Item -ItemType Directory -Path $root | Out-Null
        @'
[project]
name = "demo"
version = "0.1.0"
requires-python = ">=3.11"
[tool.uv]
package = true
'@ | Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Encoding UTF8
        InModuleScope Detection { Clear-SetupConfigCache }
        $result = Resolve-PackageManager -CliChoice auto -ProjectRoot $root
        $result.PackageManager | Should -Be 'uv'
    }

    It 'detects poetry from a poetry project section' {
        $root = Join-Path $TestDrive 'poetry'
        New-Item -ItemType Directory -Path $root | Out-Null
        @'
[tool.poetry]
name = "demo"
version = "0.1.0"
[build-system]
requires = ["poetry-core"]
build-backend = "poetry.core.masonry.api"
'@ | Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Encoding UTF8
        InModuleScope Detection { Clear-SetupConfigCache }
        $result = Resolve-PackageManager -CliChoice auto -ProjectRoot $root
        $result.PackageManager | Should -Be 'poetry'
    }
}
