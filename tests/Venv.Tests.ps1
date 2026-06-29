#Requires -Version 5.1
# Venv.psm1 lifecycle tests - in particular Resolve-VenvReuseOrRecreate, which
# decides whether an existing .venv can be reused or must be recreated.
# No real Python/uv/poetry is touched; everything operates on $TestDrive.

BeforeAll {
    $script:ModulesRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts4PythonAutomation\SetupCore\modules'
    Import-Module (Join-Path $ModulesRoot 'Venv.psm1')       -Force -DisableNameChecking
    Import-Module (Join-Path $ModulesRoot 'Versioning.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $ModulesRoot 'Compat.psm1')     -Force -DisableNameChecking
}

AfterAll {
    Remove-Module Venv, Versioning, Compat -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-VenvReuseOrRecreate' {

    BeforeEach {
        $script:CaseDir     = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $CaseDir -Force | Out-Null
        $script:VenvDir     = Join-Path $CaseDir '.venv'
        $script:Constraints = ConvertTo-VersionConstraints -ConstraintStr '>=3.8'
        $script:Selected    = [pscustomobject]@{ Version = '3.11.4'; Exe = '/fake/python3.11' }
    }

    It 'backs up and removes .venv when the Python executable is missing, instead of throwing' {
        New-Item -ItemType Directory -Path $VenvDir -Force | Out-Null

        $result = Resolve-VenvReuseOrRecreate `
            -VenvDir               $VenvDir `
            -Constraints           $Constraints `
            -RequiresPythonRaw     '>=3.8' `
            -SelectedPython        $Selected `
            -RequireSelectedPython $false `
            -NonInteractive        $true

        $result | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $VenvDir -PathType Container | Should -BeFalse
        @(Get-ChildItem -Path $CaseDir -Force -Directory -Filter '.venv_backup_*').Count | Should -Be 1
    }

    It 'leaves a fully compatible .venv untouched and returns $null' {
        $venvPython = Get-VenvPythonExe -VenvDir $VenvDir
        New-Item -ItemType Directory -Path $VenvDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $venvPython) -Force | Out-Null
        New-Item -ItemType File      -Path $venvPython -Force | Out-Null

        Mock -CommandName Invoke-NativeCommand -ModuleName Venv -MockWith {
            [pscustomobject]@{ Succeeded = $true; ExitCode = 0; StdOut = "3.11.4`n/fake/python3.11"; StdErr = '' }
        }

        $result = Resolve-VenvReuseOrRecreate `
            -VenvDir               $VenvDir `
            -Constraints           $Constraints `
            -RequiresPythonRaw     '>=3.8' `
            -SelectedPython        $Selected `
            -RequireSelectedPython $false `
            -NonInteractive        $true

        $result | Should -BeNullOrEmpty
        Test-Path -LiteralPath $VenvDir -PathType Container | Should -BeTrue
        @(Get-ChildItem -Path $CaseDir -Force -Directory -Filter '.venv_backup_*').Count | Should -Be 0
    }
}
