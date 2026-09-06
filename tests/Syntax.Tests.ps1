#Requires -Version 5.1
BeforeAll { $repoRoot = Split-Path -Parent $PSScriptRoot }

Describe 'PowerShell source syntax' {
    $files = @(
        Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
            Where-Object { $_.Extension -in @('.ps1','.psm1','.psd1') -and $_.FullName -notmatch '[\\/]artifacts[\\/]' }
    )

    It 'parses <FullName> without syntax errors' -ForEach $files {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($FullName, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
}
