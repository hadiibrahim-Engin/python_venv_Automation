#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a dummy workspace covering every project shape DevSetup must handle.

.DESCRIPTION
    Creates a throwaway tree of Python projects plus real Git repositories
    (with real upstreams, so Safe Git Sync can be driven for real rather than
    mocked). Everything lands under -Root, which is deleted and recreated.

    Layouts produced under <Root>/projects:
        uv-project        [project] + [tool.uv] + uv.lock          -> uv
        poetry-project    [tool.poetry] + poetry backend + lock     -> poetry
        pep621-only       [project] alone                           -> Ambiguous
        dual-lock         [project] + uv.lock + poetry.lock         -> Ambiguous
        both-tools        [tool.uv] + [tool.poetry]                 -> Ambiguous
        no-signal         empty directory                           -> Default
        bad-constraint    requires-python = ">=3.11 <3.13"          -> fail closed
        no-version        [project] without version
        malformed         syntactically invalid TOML
        diverged-meta     [tool.poetry].version != [project].version
        requirements-only requirements.txt, no pyproject.toml

    Git repositories under <Root>/git (each is <name> + <name>.origin.git):
        clean             in sync with upstream
        behind            upstream has one extra commit
        dirty-behind      behind AND has uncommitted changes
        diverged          local and upstream both moved
        no-upstream       branch without a tracking remote
        detached          detached HEAD
        not-a-repo        plain directory

.PARAMETER Root
    Workspace directory. Defaults to <temp>/devsetup-dummy.

.EXAMPLE
    ./tests/dummy/New-DummyProject.ps1 -Root /tmp/devsetup-dummy
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()][string] $Root = (Join-Path ([System.IO.Path]::GetTempPath()) 'devsetup-dummy'),
    [Parameter()][switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Text) if (-not $Quiet) { Write-Host "  + $Text" -ForegroundColor DarkGray } }

function New-Dir {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    return $Path
}

function Set-File {
    param([string] $Path, [string] $Content)
    New-Dir (Split-Path -Parent $Path) | Out-Null
    # -NoNewline keeps the fixtures byte-exact; content already ends with "`n".
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8 -NoNewline
}

function Invoke-Git {
    param([string] $RepoPath, [string[]] $Arguments)
    # Argument list, never a concatenated shell string.
    $all = @('-C', $RepoPath,
             '-c', 'user.email=dummy@example.invalid',
             '-c', 'user.name=DevSetup Dummy',
             '-c', 'commit.gpgsign=false',
             '-c', 'init.defaultBranch=main') + $Arguments
    $out = & git @all 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("git {0} failed in {1}: {2}" -f ($Arguments -join ' '), $RepoPath, ($out -join "`n"))
    }
    return $out
}

# ---------------------------------------------------------------------------
# Python project fixtures
# ---------------------------------------------------------------------------

$projects = [ordered]@{
    'uv-project' = @{
        Files = @{
            'pyproject.toml' = @"
[project]
name = "uv-demo"
version = "1.2.3"
requires-python = ">=3.11,<3.13"
dependencies = ["requests>=2.31"]

[dependency-groups]
dev = ["pytest>=8"]

[tool.uv]
package = true
"@
            'uv.lock' = "version = 1`nrequires-python = `">=3.11,<3.13`"`n"
        }
        Expect = 'uv'
    }
    'poetry-project' = @{
        Files = @{
            'pyproject.toml' = @"
[tool.poetry]
name = "poetry-demo"
version = "0.4.0"

[tool.poetry.dependencies]
python = "^3.11"
requests = "^2.31"

[build-system]
requires = ["poetry-core"]
build-backend = "poetry.core.masonry.api"
"@
            'poetry.lock' = "# poetry lock placeholder`n"
        }
        Expect = 'poetry'
    }
    'pep621-only' = @{
        Files = @{
            'pyproject.toml' = @"
[project]
name = "neutral-demo"
version = "0.1.0"
requires-python = ">=3.11"
"@
        }
        Expect = 'Ambiguous'
    }
    'dual-lock' = @{
        Files = @{
            'pyproject.toml' = @"
[project]
name = "dual-demo"
version = "0.1.0"
requires-python = ">=3.11"
"@
            'uv.lock'     = "version = 1`n"
            'poetry.lock' = "# poetry`n"
        }
        Expect = 'Ambiguous'
    }
    'both-tools' = @{
        Files = @{
            'pyproject.toml' = @"
[project]
name = "both-demo"
version = "0.1.0"
requires-python = ">=3.11"

[tool.uv]
package = true

[tool.poetry]
name = "both-demo"
"@
        }
        Expect = 'Ambiguous'
    }
    'no-signal' = @{
        Files  = @{}
        Expect = 'Default'
    }
    'bad-constraint' = @{
        Files = @{
            'pyproject.toml' = @"
[project]
name = "bad-demo"
version = "0.1.0"
requires-python = ">=3.11 <3.13"

[tool.uv]
package = true
"@
        }
        Expect = 'uv'
    }
    'no-version' = @{
        Files = @{
            'pyproject.toml' = @"
[project]
name = "noversion-demo"
requires-python = ">=3.11"

[tool.uv]
package = true
"@
        }
        Expect = 'uv'
    }
    'malformed' = @{
        Files = @{
            'pyproject.toml' = @"
[project
name = "broken
version =
"@
        }
        Expect = 'Default'
    }
    'diverged-meta' = @{
        Files = @{
            'pyproject.toml' = @"
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.poetry]
# stale metadata left behind by a Poetry -> PEP 621 migration
name = "diverged-demo"
version = "9.9.9"

[project]
name = "diverged-demo"
version = "1.2.3"   # the real one
requires-python = ">=3.11"
"@
        }
        Expect = 'poetry'
    }
    'requirements-only' = @{
        Files = @{
            'requirements.txt' = "requests==2.31.0`n"
        }
        Expect = 'Default'
    }
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

if ($PSCmdlet.ShouldProcess($Root, 'Recreate dummy workspace')) {
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
    New-Dir $Root | Out-Null
} else {
    return
}

if (-not $Quiet) { Write-Host "Dummy workspace: $Root" -ForegroundColor Cyan }

$projectsRoot = New-Dir (Join-Path $Root 'projects')
foreach ($name in $projects.Keys) {
    $dir = New-Dir (Join-Path $projectsRoot $name)
    foreach ($file in $projects[$name].Files.Keys) {
        Set-File -Path (Join-Path $dir $file) -Content $projects[$name].Files[$file]
    }
    Write-Step ("projects/{0} (expect: {1})" -f $name, $projects[$name].Expect)
}

# A DigiCert stub: Start-Setup's INIT guard only checks that the path exists.
$digicert = Join-Path $Root 'digicert-stub.exe'
Set-File -Path $digicert -Content ''

# ---------------------------------------------------------------------------
# Git fixtures - real repositories with real upstreams
# ---------------------------------------------------------------------------

$gitRoot = New-Dir (Join-Path $Root 'git')

function New-DummyRepo {
    param([string] $Name)
    $origin = Join-Path $gitRoot ("{0}.origin.git" -f $Name)
    $work   = Join-Path $gitRoot $Name

    New-Dir $origin | Out-Null
    Invoke-Git -RepoPath $origin -Arguments @('init', '--bare', '--initial-branch=main', '--quiet') | Out-Null

    New-Dir $work | Out-Null
    Invoke-Git -RepoPath $work -Arguments @('init', '--initial-branch=main', '--quiet') | Out-Null
    Set-File -Path (Join-Path $work 'README.md') -Content "# $Name`n"
    Invoke-Git -RepoPath $work -Arguments @('add', '-A') | Out-Null
    Invoke-Git -RepoPath $work -Arguments @('commit', '-m', 'chore: initial commit', '--quiet') | Out-Null
    Invoke-Git -RepoPath $work -Arguments @('remote', 'add', 'origin', $origin) | Out-Null
    Invoke-Git -RepoPath $work -Arguments @('push', '--quiet', '-u', 'origin', 'main') | Out-Null
    return @{ Work = $work; Origin = $origin }
}

function Add-UpstreamCommit {
    param([string] $Origin, [string] $Message)
    # Clone, commit, push back - the cheapest way to move a bare repo forward.
    $tmp = Join-Path $gitRoot ('.push-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Invoke-Git -RepoPath $gitRoot -Arguments @('clone', '--quiet', $Origin, $tmp) | Out-Null
    Set-File -Path (Join-Path $tmp 'upstream.txt') -Content ("{0}`n" -f $Message)
    Invoke-Git -RepoPath $tmp -Arguments @('add', '-A') | Out-Null
    Invoke-Git -RepoPath $tmp -Arguments @('commit', '-m', $Message, '--quiet') | Out-Null
    Invoke-Git -RepoPath $tmp -Arguments @('push', '--quiet', 'origin', 'HEAD:main') | Out-Null
    Remove-Item -LiteralPath $tmp -Recurse -Force
}

# clean: work tree exactly matches upstream
New-DummyRepo -Name 'clean' | Out-Null
Write-Step 'git/clean (UpToDate)'

# behind: upstream moved ahead by one commit
$behind = New-DummyRepo -Name 'behind'
Add-UpstreamCommit -Origin $behind.Origin -Message 'feat: upstream change'
Invoke-Git -RepoPath $behind.Work -Arguments @('fetch', '--quiet') | Out-Null
Write-Step 'git/behind (FastForwarded)'

# dirty-behind: behind upstream AND has uncommitted local edits
$dirty = New-DummyRepo -Name 'dirty-behind'
Add-UpstreamCommit -Origin $dirty.Origin -Message 'feat: upstream change'
Invoke-Git -RepoPath $dirty.Work -Arguments @('fetch', '--quiet') | Out-Null
Set-File -Path (Join-Path $dirty.Work 'README.md') -Content "# dirty-behind`nlocal edit`n"
Write-Step 'git/dirty-behind (SkippedDirty)'

# diverged: both sides moved
$div = New-DummyRepo -Name 'diverged'
Add-UpstreamCommit -Origin $div.Origin -Message 'feat: upstream change'
Set-File -Path (Join-Path $div.Work 'local.txt') -Content "local`n"
Invoke-Git -RepoPath $div.Work -Arguments @('add', '-A') | Out-Null
Invoke-Git -RepoPath $div.Work -Arguments @('commit', '-m', 'feat: local change', '--quiet') | Out-Null
Invoke-Git -RepoPath $div.Work -Arguments @('fetch', '--quiet') | Out-Null
Write-Step 'git/diverged (Diverged)'

# no-upstream: a branch that was never pushed
$noUp = New-DummyRepo -Name 'no-upstream'
Invoke-Git -RepoPath $noUp.Work -Arguments @('checkout', '--quiet', '-b', 'feature/local-only') | Out-Null
Write-Step 'git/no-upstream (NoUpstream)'

# detached: HEAD points at a commit, not a branch
$det = New-DummyRepo -Name 'detached'
$sha = (Invoke-Git -RepoPath $det.Work -Arguments @('rev-parse', 'HEAD')) -join ''
Invoke-Git -RepoPath $det.Work -Arguments @('checkout', '--quiet', $sha.Trim()) | Out-Null
Write-Step 'git/detached (DetachedHead)'

# not-a-repo: a plain directory
New-Dir (Join-Path $gitRoot 'not-a-repo') | Out-Null
Set-File -Path (Join-Path $gitRoot 'not-a-repo/file.txt') -Content "nothing`n"
Write-Step 'git/not-a-repo (NotGitRepository)'

if (-not $Quiet) {
    Write-Host ''
    Write-Host ("Projects : {0}" -f $projectsRoot)
    Write-Host ("Git      : {0}" -f $gitRoot)
    Write-Host ("DigiCert : {0}" -f $digicert)
}

[pscustomobject]@{
    Root         = $Root
    ProjectsRoot = $projectsRoot
    GitRoot      = $gitRoot
    DigiCertStub = $digicert
    Projects     = @($projects.Keys)
}
