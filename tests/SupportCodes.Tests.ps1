#Requires -Version 5.1
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modules = Join-Path $repoRoot 'scripts4PythonAutomation/SetupCore/modules'
    Import-Module (Join-Path $modules 'SupportCodes.psm1') -Force -DisableNameChecking -Global
}
AfterAll { Remove-Module SupportCodes -Force -ErrorAction SilentlyContinue }

Describe 'Get-DevSetupSupportCode' {
    It 'maps <ErrorCode> to <Expected>' -ForEach @(
        @{ ErrorCode = 'PYPROJECT_PM_AMBIGUOUS';        Expected = 'DS-P204' }
        @{ ErrorCode = 'PYTHON_CONSTRAINT_UNSUPPORTED'; Expected = 'DS-P202' }
        @{ ErrorCode = 'TOML_PARSE_ERROR';              Expected = 'DS-P201' }
        @{ ErrorCode = 'CONFIG_INVALID';                Expected = 'DS-P201' }
        @{ ErrorCode = 'PYPROJECT_HEAL_FAILED';         Expected = 'DS-P206' }
        @{ ErrorCode = 'VENV_INVALID';                  Expected = 'DS-V302' }
        @{ ErrorCode = 'DIGICERT_NOT_FOUND';            Expected = 'DS-S402' }
    ) {
        Get-DevSetupSupportCode -ErrorCode $ErrorCode | Should -Be $Expected
    }

    It 'falls back to DS-X901 for an unknown code' {
        Get-DevSetupSupportCode -ErrorCode 'SOMETHING_BRAND_NEW' | Should -Be 'DS-X901'
    }

    It 'falls back to DS-X901 for empty input' {
        Get-DevSetupSupportCode -ErrorCode '' | Should -Be 'DS-X901'
    }
}

Describe 'Get-DevSetupSupportCodeTable' {
    It 'returns every code with a title and a detail' {
        $table = Get-DevSetupSupportCodeTable
        $table.Count | Should -BeGreaterThan 10
        foreach ($row in $table) {
            $row.Code | Should -Match '^DS-[A-Z]\d{3}$'
            $row.Title | Should -Not -BeNullOrEmpty
            $row.Detail | Should -Not -BeNullOrEmpty
        }
    }

    It 'every mapped error code resolves to a documented support code' {
        $known = (Get-DevSetupSupportCodeTable).Code
        foreach ($e in @('PYPROJECT_PM_AMBIGUOUS', 'VENV_INVALID', 'GIT_SYNC_FAILED', 'SIGNING_FAILED')) {
            $known | Should -Contain (Get-DevSetupSupportCode -ErrorCode $e)
        }
    }
}

Describe 'Format-DevSetupUserError' {
    It 'shows the code and the support hint' {
        $text = Format-DevSetupUserError -ErrorCode 'PYPROJECT_PM_AMBIGUOUS'
        $text | Should -Match 'DS-P204'
        $text | Should -Match 'devsetup support'
    }

    It 'uses the configured command name in the hint' {
        Format-DevSetupUserError -ErrorCode 'VENV_INVALID' -CommandName 'projsetup' |
            Should -Match 'projsetup support'
    }

    It 'never leaks technical detail to the user' {
        $text = Format-DevSetupUserError -ErrorCode 'TOML_PARSE_ERROR'
        $text | Should -Not -Match 'Exception'
        $text | Should -Not -Match 'psm1'
        $text | Should -Not -Match 'at line'
    }
}
