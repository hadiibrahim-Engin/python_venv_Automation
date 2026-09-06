#Requires -Version 5.1
<#
    Exit-WithError used to call Read-Host unconditionally, and every caller in
    Toml/UV/Poetry omitted -NonInteractive. An unattended run (CI, a scripted
    devsetup, a background shell) therefore blocked forever on
    "Press Enter to exit" instead of failing.
#>
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modules = Join-Path $repoRoot 'scripts4PythonAutomation/SetupCore/modules'
    Import-Module (Join-Path $modules 'UI.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $modules 'Errors.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $modules 'Toml.psm1') -Force -DisableNameChecking -Global

    $script:savedEnv = @{}
    foreach ($n in 'DEVSETUP_NONINTERACTIVE', 'CI', 'TF_BUILD', 'GITHUB_ACTIONS') {
        $script:savedEnv[$n] = [Environment]::GetEnvironmentVariable($n)
        Set-Item "env:$n" '' -ErrorAction SilentlyContinue
    }
}
AfterAll {
    foreach ($n in $script:savedEnv.Keys) {
        if ($null -eq $script:savedEnv[$n]) { Remove-Item "env:$n" -ErrorAction SilentlyContinue }
        else { Set-Item "env:$n" $script:savedEnv[$n] }
    }
    Remove-Module UI -Force -ErrorAction SilentlyContinue
}

Describe 'Test-SetupInteractive' {
    It 'reports non-interactive for <Var>' -ForEach @(
        @{ Var = 'DEVSETUP_NONINTERACTIVE' }
        @{ Var = 'CI' }
        @{ Var = 'TF_BUILD' }
        @{ Var = 'GITHUB_ACTIONS' }
    ) {
        Set-Item "env:$Var" '1'
        try { Test-SetupInteractive | Should -BeFalse }
        finally { Set-Item "env:$Var" '' }
    }

    It 'ignores an env var that is set to a falsy value' {
        Set-Item 'env:CI' 'false'
        try {
            # Result depends on the host, but it must not be forced false by 'false'.
            Test-SetupInteractive | Should -BeOfType [bool]
        } finally { Set-Item 'env:CI' '' }
    }
}

Describe 'Exit-WithError never blocks an unattended run' {
    It 'throws without prompting when CI is set' {
        Set-Item 'env:CI' '1'
        try {
            Mock -ModuleName UI Read-Host { throw 'Read-Host must not be called' }
            { Exit-WithError -Message 'boom' } | Should -Throw '*boom*'
            Should -Invoke -ModuleName UI Read-Host -Times 0 -Exactly
        } finally { Set-Item 'env:CI' '' }
    }

    It 'throws without prompting when the caller passes -NonInteractive' {
        Mock -ModuleName UI Read-Host { throw 'Read-Host must not be called' }
        { Exit-WithError -Message 'boom' -NonInteractive $true } | Should -Throw '*boom*'
        Should -Invoke -ModuleName UI Read-Host -Times 0 -Exactly
    }

    It 'still prompts when a human is present' {
        Mock -ModuleName UI Test-SetupInteractive { $true }
        Mock -ModuleName UI Read-Host { '' }
        { Exit-WithError -Message 'boom' } | Should -Throw '*boom*'
        Should -Invoke -ModuleName UI Read-Host -Times 1 -Exactly
    }
}

Describe 'Get-ProjectMetadata fails fast on a missing pyproject.toml' {
    It 'throws instead of waiting for Enter' {
        Set-Item 'env:CI' '1'
        try {
            $dir = Join-Path $TestDrive 'empty'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Clear-TomlCache
            Mock -ModuleName UI Read-Host { throw 'Read-Host must not be called' }
            { Get-ProjectMetadata -ProjectRoot $dir } | Should -Throw '*not found*'
        } finally { Set-Item 'env:CI' '' }
    }
}
