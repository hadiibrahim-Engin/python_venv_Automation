#Requires -Version 5.1

BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\GitSync.psm1'
    Import-Module $modulePath -Force
}

AfterAll { Remove-Module GitSync -Force -ErrorAction SilentlyContinue }

Describe 'Invoke-SafeGitPull' {
    InModuleScope GitSync {
        BeforeEach {
            Mock Test-Path { $true }
            Mock Resolve-Path { [pscustomobject]@{ Path = 'C:\repo' } }
            Mock Get-Command { [pscustomobject]@{ Source = 'git.exe' } } -ParameterFilter { $Name -eq 'git' }
        }

        It 'skips a dirty repository that is behind by default' {
            Mock Invoke-GitProcess {
                param($RepositoryPath, $Arguments)
                $cmd = $Arguments -join ' '
                switch -Regex ($cmd) {
                    'rev-parse --show-toplevel' { [pscustomobject]@{Succeeded=$true;StdOut='C:\repo';StdErr='';ExitCode=0} }
                    'rev-parse --abbrev-ref HEAD' { [pscustomobject]@{Succeeded=$true;StdOut='main';StdErr='';ExitCode=0} }
                    'fetch --prune' { [pscustomobject]@{Succeeded=$true;StdOut='';StdErr='';ExitCode=0} }
                    'symbolic-full-name' { [pscustomobject]@{Succeeded=$true;StdOut='origin/main';StdErr='';ExitCode=0} }
                    'status --porcelain' { [pscustomobject]@{Succeeded=$true;StdOut=' M pyproject.toml';StdErr='';ExitCode=0} }
                    'rev-list --left-right --count' { [pscustomobject]@{Succeeded=$true;StdOut="0`t2";StdErr='';ExitCode=0} }
                }
            }
            $result = Invoke-SafeGitPull -RepositoryPath 'C:\repo' -Confirm:$false
            $result.Status | Should -Be 'SkippedDirty'
            $result.Changed | Should -BeFalse
        }

        It 'fast-forwards a clean repository that is only behind' {
            Mock Invoke-GitProcess {
                param($RepositoryPath, $Arguments)
                $cmd = $Arguments -join ' '
                switch -Regex ($cmd) {
                    'rev-parse --show-toplevel' { [pscustomobject]@{Succeeded=$true;StdOut='C:\repo';StdErr='';ExitCode=0} }
                    'rev-parse --abbrev-ref HEAD' { [pscustomobject]@{Succeeded=$true;StdOut='main';StdErr='';ExitCode=0} }
                    'symbolic-full-name' { [pscustomobject]@{Succeeded=$true;StdOut='origin/main';StdErr='';ExitCode=0} }
                    'status --porcelain' { [pscustomobject]@{Succeeded=$true;StdOut='';StdErr='';ExitCode=0} }
                    'rev-list --left-right --count' { [pscustomobject]@{Succeeded=$true;StdOut="0`t1";StdErr='';ExitCode=0} }
                    default { [pscustomobject]@{Succeeded=$true;StdOut='';StdErr='';ExitCode=0} }
                }
            }
            $result = Invoke-SafeGitPull -RepositoryPath 'C:\repo' -Confirm:$false
            $result.Status | Should -Be 'FastForwarded'
            $result.Changed | Should -BeTrue
        }

        It 'never force-resets unless Force is explicitly supplied' {
            Mock Invoke-GitProcess {
                param($RepositoryPath, $Arguments)
                $cmd = $Arguments -join ' '
                switch -Regex ($cmd) {
                    'rev-parse --show-toplevel' { [pscustomobject]@{Succeeded=$true;StdOut='C:\repo';StdErr='';ExitCode=0} }
                    'rev-parse --abbrev-ref HEAD' { [pscustomobject]@{Succeeded=$true;StdOut='main';StdErr='';ExitCode=0} }
                    'symbolic-full-name' { [pscustomobject]@{Succeeded=$true;StdOut='origin/main';StdErr='';ExitCode=0} }
                    'status --porcelain' { [pscustomobject]@{Succeeded=$true;StdOut='';StdErr='';ExitCode=0} }
                    'rev-list --left-right --count' { [pscustomobject]@{Succeeded=$true;StdOut="1`t1";StdErr='';ExitCode=0} }
                    default { [pscustomobject]@{Succeeded=$true;StdOut='';StdErr='';ExitCode=0} }
                }
            }
            $result = Invoke-SafeGitPull -RepositoryPath 'C:\repo' -Confirm:$false
            $result.Status | Should -Be 'Diverged'
            Should -Invoke Invoke-GitProcess -ParameterFilter { ($Arguments -join ' ') -match '^reset --hard' } -Times 0
        }
    }
}
