#Requires -Version 5.1
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modules = Join-Path $repoRoot 'scripts4PythonAutomation/SetupCore/modules'
    Import-Module (Join-Path $modules 'Errors.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $modules 'Versioning.psm1') -Force -DisableNameChecking -Global

    function Get-Ops {
        param([string] $Constraint)
        # Assign first: the function returns ,$list, so piping it straight into
        # ForEach-Object yields the List itself and member-enumerates .Op.
        $parsed = ConvertTo-VersionConstraints -ConstraintStr $Constraint
        ($parsed | ForEach-Object { '{0}{1}' -f $_.Op, $_.Version }) -join ' '
    }

    function Get-ThrownCode {
        param([scriptblock] $Action)
        try { & $Action | Out-Null; return '<no-throw>' }
        catch {
            if ($_.Exception.PSObject.Properties.Name -contains 'ErrorCode') { return $_.Exception.ErrorCode }
            return $_.Exception.GetType().Name
        }
    }
}
AfterAll { Remove-Module Versioning -Force -ErrorAction SilentlyContinue }

Describe 'ConvertTo-VersionConstraints - supported syntax' {
    It 'parses <Constraint> as <Expected>' -ForEach @(
        @{ Constraint = '>=3.11,<3.13'; Expected = '>=3.11 <3.13' }
        @{ Constraint = '>=3.11';       Expected = '>=3.11' }
        @{ Constraint = '<=3.12';       Expected = '<=3.12' }
        @{ Constraint = '==3.11';       Expected = '>=3.11 <3.12' }
        @{ Constraint = '==3.11.4';     Expected = '==3.11.4' }
        @{ Constraint = '==3.11.*';     Expected = '>=3.11 <3.12' }
        @{ Constraint = '^3.11';        Expected = '>=3.11 <4.0' }
        @{ Constraint = '^0.5';         Expected = '>=0.5 <0.6' }
        @{ Constraint = '~3.11';        Expected = '>=3.11 <3.12' }
        @{ Constraint = '~=3.11';       Expected = '>=3.11 <4.0' }
        @{ Constraint = '~=3.11.4';     Expected = '>=3.11.4 <3.12' }
        @{ Constraint = '!=3.12';       Expected = '!=line3.12' }
        @{ Constraint = '!=3.12.1';     Expected = '!=3.12.1' }
        @{ Constraint = '3.11';         Expected = '>=3.11 <3.12' }
    ) {
        Get-Ops -Constraint $Constraint | Should -Be $Expected
    }

    It 'tolerates surrounding whitespace' {
        Get-Ops -Constraint ' >=3.11 , <3.13 ' | Should -Be '>=3.11 <3.13'
    }
}

Describe 'ConvertTo-VersionConstraints - fail closed' {
    It 'throws PYTHON_CONSTRAINT_UNSUPPORTED for <Constraint>' -ForEach @(
        @{ Constraint = '   ' }
        @{ Constraint = '~=3' }
        @{ Constraint = '>=abc' }
        @{ Constraint = 'foo' }
        @{ Constraint = '>=3' }
        @{ Constraint = '3.11.*.*' }
        @{ Constraint = '>=3.11 <3.13' }      # missing comma
        @{ Constraint = '>=3.11,,<3.13' }     # stray comma
        @{ Constraint = '>=3.11,' }
        @{ Constraint = '>=3.11;<3.13' }
        @{ Constraint = '===3.11' }
        @{ Constraint = '>=3.11.x' }
    ) {
        Get-ThrownCode -Action { ConvertTo-VersionConstraints -ConstraintStr $Constraint } |
            Should -Be 'PYTHON_CONSTRAINT_UNSUPPORTED'
    }

    It 'never silently drops a token it does not understand' {
        # The old implementation warned and skipped, weakening the requirement
        # to just ">=3.11". Fail-closed means the whole string is rejected.
        Get-ThrownCode -Action { ConvertTo-VersionConstraints -ConstraintStr '>=3.11,@@@' } |
            Should -Be 'PYTHON_CONSTRAINT_UNSUPPORTED'
    }
}

Describe 'Test-VersionConstraints' {
    It 'range 3.11-3.13 accepts <Version> is <Expected>' -ForEach @(
        @{ Version = '3.10.9'; Expected = $false }
        @{ Version = '3.11.0'; Expected = $true }
        @{ Version = '3.12.8'; Expected = $true }
        @{ Version = '3.13.0'; Expected = $false }
    ) {
        $c = ConvertTo-VersionConstraints -ConstraintStr '>=3.11,<3.13'
        Test-VersionConstraints -Version ([Version]$Version) -Constraints $c | Should -Be $Expected
    }

    It 'excludes the entire 3.12 line for !=3.12, not just 3.12.0' {
        $c = ConvertTo-VersionConstraints -ConstraintStr '>=3.11,!=3.12'
        Test-VersionConstraints -Version ([Version]'3.11.9') -Constraints $c | Should -BeTrue
        Test-VersionConstraints -Version ([Version]'3.12.0') -Constraints $c | Should -BeFalse
        Test-VersionConstraints -Version ([Version]'3.12.5') -Constraints $c | Should -BeFalse
        Test-VersionConstraints -Version ([Version]'3.13.1') -Constraints $c | Should -BeTrue
    }

    It 'throws on an unknown operator instead of silently passing' {
        $bad = [System.Collections.Generic.List[hashtable]]::new()
        $bad.Add(@{ Op = '<<>>'; Version = [Version]'3.11' })
        Get-ThrownCode -Action { Test-VersionConstraints -Version ([Version]'3.11') -Constraints $bad } |
            Should -Be 'PYTHON_CONSTRAINT_UNSUPPORTED'
    }
}
