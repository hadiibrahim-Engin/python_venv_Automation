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

    It 'does not export private helper <_>' -ForEach @('Get-DevSetupCommandName', 'New-DevSetupShim', 'Get-DevSetupRuntimeConfig', 'Test-PythonVenvAutomationVersion', 'Update-PythonVenvAutomationIfNeeded', 'Assert-DevSetupEngine', 'Get-DevSetupInstallInfo') {
        Get-Command $_ -Module $ModuleName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'exports exactly the documented public surface' {
        # Asserting the set (not just a count) so an accidental export is named.
        $expected = @(
            'Get-DevSetupAbout'
            'Get-PythonVenvSetupInfo'
            'Install-DevSetupCommand'
            'Invoke-DevSetupDoctor'
            'Invoke-DevSetupRepairCommand'
            'Invoke-PythonVenvSetup'
            'New-DevSetupSupport'
            'Update-PythonVenvAutomation'
        )
        $actual = (Get-Command -Module $ModuleName -CommandType Function | ForEach-Object Name) | Sort-Object
        ($actual -join ',') | Should -Be (($expected | Sort-Object) -join ',')
    }

    It 'keeps the manifest FunctionsToExport in sync with the module' {
        $manifest = Import-PowerShellDataFile (Join-Path $RepoRoot 'PythonVenvAutomation/PythonVenvAutomation.psd1')
        $actual = (Get-Command -Module $ModuleName -CommandType Function | ForEach-Object Name) | Sort-Object
        (($manifest.FunctionsToExport | Sort-Object) -join ',') | Should -Be ($actual -join ',')
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

Describe 'Get-DevSetupInstallInfo' {
    It 'derives version and paths from a managed installation layout' {
        $root = Join-Path $TestDrive 'Company/DevSetup'
        $moduleRoot = Join-Path $root 'versions/1.9.0/PythonVenvAutomation'
        New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null

        $info = InModuleScope PythonVenvAutomation -Parameters @{ mr = $moduleRoot } {
            param($mr) Get-DevSetupInstallInfo -ModuleRoot $mr
        }
        $info.IsManaged | Should -BeTrue
        $info.Version | Should -Be '1.9.0'
        $info.InstallRoot | Should -Be $root
        $info.BinDirectory | Should -Be (Join-Path $root 'bin')
        $info.ConfigPath | Should -Be (Join-Path $root 'config.json')
    }

    It 'reports IsManaged false for a source checkout' {
        $info = InModuleScope PythonVenvAutomation -Parameters @{ mr = (Join-Path $TestDrive 'repo/PythonVenvAutomation') } {
            param($mr) Get-DevSetupInstallInfo -ModuleRoot $mr
        }
        $info.IsManaged | Should -BeFalse
        $info.Version | Should -BeNullOrEmpty
    }

    It 'reports IsManaged false when the parent is not named versions' {
        $info = InModuleScope PythonVenvAutomation -Parameters @{ mr = (Join-Path $TestDrive 'x/releases/1.0.0/PythonVenvAutomation') } {
            param($mr) Get-DevSetupInstallInfo -ModuleRoot $mr
        }
        $info.IsManaged | Should -BeFalse
    }
}
