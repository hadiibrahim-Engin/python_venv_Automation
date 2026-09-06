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

Describe 'Package manager ambiguity (PEP 621 is tool-neutral)' {
    BeforeAll {
        $script:modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts4PythonAutomation/SetupCore/modules'
        Import-Module (Join-Path $script:modulesDir 'Toml.psm1') -Force -DisableNameChecking

        # Pester 5 runs Describe bodies at discovery time, so helper functions
        # must be defined inside BeforeAll to exist during the run phase.
        function New-PyProject {
            param([string] $Root, [string] $Toml, [string[]] $Locks = @())
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Root 'pyproject.toml') -Value $Toml -Encoding UTF8
            foreach ($l in $Locks) { Set-Content -LiteralPath (Join-Path $Root $l) -Value '' -Encoding UTF8 }
            Clear-TomlCache
            InModuleScope Detection { Clear-SetupConfigCache }
            return $Root
        }
    }

    It 'reports Ambiguous for a PEP 621-only project instead of assuming uv' {
        $root = New-PyProject -Root (Join-Path $TestDrive 'pep621') -Toml @'
[project]
name = "demo"
version = "0.1.0"
requires-python = ">=3.11"
'@
        $r = Get-PmDetectionReport -ProjectRoot $root
        $r.Status | Should -Be 'Ambiguous'
        $r.AmbiguityCode | Should -Be 'PYPROJECT_PM_AMBIGUOUS'
        $r.PackageManager | Should -BeNullOrEmpty
        $r.Candidates | Should -Contain 'uv'
        $r.Candidates | Should -Contain 'poetry'
    }

    It 'reports MULTIPLE_LOCKFILES when both lock files exist, ignoring mtime' {
        $root = New-PyProject -Root (Join-Path $TestDrive 'dual') -Toml @'
[project]
name = "demo"
version = "0.1.0"
requires-python = ">=3.11"
'@ -Locks @('uv.lock', 'poetry.lock')
        # Make uv.lock clearly newer; the old implementation would pick uv.
        (Get-Item (Join-Path $root 'uv.lock')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(1)
        $r = Get-PmDetectionReport -ProjectRoot $root
        $r.Status | Should -Be 'Ambiguous'
        $r.AmbiguityCode | Should -Be 'PYPROJECT_MULTIPLE_LOCKFILES'
    }

    It 'still resolves uv when only uv evidence is present' {
        $root = New-PyProject -Root (Join-Path $TestDrive 'uvonly') -Toml @'
[project]
name = "demo"
[tool.uv]
package = true
'@
        $r = Get-PmDetectionReport -ProjectRoot $root
        $r.Status | Should -Be 'Resolved'
        $r.PackageManager | Should -Be 'uv'
    }

    It 'resolves uv from uv.lock alone' {
        $root = New-PyProject -Root (Join-Path $TestDrive 'uvlock') -Toml @'
[project]
name = "demo"
'@ -Locks @('uv.lock')
        (Get-PmDetectionReport -ProjectRoot $root).PackageManager | Should -Be 'uv'
    }

    It 'still resolves poetry when only poetry evidence is present' {
        $root = New-PyProject -Root (Join-Path $TestDrive 'poetryonly') -Toml @'
[tool.poetry]
name = "demo"
'@ -Locks @('poetry.lock')
        $r = Get-PmDetectionReport -ProjectRoot $root
        $r.Status | Should -Be 'Resolved'
        $r.PackageManager | Should -Be 'poetry'
    }

    It 'treats a project with both tool sections as ambiguous' {
        $root = New-PyProject -Root (Join-Path $TestDrive 'bothtools') -Toml @'
[project]
name = "demo"
[tool.uv]
package = true
[tool.poetry]
name = "demo"
'@
        (Get-PmDetectionReport -ProjectRoot $root).Status | Should -Be 'Ambiguous'
    }

    It 'falls back to the poetry default only when there is no signal at all' {
        $root = Join-Path $TestDrive 'nosignal'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Clear-TomlCache
        $r = Get-PmDetectionReport -ProjectRoot $root
        $r.Status | Should -Be 'Default'
        $r.PackageManager | Should -Be 'poetry'
    }

    It 'ignores tool sections that only appear inside comments' {
        $root = New-PyProject -Root (Join-Path $TestDrive 'commented') -Toml @'
[project]
name = "demo"
# [tool.poetry]
'@ -Locks @('uv.lock')
        $r = Get-PmDetectionReport -ProjectRoot $root
        $r.Status | Should -Be 'Resolved'
        $r.PackageManager | Should -Be 'uv'
    }
}

Describe 'Resolve-PackageManager fail-closed behaviour' {
    BeforeAll {
        $script:modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts4PythonAutomation/SetupCore/modules'
        Import-Module (Join-Path $script:modulesDir 'Toml.psm1') -Force -DisableNameChecking
    }

    It 'throws PYPROJECT_PM_AMBIGUOUS in non-interactive mode' {
        $root = Join-Path $TestDrive 'ni-ambiguous'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Value "[project]`nname = `"demo`"" -Encoding UTF8
        Clear-TomlCache
        InModuleScope Detection { Clear-SetupConfigCache }

        $err = $null
        try { Resolve-PackageManager -CliChoice auto -ProjectRoot $root -NonInteractive } catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.ErrorCode | Should -Be 'PYPROJECT_PM_AMBIGUOUS'
        $err.Step | Should -Be 'DETECT'
    }

    It 'lets an explicit CLI choice override an ambiguous project' {
        $root = Join-Path $TestDrive 'ni-cli'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Value "[project]`nname = `"demo`"" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'uv.lock') -Value '' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'poetry.lock') -Value '' -Encoding UTF8
        Clear-TomlCache
        InModuleScope Detection { Clear-SetupConfigCache }

        $r = Resolve-PackageManager -CliChoice poetry -ProjectRoot $root -NonInteractive
        $r.PackageManager | Should -Be 'poetry'
        $r.Source | Should -Be 'cli'
    }

    It 'fails closed on a headless host even without -NonInteractive' {
        # Read-Host returns $null with no console attached; prompting there
        # would burn three attempts and end in a confusing error.
        $root = Join-Path $TestDrive 'headless'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Value "[project]`nname = `"demo`"" -Encoding UTF8
        Clear-TomlCache
        InModuleScope Detection { Clear-SetupConfigCache }

        Mock -ModuleName Detection Test-SetupInteractive { $false }
        Mock -ModuleName Detection Read-Host { throw 'Read-Host must not be called on a headless host' }

        $err = $null
        try { Resolve-PackageManager -CliChoice auto -ProjectRoot $root } catch { $err = $_.Exception }
        $err.ErrorCode | Should -Be 'PYPROJECT_PM_AMBIGUOUS'
        Should -Invoke -ModuleName Detection Read-Host -Times 0 -Exactly
    }

    It 'survives Read-Host returning $null when a console is claimed to exist' {
        $root = Join-Path $TestDrive 'nullanswer'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Value "[project]`nname = `"demo`"" -Encoding UTF8
        Clear-TomlCache
        InModuleScope Detection { Clear-SetupConfigCache }

        Mock -ModuleName Detection Test-SetupInteractive { $true }
        Mock -ModuleName Detection Read-Host { $null }

        # Must raise the structured error, not "cannot call a method on a
        # null-valued expression".
        $err = $null
        try { Resolve-PackageManager -CliChoice auto -ProjectRoot $root } catch { $err = $_.Exception }
        $err.ErrorCode | Should -Be 'PYPROJECT_PM_AMBIGUOUS'
    }

    It 'accepts an interactive selection and reports source user-decision' {
        $root = Join-Path $TestDrive 'interactive'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Value "[project]`nname = `"demo`"" -Encoding UTF8
        Clear-TomlCache
        InModuleScope Detection { Clear-SetupConfigCache }

        Mock -ModuleName Detection Test-SetupInteractive { $true }
        Mock -ModuleName Detection Read-Host { '2' }
        $r = Resolve-PackageManager -CliChoice auto -ProjectRoot $root
        $r.PackageManager | Should -Be 'poetry'
        $r.Source | Should -Be 'user-decision'
    }

    It 'throws when the operator never gives a valid answer' {
        $root = Join-Path $TestDrive 'interactive-bad'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Value "[project]`nname = `"demo`"" -Encoding UTF8
        Clear-TomlCache
        InModuleScope Detection { Clear-SetupConfigCache }

        Mock -ModuleName Detection Test-SetupInteractive { $true }
        Mock -ModuleName Detection Read-Host { 'nonsense' }
        { Resolve-PackageManager -CliChoice auto -ProjectRoot $root } | Should -Throw
    }
}

Describe 'Get-PreferredPackageManager' {
    BeforeAll {
        $script:modulesDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts4PythonAutomation/SetupCore/modules'
        Import-Module (Join-Path $script:modulesDir 'Toml.psm1') -Force -DisableNameChecking
    }

    It 'throws rather than returning $null for an ambiguous project' {
        $root = Join-Path $TestDrive 'pref-ambiguous'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Value "[project]`nname = `"demo`"" -Encoding UTF8
        Clear-TomlCache
        { Get-PreferredPackageManager -ProjectRoot $root } | Should -Throw '*ambiguous*'
    }
}
