#Requires -Version 5.1
BeforeAll { $repoRoot = Split-Path -Parent $PSScriptRoot }

Describe 'PowerShell source syntax' {
    $cases = @(
        Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
            Where-Object { $_.Extension -in @('.ps1','.psm1','.psd1') -and $_.FullName -notmatch '[\\/]artifacts[\\/]' } |
            ForEach-Object { @{ Path = $_.FullName } }
    )

    It 'parses <Path> without syntax errors' -ForEach $cases {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
}
