#Requires -Version 5.1
# Command-name configuration tests: default value, shim names, help text, and
# that a rename propagates to all generated outputs.

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:ModuleName = 'PythonVenvAutomation'
    $script:Manifest   = Join-Path $RepoRoot "$ModuleName\$ModuleName.psd1"
    Import-Module $Manifest -Force
}

AfterAll {
    Remove-Module PythonVenvAutomation -Force -ErrorAction SilentlyContinue
}

Describe 'Get-DevSetupCommandName' {
    It "returns 'devsetup' by default" {
        InModuleScope PythonVenvAutomation { Get-DevSetupCommandName } | Should -Be 'devsetup'
    }
}

Describe 'Generated shim names derive from the command name' {
    BeforeEach {
        $script:BinDir = Join-Path ([System.IO.Path]::GetTempPath()) ("shim-name-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $BinDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'uses devsetup.ps1 and devsetup.cmd for the default name' {
        $r = InModuleScope PythonVenvAutomation -Parameters @{ Bin = $BinDir } {
            param($Bin) New-DevSetupShim -BinDirectory $Bin -Force
        }
        (Split-Path $r.PsShimPath -Leaf)  | Should -Be 'devsetup.ps1'
        (Split-Path $r.CmdShimPath -Leaf) | Should -Be 'devsetup.cmd'
        Test-Path $r.PsShimPath  | Should -BeTrue
        Test-Path $r.CmdShimPath | Should -BeTrue
    }

    It 'changes shim names when the command name changes' {
        $r = InModuleScope PythonVenvAutomation -Parameters @{ Bin = $BinDir } {
            param($Bin) New-DevSetupShim -BinDirectory $Bin -CommandName 'envctl' -Force
        }
        (Split-Path $r.PsShimPath -Leaf)  | Should -Be 'envctl.ps1'
        (Split-Path $r.CmdShimPath -Leaf) | Should -Be 'envctl.cmd'
    }

    It 'bakes the command name into the generated .cmd and .ps1 content' {
        $r = InModuleScope PythonVenvAutomation -Parameters @{ Bin = $BinDir } {
            param($Bin) New-DevSetupShim -BinDirectory $Bin -CommandName 'envctl' -Force
        }
        (Get-Content $r.CmdShimPath -Raw) | Should -Match 'envctl\.ps1'
        (Get-Content $r.PsShimPath -Raw)  | Should -Match "CommandName = 'envctl'"
        (Get-Content $r.CmdShimPath -Raw) | Should -Not -Match '__COMMAND_NAME__'
    }
}

Describe 'Help text uses the configured command name' {
    It 'renders the default name' {
        $help = InModuleScope PythonVenvAutomation { Write-DevSetupHelp }
        $help | Should -Match 'devsetup - Python project environment setup automation'
        $help | Should -Match 'devsetup self-update'
    }

    It 'renders a renamed command everywhere in the help' {
        $help = InModuleScope PythonVenvAutomation { Write-DevSetupHelp -CommandName 'envctl' }
        $help | Should -Match 'envctl - Python project environment setup automation'
        $help | Should -Not -Match '(^|\s)devsetup(\s|$)'
    }
}

Describe 'Installer output uses the configured command name' {
    It 'prints the renamed command in the success message' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("install-name-" + [guid]::NewGuid().ToString('N'))
        $env:LOCALAPPDATA = $tmp
        try {
            $out = InModuleScope PythonVenvAutomation {
                $Script:DevSetupCommandName = 'envctl'
                Install-DevSetupCommand -Force 6>&1
            }
            ($out -join "`n") | Should -Match 'envctl'
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            InModuleScope PythonVenvAutomation { $Script:DevSetupCommandName = 'devsetup' }
        }
    }
}
