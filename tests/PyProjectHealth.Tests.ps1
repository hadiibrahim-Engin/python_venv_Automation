#Requires -Version 5.1
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modules = Join-Path $repoRoot 'scripts4PythonAutomation/SetupCore/modules'
    foreach ($m in 'Errors', 'Constants', 'UI', 'Logging', 'Versioning', 'TomlParser', 'Config', 'Toml', 'PyProjectHealth') {
        Import-Module (Join-Path $modules "$m.psm1") -Force -DisableNameChecking -Global
    }

    function New-Project {
        # $Toml is [object] so that $null means "write no file at all";
        # a [string] parameter would coerce $null to '' and create an empty file.
        param([string] $Name, [AllowNull()][object] $Toml, [string[]] $Locks = @())
        $root = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        if ($null -ne $Toml) { Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Value $Toml -Encoding UTF8 }
        foreach ($l in $Locks) { Set-Content -LiteralPath (Join-Path $root $l) -Value 'lock' -Encoding UTF8 }
        Clear-PyProjectHealthCache
        return $root
    }

    function Get-Codes {
        param([string] $Root)
        Clear-PyProjectHealthCache
        (Get-PyProjectHealthReport -ProjectRoot $Root).Findings | ForEach-Object { $_.Code }
    }
}
AfterAll { Remove-Module PyProjectHealth -Force -ErrorAction SilentlyContinue }

Describe 'Get-PyProjectHealthReport - healthy projects' {
    It 'reports a clean uv project as healthy' {
        $root = New-Project -Name 'ok-uv' -Locks @('uv.lock') -Toml @'
[project]
name = "demo"
version = "1.0.0"
requires-python = ">=3.11,<3.13"
dependencies = ["requests"]

[tool.uv]
package = true
'@
        $r = Get-PyProjectHealthReport -ProjectRoot $root
        $r.HasErrors | Should -BeFalse
        $r.PackageManager | Should -Be 'uv'
        $r.Metadata.Name | Should -Be 'demo'
        $r.Metadata.Version | Should -Be '1.0.0'
    }

    It 'reports a clean Poetry project as healthy' {
        $root = New-Project -Name 'ok-poetry' -Locks @('poetry.lock') -Toml @'
[tool.poetry]
name = "demo"
version = "0.4.0"

[tool.poetry.dependencies]
python = "^3.11"

[build-system]
requires = ["poetry-core"]
build-backend = "poetry.core.masonry.api"
'@
        $r = Get-PyProjectHealthReport -ProjectRoot $root
        $r.HasErrors | Should -BeFalse
        $r.PackageManager | Should -Be 'poetry'
        $r.Metadata.RequiresPython | Should -Be '^3.11'
    }
}

Describe 'Get-PyProjectHealthReport - file level' {
    It 'reports PYPROJECT_MISSING' {
        $root = New-Project -Name 'nofile' -Toml $null
        Get-Codes -Root $root | Should -Contain 'PYPROJECT_MISSING'
    }

    It 'reports PYPROJECT_EMPTY' {
        $root = New-Project -Name 'emptyfile' -Toml ''
        Get-Codes -Root $root | Should -Contain 'PYPROJECT_EMPTY'
    }

    It 'reports PYPROJECT_PARSE_INVALID for malformed TOML' {
        $root = New-Project -Name 'broken' -Toml "[project`nname = broken"
        $codes = Get-Codes -Root $root
        $codes | Should -Contain 'PYPROJECT_PARSE_INVALID'
    }

    It 'does not judge lock health when the document cannot be parsed' {
        $root = New-Project -Name 'broken2' -Toml "[project`nname = broken"
        Get-Codes -Root $root | Should -Not -Contain 'LOCK_MISSING'
    }
}

Describe 'Get-PyProjectHealthReport - metadata' {
    It 'reports PYPROJECT_NAME_MISSING' {
        $root = New-Project -Name 'noname' -Locks @('uv.lock') -Toml "[project]`nversion = `"1.0.0`"`nrequires-python = `">=3.11`"`n`n[tool.uv]`npackage = true"
        Get-Codes -Root $root | Should -Contain 'PYPROJECT_NAME_MISSING'
    }

    It 'reports PYPROJECT_VERSION_MISSING' {
        $root = New-Project -Name 'nover' -Locks @('uv.lock') -Toml "[project]`nname = `"d`"`nrequires-python = `">=3.11`"`n`n[tool.uv]`npackage = true"
        Get-Codes -Root $root | Should -Contain 'PYPROJECT_VERSION_MISSING'
    }

    It 'reports PYPROJECT_REQUIRES_PYTHON_MISSING' {
        $root = New-Project -Name 'nopy' -Locks @('uv.lock') -Toml "[project]`nname = `"d`"`nversion = `"1.0.0`"`n`n[tool.uv]`npackage = true"
        Get-Codes -Root $root | Should -Contain 'PYPROJECT_REQUIRES_PYTHON_MISSING'
    }

    It 'reports PYPROJECT_METADATA_DIVERGED when the dialects disagree' {
        $root = New-Project -Name 'diverged' -Locks @('poetry.lock') -Toml @'
[tool.poetry]
name = "demo"
version = "9.9.9"

[project]
name = "demo"
version = "1.2.3"
requires-python = ">=3.11"
'@
        Get-Codes -Root $root | Should -Contain 'PYPROJECT_METADATA_DIVERGED'
    }

    It 'reports PYPROJECT_POETRY_METADATA_LEGACY' {
        $root = New-Project -Name 'legacymeta' -Locks @('poetry.lock') -Toml @'
[tool.poetry]
name = "demo"

[project]
name = "demo"
version = "1.0.0"
requires-python = ">=3.11"
'@
        Get-Codes -Root $root | Should -Contain 'PYPROJECT_POETRY_METADATA_LEGACY'
    }
}

Describe 'Get-PyProjectHealthReport - python constraints' {
    It 'reports PYPROJECT_PYTHON_CONSTRAINT_INVALID' {
        $root = New-Project -Name 'badpy' -Locks @('uv.lock') -Toml @'
[project]
name = "d"
version = "1.0.0"
requires-python = ">=3.11 <3.13"

[tool.uv]
package = true
'@
        Get-Codes -Root $root | Should -Contain 'PYPROJECT_PYTHON_CONSTRAINT_INVALID'
    }

    It 'reports PYPROJECT_PYTHON_CONSTRAINT_CONFLICT' {
        $root = New-Project -Name 'conflictpy' -Locks @('poetry.lock') -Toml @'
[project]
name = "d"
version = "1.0.0"
requires-python = ">=3.11"

[tool.poetry.dependencies]
python = "^3.10"
'@
        Get-Codes -Root $root | Should -Contain 'PYPROJECT_PYTHON_CONSTRAINT_CONFLICT'
    }
}

Describe 'Get-PyProjectHealthReport - dependencies and tooling' {
    It 'reports PYPROJECT_DUPLICATE_DEPENDENCY across differing spellings' {
        $root = New-Project -Name 'dupdeps' -Locks @('uv.lock') -Toml @'
[project]
name = "d"
version = "1.0.0"
requires-python = ">=3.11"
dependencies = ["requests>=2.31", "Requests", "rich"]

[tool.uv]
package = true
'@
        Get-Codes -Root $root | Should -Contain 'PYPROJECT_DUPLICATE_DEPENDENCY'
    }

    It 'reports PYPROJECT_LEGACY_UV_DEV_DEPENDENCIES as a safe auto-fix' {
        $root = New-Project -Name 'legacyuv' -Locks @('uv.lock') -Toml @'
[project]
name = "d"
version = "1.0.0"
requires-python = ">=3.11"

[tool.uv]
dev-dependencies = ["pytest"]
'@
        Clear-PyProjectHealthCache
        $f = (Get-PyProjectHealthReport -ProjectRoot $root).Findings |
             Where-Object Code -eq 'PYPROJECT_LEGACY_UV_DEV_DEPENDENCIES'
        $f | Should -Not -BeNullOrEmpty
        $f.AutoFixable | Should -BeTrue
        $f.FixClass | Should -Be 'SafeAutoFix'
    }

    It 'escalates legacy uv dev-dependencies to NeedsDecision when both locations are used' {
        $root = New-Project -Name 'bothdev' -Locks @('uv.lock') -Toml @'
[project]
name = "d"
version = "1.0.0"
requires-python = ">=3.11"

[dependency-groups]
dev = ["ruff"]

[tool.uv]
dev-dependencies = ["pytest"]
'@
        Clear-PyProjectHealthCache
        $f = (Get-PyProjectHealthReport -ProjectRoot $root).Findings |
             Where-Object Code -eq 'PYPROJECT_LEGACY_UV_DEV_DEPENDENCIES'
        $f.FixClass | Should -Be 'NeedsDecision'
        $f.AutoFixable | Should -BeFalse
    }

    It 'reports PYPROJECT_UV_SOURCE_ORPHANED' {
        $root = New-Project -Name 'orphan' -Locks @('uv.lock') -Toml @'
[project]
name = "d"
version = "1.0.0"
requires-python = ">=3.11"
dependencies = ["rich"]

[tool.uv.sources]
ghost = { git = "https://x.invalid/g.git" }
'@
        Get-Codes -Root $root | Should -Contain 'PYPROJECT_UV_SOURCE_ORPHANED'
    }

    It 'does not report an orphan when the source is a declared dependency' {
        $root = New-Project -Name 'notorphan' -Locks @('uv.lock') -Toml @'
[project]
name = "d"
version = "1.0.0"
requires-python = ">=3.11"
dependencies = ["my-lib>=1.0"]

[tool.uv.sources]
my_lib = { git = "https://x.invalid/g.git" }
'@
        Get-Codes -Root $root | Should -Not -Contain 'PYPROJECT_UV_SOURCE_ORPHANED'
    }
}

Describe 'Test-PyProjectLockHealth' {
    It 'reports LOCK_MISSING as a safe auto-fix' {
        $root = New-Project -Name 'nolock' -Toml "[project]`nname=`"d`"`nversion=`"1.0.0`"`nrequires-python=`">=3.11`"`n`n[tool.uv]`npackage = true"
        $f = Test-PyProjectLockHealth -ProjectRoot $root -PackageManager 'uv'
        $f.Code | Should -Be 'LOCK_MISSING'
        $f.AutoFixable | Should -BeTrue
    }

    It 'reports LOCK_WRONG_MANAGER without offering to overwrite' {
        $root = New-Project -Name 'wronglock' -Locks @('poetry.lock') -Toml "[project]`nname=`"d`"`n`n[tool.uv]`npackage = true"
        $f = Test-PyProjectLockHealth -ProjectRoot $root -PackageManager 'uv'
        ($f | Where-Object Code -eq 'LOCK_WRONG_MANAGER').FixClass | Should -Be 'NeedsDecision'
    }

    It 'reports PYPROJECT_MULTIPLE_LOCKFILES for dual locks' {
        $root = New-Project -Name 'duallock' -Locks @('uv.lock', 'poetry.lock') -Toml "[project]`nname=`"d`"`n"
        (Test-PyProjectLockHealth -ProjectRoot $root -PackageManager 'uv' | ForEach-Object Code) |
            Should -Contain 'PYPROJECT_MULTIPLE_LOCKFILES'
    }

    It 'reports LOCK_INVALID for an empty lock file' {
        $root = New-Project -Name 'emptylock' -Toml "[project]`nname=`"d`"`n`n[tool.uv]`npackage = true"
        Set-Content -LiteralPath (Join-Path $root 'uv.lock') -Value '' -Encoding UTF8
        (Test-PyProjectLockHealth -ProjectRoot $root -PackageManager 'uv' | ForEach-Object Code) |
            Should -Contain 'LOCK_INVALID'
    }

    It 'reports LOCK_OUTDATED when the lock predates pyproject.toml' {
        $root = New-Project -Name 'stalelock' -Locks @('uv.lock') -Toml "[project]`nname=`"d`"`n`n[tool.uv]`npackage = true"
        (Get-Item (Join-Path $root 'uv.lock')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-2)
        (Test-PyProjectLockHealth -ProjectRoot $root -PackageManager 'uv' | ForEach-Object Code) |
            Should -Contain 'LOCK_OUTDATED'
    }

    It 'reports nothing for a fresh matching lock' {
        $root = New-Project -Name 'freshlock' -Locks @('uv.lock') -Toml "[project]`nname=`"d`"`n`n[tool.uv]`npackage = true"
        (Get-Item (Join-Path $root 'uv.lock')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(1)
        @(Test-PyProjectLockHealth -ProjectRoot $root -PackageManager 'uv').Count | Should -Be 0
    }
}

Describe 'Test-PyProjectHealth' {
    It 'is true when only warnings exist and false in strict mode' {
        $root = New-Project -Name 'warnonly' -Locks @('uv.lock') -Toml @'
[project]
name = "d"
requires-python = ">=3.11"

[tool.uv]
package = true
'@
        Test-PyProjectHealth -ProjectRoot $root -NoCache | Should -BeTrue
        Test-PyProjectHealth -ProjectRoot $root -Strict -NoCache | Should -BeFalse
    }

    It 'is false when an error exists' {
        $root = New-Project -Name 'haserr' -Toml "[project]`nname = `"d`"`nversion = `"1.0.0`"`n"
        Test-PyProjectHealth -ProjectRoot $root -NoCache | Should -BeFalse
    }
}

Describe 'Health report caching' {
    It 'serves a cached report until the cache is cleared' {
        $root = New-Project -Name 'cache' -Locks @('uv.lock') -Toml @'
[project]
name = "before"
version = "1.0.0"
requires-python = ">=3.11"

[tool.uv]
package = true
'@
        (Get-PyProjectHealthReport -ProjectRoot $root).Metadata.Name | Should -Be 'before'

        Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Encoding UTF8 -Value @'
[project]
name = "after"
version = "1.0.0"
requires-python = ">=3.11"

[tool.uv]
package = true
'@
        (Get-PyProjectHealthReport -ProjectRoot $root).Metadata.Name | Should -Be 'before'
        Clear-PyProjectHealthCache
        (Get-PyProjectHealthReport -ProjectRoot $root).Metadata.Name | Should -Be 'after'
    }

    It 'bypasses the cache with -NoCache' {
        $root = New-Project -Name 'nocache' -Locks @('uv.lock') -Toml "[project]`nname = `"one`"`nversion=`"1.0.0`"`nrequires-python=`">=3.11`"`n`n[tool.uv]`npackage = true"
        (Get-PyProjectHealthReport -ProjectRoot $root).Metadata.Name | Should -Be 'one'
        Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Encoding UTF8 -Value "[project]`nname = `"two`"`nversion=`"1.0.0`"`nrequires-python=`">=3.11`"`n`n[tool.uv]`npackage = true"
        (Get-PyProjectHealthReport -ProjectRoot $root -NoCache).Metadata.Name | Should -Be 'two'
    }
}

Describe 'Get-NormalizedDependencyName' {
    It 'normalises <In> to <Out>' -ForEach @(
        @{ In = 'requests';            Out = 'requests' }
        @{ In = 'Requests';            Out = 'requests' }
        @{ In = 'requests>=2.31';      Out = 'requests' }
        @{ In = 'requests[socks]>=2';  Out = 'requests' }
        @{ In = 'my_lib';              Out = 'my-lib' }
        @{ In = 'my.lib';              Out = 'my-lib' }
        @{ In = 'rich ; python_version < "3.12"'; Out = 'rich' }
        @{ In = '';                    Out = '' }
    ) {
        Get-NormalizedDependencyName -Requirement $In | Should -Be $Out
    }
}
