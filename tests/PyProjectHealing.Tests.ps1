#Requires -Version 5.1
<#
    Part Q: healing must be transactional. Either the document is fully
    repaired and still valid, or the original is restored untouched.
#>
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modules = Join-Path $repoRoot 'scripts4PythonAutomation/SetupCore/modules'
    foreach ($m in 'Errors', 'Constants', 'UI', 'Logging', 'Versioning', 'TomlParser', 'Config', 'Toml', 'PyProjectHealth') {
        Import-Module (Join-Path $modules "$m.psm1") -Force -DisableNameChecking -Global
    }

    function New-HealProject {
        param([string] $Name, [string] $Toml, [string[]] $Locks = @('uv.lock'))
        $root = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Value $Toml -Encoding UTF8
        foreach ($l in $Locks) { Set-Content -LiteralPath (Join-Path $root $l) -Value 'lock' -Encoding UTF8 }
        Clear-PyProjectHealthCache
        return $root
    }

    $script:DupToml = @'
[project]
name = "x"
version = "1.0.0"
requires-python = ">=3.11"
dependencies = ["requests>=2.31", "Requests", "rich"]

[tool.uv]
package = true
'@

    $script:LegacyToml = @'
[project]
name = "x"
version = "1.0.0"
requires-python = ">=3.11"

[tool.uv]
dev-dependencies = ["pytest", "ruff"]
'@
}
AfterAll { Remove-Module PyProjectHealth -Force -ErrorAction SilentlyContinue }

Describe 'Invoke-PyProjectHealing - safe fixes only' {
    It 'removes duplicate dependencies and keeps the first spelling' {
        $root = New-HealProject -Name 'dup' -Toml $script:DupToml
        $r = Invoke-PyProjectHealing -ProjectRoot $root -Confirm:$false
        $r.Changed | Should -BeTrue
        ($r.Applied | ForEach-Object Code) | Should -Contain 'PYPROJECT_DUPLICATE_DEPENDENCY'

        Clear-PyProjectHealthCache
        $meta = (Get-PyProjectHealthReport -ProjectRoot $root).Metadata
        $meta.RuntimeDependencies -join '|' | Should -Be 'requests>=2.31|rich'
    }

    It 'migrates [tool.uv].dev-dependencies to [dependency-groups].dev' {
        $root = New-HealProject -Name 'legacy' -Toml $script:LegacyToml
        $r = Invoke-PyProjectHealing -ProjectRoot $root -Confirm:$false
        ($r.Applied | ForEach-Object Code) | Should -Contain 'PYPROJECT_LEGACY_UV_DEV_DEPENDENCIES'

        $text = Get-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Raw
        $text | Should -Match '\[dependency-groups\]'
        $text | Should -Not -Match 'dev-dependencies'

        Clear-PyProjectHealthCache
        (Get-PyProjectHealthReport -ProjectRoot $root).Metadata.DevDependencies -join '|' | Should -Be 'pytest|ruff'
    }

    It 'leaves NeedsDecision findings alone and reports them as skipped' {
        $root = New-HealProject -Name 'needsdecision' -Toml @'
[project]
name = "x"
version = "1.2.3"
requires-python = ">=3.11"

[tool.poetry]
name = "x"
version = "9.9.9"
'@ -Locks @('poetry.lock')
        $r = Invoke-PyProjectHealing -ProjectRoot $root -Confirm:$false
        $r.Changed | Should -BeFalse
        ($r.Skipped | ForEach-Object Code) | Should -Contain 'PYPROJECT_METADATA_DIVERGED'

        # The file must be byte-identical.
        $text = Get-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Raw
        $text | Should -Match '9\.9\.9'
    }

    It 'does nothing and creates no backup for a healthy project' {
        $root = New-HealProject -Name 'healthy' -Toml @'
[project]
name = "x"
version = "1.0.0"
requires-python = ">=3.11"
dependencies = ["rich"]

[tool.uv]
package = true
'@
        $before = Get-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Raw
        $r = Invoke-PyProjectHealing -ProjectRoot $root -Confirm:$false
        $r.Changed | Should -BeFalse
        $r.BackupPath | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Raw) | Should -Be $before
    }
}

Describe 'Invoke-PyProjectHealing - transaction guarantees' {
    It 'writes a backup before changing anything' {
        $root = New-HealProject -Name 'backup' -Toml $script:DupToml
        $original = Get-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Raw
        $r = Invoke-PyProjectHealing -ProjectRoot $root -Confirm:$false
        $r.BackupPath | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $r.BackupPath | Should -BeTrue
        (Get-Content -LiteralPath $r.BackupPath -Raw) | Should -Be $original
    }

    It 'records the before and after hashes' {
        $root = New-HealProject -Name 'hashes' -Toml $script:DupToml
        $r = Invoke-PyProjectHealing -ProjectRoot $root -Confirm:$false
        $r.OriginalSha256 | Should -Match '^[0-9a-f]{64}$'
        $r.NewSha256 | Should -Match '^[0-9a-f]{64}$'
        $r.OriginalSha256 | Should -Not -Be $r.NewSha256
    }

    It 'produces a diff describing the change' {
        $root = New-HealProject -Name 'diff' -Toml $script:DupToml
        $r = Invoke-PyProjectHealing -ProjectRoot $root -Confirm:$false
        $r.Diff.Count | Should -BeGreaterThan 0
        ($r.Diff -join "`n") | Should -Match 'requests'
    }

    It 'leaves the result parseable' {
        $root = New-HealProject -Name 'parseable' -Toml $script:DupToml
        Invoke-PyProjectHealing -ProjectRoot $root -Confirm:$false | Out-Null
        { ConvertFrom-TomlFile -Path (Join-Path $root 'pyproject.toml') } | Should -Not -Throw
    }

    It 'changes nothing under -WhatIf' {
        $root = New-HealProject -Name 'whatif' -Toml $script:DupToml
        $before = Get-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Raw
        $r = Invoke-PyProjectHealing -ProjectRoot $root -WhatIf
        $r.Changed | Should -BeFalse
        $r.BackupPath | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Raw) | Should -Be $before
    }

    It 'rolls back and throws PYPROJECT_HEAL_FAILED when validation fails' {
        $root = New-HealProject -Name 'rollback' -Toml $script:DupToml
        $before = Get-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Raw

        # Simulate a corrupt intermediate document.
        Mock -ModuleName PyProjectHealth ConvertFrom-TomlFile { throw 'simulated validation failure' }

        $err = $null
        try { Invoke-PyProjectHealing -ProjectRoot $root -Confirm:$false } catch { $err = $_.Exception }

        $err | Should -Not -BeNullOrEmpty
        $err.ErrorCode | Should -Be 'PYPROJECT_HEAL_FAILED'
        (Get-Content -LiteralPath (Join-Path $root 'pyproject.toml') -Raw) | Should -Be $before
    }

    It 'leaves no temp files behind after a rollback' {
        $root = New-HealProject -Name 'rollback-temp' -Toml $script:DupToml
        Mock -ModuleName PyProjectHealth ConvertFrom-TomlFile { throw 'simulated validation failure' }
        try { Invoke-PyProjectHealing -ProjectRoot $root -Confirm:$false } catch { }
        @(Get-ChildItem -LiteralPath $root -Filter '.pyproject.toml.devsetup-*.tmp' -Force).Count | Should -Be 0
    }

    It 'invalidates the health cache after healing' {
        $root = New-HealProject -Name 'cacheinvalidate' -Toml $script:DupToml
        (Get-PyProjectHealthReport -ProjectRoot $root).Findings.Count | Should -BeGreaterThan 0
        Invoke-PyProjectHealing -ProjectRoot $root -Confirm:$false | Out-Null
        # Without cache invalidation this would still report the duplicate.
        (Get-PyProjectHealthReport -ProjectRoot $root).Findings |
            Where-Object Code -eq 'PYPROJECT_DUPLICATE_DEPENDENCY' | Should -BeNullOrEmpty
    }

    It 'never touches lock files' {
        $root = New-HealProject -Name 'nolocktouch' -Toml $script:DupToml
        $lockBefore = Get-Content -LiteralPath (Join-Path $root 'uv.lock') -Raw
        Invoke-PyProjectHealing -ProjectRoot $root -Confirm:$false | Out-Null
        (Get-Content -LiteralPath (Join-Path $root 'uv.lock') -Raw) | Should -Be $lockBefore
    }
}

Describe 'Format-TomlArrayAssignment' {
    It 'renders a single-line array' {
        (Format-TomlArrayAssignment -KeyText 'deps' -Items @('a', 'b')) -join "`n" |
            Should -Be 'deps = ["a", "b"]'
    }

    It 'renders a multi-line array with indentation' {
        $lines = Format-TomlArrayAssignment -KeyText 'dev' -Items @('a', 'b') -MultiLine
        $lines[0] | Should -Be 'dev = ['
        $lines[1] | Should -Be '    "a",'
        $lines[-1] | Should -Be ']'
    }

    It 'renders an empty array' {
        (Format-TomlArrayAssignment -KeyText 'deps' -Items @()) -join '' | Should -Be 'deps = []'
    }
}

Describe 'Get-TextSha256 and Get-TextDiff' {
    It 'hashes deterministically' {
        Get-TextSha256 -Text 'abc' | Should -Be (Get-TextSha256 -Text 'abc')
        Get-TextSha256 -Text 'abc' | Should -Not -Be (Get-TextSha256 -Text 'abd')
    }

    It 'reports added and removed lines' {
        $d = Get-TextDiff -Before "a`nb`n" -After "a`nc`n"
        ($d -join ' ') | Should -Match '- b'
        ($d -join ' ') | Should -Match '\+ c'
    }
}
