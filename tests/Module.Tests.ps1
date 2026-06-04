#Requires -Version 5.1
# Module manifest / import / public-surface tests.

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:ModuleName = 'PythonVenvAutomation'
    $script:Manifest   = Join-Path $RepoRoot "$ModuleName\$ModuleName.psd1"
    Import-Module $Manifest -Force
}

AfterAll {
    Remove-Module PythonVenvAutomation -Force -ErrorAction SilentlyContinue
}

Describe 'Module manifest and import' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $Manifest } | Should -Not -Throw
    }

    It 'declares ModuleVersion equal to the VERSION file' {
        $manifestVersion = (Import-PowerShellDataFile -LiteralPath $Manifest).ModuleVersion
        $fileVersion = (Get-Content -LiteralPath (Join-Path $RepoRoot 'VERSION') -Raw).Trim()
        "$manifestVersion" | Should -Be $fileVersion
    }

    It 'imports successfully from an arbitrary working directory' {
        Push-Location ([System.IO.Path]::GetTempPath())
        try {
            { Import-Module $Manifest -Force } | Should -Not -Throw
        } finally { Pop-Location }
    }
}

Describe 'Public command surface' {
    It 'exports <_>' -ForEach @('Invoke-PythonVenvSetup', 'Install-DevSetupCommand', 'Update-PythonVenvAutomation', 'Get-PythonVenvSetupInfo') {
        Get-Command $_ -Module $ModuleName -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'does not export private helper <_>' -ForEach @('Get-DevSetupCommandName', 'New-DevSetupShim', 'Get-DevSetupRuntimeConfig', 'Test-PythonVenvAutomationVersion', 'Update-PythonVenvAutomationIfNeeded') {
        Get-Command $_ -Module $ModuleName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'exports exactly four public functions' {
        (Get-Command -Module $ModuleName -CommandType Function).Count | Should -Be 4
    }
}

Describe 'Backward-compatible setup-core.ps1 wrapper' {
    It 'parses without syntax errors' {
        $path = Join-Path $RepoRoot 'scripts4PythonAutomation\setup-core.ps1'
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It 'still accepts the legacy parameter surface' {
        $path = Join-Path $RepoRoot 'scripts4PythonAutomation\setup-core.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $paramNames = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        foreach ($p in @('DryRun', 'Mode', 'ForceRecreateVenv', 'PackageManager', 'ListMode', 'UpdateDependencies')) {
            $paramNames | Should -Contain $p
        }
    }

    It 'routes through Invoke-PythonVenvSetup' {
        $text = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts4PythonAutomation\setup-core.ps1') -Raw
        $text | Should -Match 'Invoke-PythonVenvSetup'
        $text | Should -Match 'Import-Module PythonVenvAutomation'
    }
}
