#Requires -Version 5.1
<#
    Part Y: `git reset --hard` discards local commits and leaves them reachable
    only through the reflog, which expires. A real backup ref must exist first.
#>
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modules = Join-Path $repoRoot 'scripts4PythonAutomation/SetupCore/modules'
    Import-Module (Join-Path $modules 'GitSync.psm1') -Force -DisableNameChecking -Global

    function Invoke-TestGit {
        param([string] $Repo, [string[]] $Arguments)
        $all = @('-C', $Repo, '-c', 'user.email=t@t.invalid', '-c', 'user.name=T',
                 '-c', 'commit.gpgsign=false', '-c', 'init.defaultBranch=main') + $Arguments
        $out = & git @all 2>&1
        if ($LASTEXITCODE -ne 0) { throw ("git {0} failed: {1}" -f ($Arguments -join ' '), ($out -join "`n")) }
        return ($out -join "`n")
    }

    function New-TestRepo {
        param([string] $Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Invoke-TestGit -Repo $Path -Arguments @('init', '--initial-branch=main', '--quiet') | Out-Null
        Set-Content -LiteralPath (Join-Path $Path 'a.txt') -Value 'one' -Encoding UTF8
        Invoke-TestGit -Repo $Path -Arguments @('add', '-A') | Out-Null
        Invoke-TestGit -Repo $Path -Arguments @('commit', '-m', 'init', '--quiet') | Out-Null
        return $Path
    }
}
AfterAll { Remove-Module GitSync -Force -ErrorAction SilentlyContinue }

Describe 'New-GitRecoveryRef' {
    It 'creates a ref under refs/devsetup-backup pointing at HEAD' {
        $repo = New-TestRepo (Join-Path $TestDrive 'rec')
        $head = (Invoke-TestGit -Repo $repo -Arguments @('rev-parse', 'HEAD')).Trim()

        $ref = New-GitRecoveryRef -RepositoryRoot $repo
        $ref | Should -Match '^refs/devsetup-backup/\d{8}-\d{6}$'
        (Invoke-TestGit -Repo $repo -Arguments @('rev-parse', $ref)).Trim() | Should -Be $head
    }

    It 'returns $null when HEAD cannot be resolved (empty repository)' {
        $repo = Join-Path $TestDrive 'empty-repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Invoke-TestGit -Repo $repo -Arguments @('init', '--initial-branch=main', '--quiet') | Out-Null
        New-GitRecoveryRef -RepositoryRoot $repo | Should -BeNullOrEmpty
    }

    It 'the recovery ref survives a hard reset and restores the old commit' {
        $repo = New-TestRepo (Join-Path $TestDrive 'restore')
        Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'two' -Encoding UTF8
        Invoke-TestGit -Repo $repo -Arguments @('add', '-A') | Out-Null
        Invoke-TestGit -Repo $repo -Arguments @('commit', '-m', 'second', '--quiet') | Out-Null
        $before = (Invoke-TestGit -Repo $repo -Arguments @('rev-parse', 'HEAD')).Trim()

        $ref = New-GitRecoveryRef -RepositoryRoot $repo
        Invoke-TestGit -Repo $repo -Arguments @('reset', '--hard', 'HEAD~1', '--quiet') | Out-Null
        (Invoke-TestGit -Repo $repo -Arguments @('rev-parse', 'HEAD')).Trim() | Should -Not -Be $before

        Invoke-TestGit -Repo $repo -Arguments @('reset', '--hard', $ref, '--quiet') | Out-Null
        (Invoke-TestGit -Repo $repo -Arguments @('rev-parse', 'HEAD')).Trim() | Should -Be $before
        (Get-Content -LiteralPath (Join-Path $repo 'a.txt') -Raw).Trim() | Should -Be 'two'
    }
}

Describe 'Invoke-SafeGitPull result shape' {
    It 'always exposes a RecoveryRef property' {
        $repo = New-TestRepo (Join-Path $TestDrive 'shape')
        $result = Invoke-SafeGitPull -RepositoryPath $repo -TimeoutSeconds 30 -WarningAction SilentlyContinue
        $result.PSObject.Properties.Name | Should -Contain 'RecoveryRef'
        $result.Status | Should -Be 'NoUpstream'
    }

    It 'reports NotGitRepository for a plain directory' {
        $plain = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        (Invoke-SafeGitPull -RepositoryPath $plain -TimeoutSeconds 30 -WarningAction SilentlyContinue).Status |
            Should -Be 'NotGitRepository'
    }
}
