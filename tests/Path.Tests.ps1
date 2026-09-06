#Requires -Version 5.1
# PATH idempotency + install/overwrite tests.

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:ModuleName = 'PythonVenvAutomation'
    $script:Manifest   = Join-Path $RepoRoot "$ModuleName\$ModuleName.psd1"
    Import-Module $Manifest -Force
}

AfterAll {
    Remove-Module PythonVenvAutomation -Force -ErrorAction SilentlyContinue
}

Describe 'Install-DevSetupCommand idempotency' {
    BeforeEach {
        $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("path-test-" + [guid]::NewGuid().ToString('N'))
        $env:LOCALAPPDATA = $Tmp
        $script:OrigPath = $env:Path
    }
    AfterEach {
        $env:Path = $script:OrigPath
        Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'adds the bin directory to the process PATH exactly once across repeated installs' {
        $r1 = Install-DevSetupCommand -Force 6>$null
        $bin = $r1.BinDirectory
        Install-DevSetupCommand -Force 6>$null | Out-Null
        Install-DevSetupCommand -Force 6>$null | Out-Null

        $sep = [System.IO.Path]::PathSeparator
        $occurrences = @($env:Path -split [regex]::Escape($sep) | Where-Object { $_.TrimEnd('\','/') -ieq $bin.TrimEnd('\','/') }).Count
        $occurrences | Should -Be 1
    }

    It '-Force overwrites existing shims without error' {
        Install-DevSetupCommand -Force 6>$null | Out-Null
        { Install-DevSetupCommand -Force 6>$null } | Should -Not -Throw
    }

    It 'fails (by default) to clobber existing shims without -Force' {
        Install-DevSetupCommand -Force 6>$null | Out-Null
        $bin = (Get-PythonVenvSetupInfo).BinDirectory
        { InModuleScope PythonVenvAutomation -Parameters @{ Bin = $bin } { param($Bin) New-DevSetupShim -BinDirectory $Bin } } | Should -Throw
    }

    It 'writes the runtime config under the LOCALAPPDATA tree' {
        $r = Install-DevSetupCommand -Force 6>$null
        Test-Path $r.ConfigPath | Should -BeTrue
        (Get-Content $r.ConfigPath -Raw) | Should -Match '"CommandName"\s*:\s*"devsetup"'
    }
}
