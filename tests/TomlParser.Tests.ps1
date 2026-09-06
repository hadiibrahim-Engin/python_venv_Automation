#Requires -Version 5.1
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modules = Join-Path $repoRoot 'scripts4PythonAutomation/SetupCore/modules'
    Import-Module (Join-Path $modules 'Errors.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $modules 'TomlParser.psm1') -Force -DisableNameChecking -Global

    function Get-ParseErrorCode {
        param([string] $Text)
        try { ConvertFrom-TomlText -Text $Text | Out-Null; return '<no-throw>' }
        catch {
            if ($_.Exception.PSObject.Properties.Name -contains 'ErrorCode') { return $_.Exception.ErrorCode }
            return $_.Exception.GetType().Name
        }
    }
}
AfterAll { Remove-Module TomlParser -Force -ErrorAction SilentlyContinue }

Describe 'ConvertFrom-TomlText - scalars' {
    It 'reads basic and literal strings' {
        $r = ConvertFrom-TomlText -Text "[a]`nb = `"x`"`nc = 'y'`n"
        Get-TomlPathValue -Data $r.Data -Path 'a.b' | Should -Be 'x'
        Get-TomlPathValue -Data $r.Data -Path 'a.c' | Should -Be 'y'
    }

    It 'reads booleans, integers and floats' {
        $r = ConvertFrom-TomlText -Text "[a]`nt = true`nf = false`ni = 42`nu = 1_000`nd = 1.5`n"
        Get-TomlPathValue -Data $r.Data -Path 'a.t' | Should -BeTrue
        Get-TomlPathValue -Data $r.Data -Path 'a.f' | Should -BeFalse
        Get-TomlPathValue -Data $r.Data -Path 'a.i' | Should -Be 42
        Get-TomlPathValue -Data $r.Data -Path 'a.u' | Should -Be 1000
        Get-TomlPathValue -Data $r.Data -Path 'a.d' | Should -Be 1.5
    }

    It 'ignores a trailing comment on a value line' {
        $r = ConvertFrom-TomlText -Text "[a]`nb = `"x`"   # note`n"
        Get-TomlPathValue -Data $r.Data -Path 'a.b' | Should -Be 'x'
    }

    It 'keeps a # that is inside a string' {
        $r = ConvertFrom-TomlText -Text "[a]`nb = `"c#d`"`n"
        Get-TomlPathValue -Data $r.Data -Path 'a.b' | Should -Be 'c#d'
    }
}

Describe 'ConvertFrom-TomlText - structures' {
    It 'reads a single-line array' {
        $r = ConvertFrom-TomlText -Text "[a]`nb = [`"x`", `"y`"]`n"
        (Get-TomlPathValue -Data $r.Data -Path 'a.b') -join ',' | Should -Be 'x,y'
    }

    It 'reads a multi-line array with comments and a trailing comma' {
        $text = "[project]`ndependencies = [`n  `"requests>=2.31`",   # http`n  `"rich`",`n]`n"
        $r = ConvertFrom-TomlText -Text $text
        (Get-TomlPathValue -Data $r.Data -Path 'project.dependencies') -join '|' | Should -Be 'requests>=2.31|rich'
    }

    It 'returns an empty array as an array, not as $null' {
        $r = ConvertFrom-TomlText -Text "[a]`nb = []`n"
        $v = Get-TomlPathValue -Data $r.Data -Path 'a.b'
        $v -is [System.Array] | Should -BeTrue
        @($v).Count | Should -Be 0
    }

    It 'reads an inline table' {
        $r = ConvertFrom-TomlText -Text "[tool.uv.sources]`nlib = { git = `"https://x.invalid/a.git`", rev = `"main`" }`n"
        (Get-TomlPathValue -Data $r.Data -Path 'tool.uv.sources.lib').git | Should -Be 'https://x.invalid/a.git'
        (Get-TomlPathValue -Data $r.Data -Path 'tool.uv.sources.lib').rev | Should -Be 'main'
    }

    It 'reads nested tables via dotted headers' {
        $r = ConvertFrom-TomlText -Text "[tool.poetry.group.dev.dependencies]`npytest = `"^8`"`n"
        Get-TomlPathValue -Data $r.Data -Path 'tool.poetry.group.dev.dependencies.pytest' | Should -Be '^8'
    }

    It 'reads an array of tables' {
        $r = ConvertFrom-TomlText -Text "[[x.items]]`nn = `"one`"`n`n[[x.items]]`nn = `"two`"`n"
        $items = Get-TomlPathValue -Data $r.Data -Path 'x.items'
        $items.Count | Should -Be 2
        ($items | ForEach-Object { $_.n }) -join ',' | Should -Be 'one,two'
    }

    It 'reads dotted keys inside a table' {
        $r = ConvertFrom-TomlText -Text "[a]`nb.c = `"x`"`n"
        Get-TomlPathValue -Data $r.Data -Path 'a.b.c' | Should -Be 'x'
    }

    It 'reads a quoted key' {
        $r = ConvertFrom-TomlText -Text "[a]`n`"my key`" = 1`n"
        Get-TomlPathValue -Data $r.Data -Path 'a.my key' | Should -Be 1
    }
}

Describe 'ConvertFrom-TomlText - locations' {
    It 'records the line number of each key' {
        $r = ConvertFrom-TomlText -Text "[project]`nname = `"d`"`nversion = `"1.0.0`"`n"
        $r.Locations['project.name'] | Should -Be 2
        $r.Locations['project.version'] | Should -Be 3
    }

    It 'records the full span of a multi-line value' {
        $r = ConvertFrom-TomlText -Text "[project]`ndeps = [`n  `"a`",`n  `"b`",`n]`nx = 1`n"
        $r.Locations['project.deps'] | Should -Be 2
        $r.EndLocations['project.deps'] | Should -Be 5
        $r.Locations['project.x'] | Should -Be 6
    }

    It 'records table header lines' {
        $r = ConvertFrom-TomlText -Text "[a]`nx = 1`n`n[b]`ny = 2`n"
        $r.Tables['a'] | Should -Be 1
        $r.Tables['b'] | Should -Be 4
    }
}

Describe 'ConvertFrom-TomlText - fail closed' {
    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a line that is neither header nor assignment'; Text = "[a]`njust text`n" }
        @{ Case = 'an unterminated array';                        Text = "[a]`nb = [`"x`"`n" }
        @{ Case = 'an unterminated string';                       Text = "[a]`nb = `"x`n" }
        @{ Case = 'a duplicate table header';                     Text = "[a]`nx = 1`n`n[a]`ny = 2`n" }
        @{ Case = 'a value type it does not understand';          Text = "[a]`nb = 2024-01-01`n" }
        @{ Case = 'a missing value';                              Text = "[a]`nb =`n" }
        @{ Case = 'an empty key segment';                         Text = "[a]`nb..c = 1`n" }
    ) {
        Get-ParseErrorCode -Text $Text | Should -Be 'TOML_PARSE_ERROR'
    }

    It 'accepts an empty document' {
        $r = ConvertFrom-TomlText -Text ''
        $r.Data.Keys.Count | Should -Be 0
    }

    It 'accepts a comment-only document' {
        $r = ConvertFrom-TomlText -Text "# nothing here`n# really`n"
        $r.Data.Keys.Count | Should -Be 0
    }
}

Describe 'ConvertFrom-TomlFile' {
    It 'parses a file from disk' {
        $p = Join-Path $TestDrive 'pyproject.toml'
        Set-Content -LiteralPath $p -Value "[project]`nname = `"fromfile`"`n" -Encoding UTF8
        $r = ConvertFrom-TomlFile -Path $p
        Get-TomlPathValue -Data $r.Data -Path 'project.name' | Should -Be 'fromfile'
    }

    It 'throws TOML_FILE_NOT_FOUND for a missing file' {
        $err = $null
        try { ConvertFrom-TomlFile -Path (Join-Path $TestDrive 'nope.toml') } catch { $err = $_.Exception }
        $err.ErrorCode | Should -Be 'TOML_FILE_NOT_FOUND'
    }
}
