#Requires -Version 5.1
# =============================================================================
# Module  : Toml.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'UI.psm1') -Force -DisableNameChecking -ErrorAction Stop

<#
.SYNOPSIS
    pyproject.toml parsing helpers used during setup.
#>

<#
.SYNOPSIS
    Extracts project name and Python requirement from pyproject.toml.

.DESCRIPTION
    Supports both PEP 621 `requires-python` and Poetry `python` constraint
    keys and returns normalized metadata required by setup orchestration.
#>
function Get-ProjectMetadata {
    param([Parameter(Mandatory=$true)][string] $ProjectRoot)

    $tomlPath = Join-Path $ProjectRoot 'pyproject.toml'
    if (-not (Test-Path $tomlPath)) {
        Exit-WithError -Message "pyproject.toml not found at: $tomlPath"
    }

    $content = Get-Content $tomlPath -Raw

    # Support both hatchling (requires-python) and Poetry-native (python) keys.
    # TOML allows both "double" and 'single' quoted strings.
    $requires = $null
    if ($content -match 'requires-python\s*=\s*[''"]([^''"]+)[''"]') {
        $requires = $Matches[1]
    } elseif ($content -match '(?m)^\s*python\s*=\s*[''"]([^''"]+)[''"]') {
        $requires = $Matches[1]
    } else {
        Exit-WithError -Message "Could not find a Python version constraint in pyproject.toml.`n  Add either 'requires-python' (hatchling) or 'python' (Poetry) key."
    }

    if ($content -notmatch '(?m)^\s*name\s*=\s*[''"]([^''"]+)[''"]') {
        Exit-WithError -Message "Could not find 'name' in pyproject.toml"
    }

    [pscustomobject]@{
        ProjectName    = $Matches[1]
        RequiresPython = $requires
    }
}

<#
.SYNOPSIS
    Infers the preferred package manager for a project directory.

.DESCRIPTION
    Detection priority (first match wins):

      1. Build-system backend  - most definitive authorship signal.
           build-backend = "poetry.core.masonry.api"  → poetry
           (uv / hatchling / setuptools have no single canonical backend
            so they are handled by lower priorities)

      2. Explicit tool sections in pyproject.toml - clear tooling choice.
           [tool.uv] or [tool.uv.*]  present, no [tool.poetry.*] → uv
           [tool.poetry] or [tool.poetry.*] present, no [tool.uv*] → poetry

      3. PEP 621 [project] table without Poetry sections → uv.
           Poetry stores all its metadata under [tool.poetry]; a bare
           [project] section (used by uv, hatchling, setuptools) with no
           [tool.poetry.*] means this is a non-Poetry project.

      4. Lock files - what was most recently USED.
           uv.lock only    → uv
           poetry.lock only → poetry
           Both present    → the more recently written file wins.

      5. No signal → poetry (conservative default).

.PARAMETER ProjectRoot
    Project directory to inspect.

.OUTPUTS
    String: 'uv' or 'poetry'.
#>
function Get-PreferredPackageManager {
    param([Parameter(Mandatory=$true)][string] $ProjectRoot)

    $poetryLock = Join-Path $ProjectRoot 'poetry.lock'
    $uvLock     = Join-Path $ProjectRoot 'uv.lock'
    $tomlPath   = Join-Path $ProjectRoot 'pyproject.toml'

    $hasUvSection      = $false
    $hasPoetrySection  = $false
    $hasProjectSection = $false
    $hasPoetryBackend  = $false

    if (Test-Path $tomlPath -PathType Leaf) {
        $raw = Get-Content $tomlPath -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            # Strip full-line TOML comments to avoid false matches on lines like:
            #   # [tool.uv.sources]  or  # build-backend = "poetry.core.masonry.api"
            $clean = ($raw -split "`r?`n" |
                Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

            # [build-system] backend - strongest authorship signal
            $hasPoetryBackend  = $clean -match 'poetry\.core\.masonry\.api'

            # Explicit tool configuration sections
            $hasUvSection      = $clean -match '(?m)^\s*\[tool\.uv[\].]'
            $hasPoetrySection  = $clean -match '(?m)^\s*\[tool\.poetry[\].]'

            # PEP 621 project table ([project] without trailing dot -
            # avoids matching [project.optional-dependencies] etc.)
            $hasProjectSection = $clean -match '(?m)^\s*\[project\]'
        }
    }

    # Priority 1: Build-system backend
    # poetry.core.masonry.api is an unambiguous Poetry marker.
    # No equivalent exists for uv; skip to priority 2 when backend is absent.
    if ($hasPoetryBackend) { return 'poetry' }

    # Priority 2: Explicit tool sections
    if ($hasUvSection     -and -not $hasPoetrySection) { return 'uv'     }
    if ($hasPoetrySection -and -not $hasUvSection)     { return 'poetry' }
    # Both sections present (dual-mode project): fall through to lock files.

    # Priority 3: PEP 621 [project] table
    # Poetry stores all metadata under [tool.poetry]; any project using [project]
    # without [tool.poetry.*] is a PEP 621 / uv-style project.
    if ($hasProjectSection -and -not $hasPoetrySection) { return 'uv' }

    # Priority 4: Lock files
    $hasPoetryLock = Test-Path $poetryLock -PathType Leaf
    $hasUvLock     = Test-Path $uvLock     -PathType Leaf

    if ($hasPoetryLock -and -not $hasUvLock) { return 'poetry' }
    if ($hasUvLock -and -not $hasPoetryLock) { return 'uv'     }

    if ($hasPoetryLock -and $hasUvLock) {
        $uvTime     = (Get-Item -LiteralPath $uvLock).LastWriteTimeUtc
        $poetryTime = (Get-Item -LiteralPath $poetryLock).LastWriteTimeUtc
        return $(if ($uvTime -ge $poetryTime) { 'uv' } else { 'poetry' })
    }

    # Priority 5: Default
    return 'poetry'
}

<#
.SYNOPSIS
    Runs the full package-manager detection and returns every signal found.

.DESCRIPTION
    Identical detection logic to Get-PreferredPackageManager, but instead of
    returning only the winner it returns a structured report that callers can
    log for diagnostics.  The orchestrator uses this so the PM step can show
    exactly which evidence triggered the decision.

.OUTPUTS
    PSCustomObject with:
        PackageManager    - 'uv' or 'poetry'
        Reason            - Human-readable string naming the winning evidence
        HasPoetryBackend  - build-backend = "poetry.core.masonry.api" found
        HasUvSection      - [tool.uv] or [tool.uv.*] section found
        HasPoetrySection  - [tool.poetry] or [tool.poetry.*] section found
        HasProjectSection - [project] table (PEP 621) found
        HasUvLock         - uv.lock present on disk
        HasPoetryLock     - poetry.lock present on disk
#>
function Get-PmDetectionReport {
    param([Parameter(Mandatory=$true)][string] $ProjectRoot)

    $poetryLock = Join-Path $ProjectRoot 'poetry.lock'
    $uvLock     = Join-Path $ProjectRoot 'uv.lock'
    $tomlPath   = Join-Path $ProjectRoot 'pyproject.toml'

    $hasUvSection      = $false
    $hasPoetrySection  = $false
    $hasProjectSection = $false
    $hasPoetryBackend  = $false
    $hasUvLock         = Test-Path $uvLock     -PathType Leaf
    $hasPoetryLock     = Test-Path $poetryLock -PathType Leaf

    if (Test-Path $tomlPath -PathType Leaf) {
        $raw = Get-Content $tomlPath -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            $clean = ($raw -split "`r?`n" |
                Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

            $hasPoetryBackend  = $clean -match 'poetry\.core\.masonry\.api'
            $hasUvSection      = $clean -match '(?m)^\s*\[tool\.uv[\].]'
            $hasPoetrySection  = $clean -match '(?m)^\s*\[tool\.poetry[\].]'
            $hasProjectSection = $clean -match '(?m)^\s*\[project\]'
        }
    }

    # Mirror the priority chain in Get-PreferredPackageManager exactly.
    $pm     = 'poetry'
    $reason = 'no signal found - using default'

    if ($hasPoetryBackend) {
        $pm     = 'poetry'
        $reason = 'build-backend = "poetry.core.masonry.api" in [build-system]'
    } elseif ($hasUvSection -and -not $hasPoetrySection) {
        $pm     = 'uv'
        $reason = '[tool.uv] section present, no [tool.poetry]'
    } elseif ($hasPoetrySection -and -not $hasUvSection) {
        $pm     = 'poetry'
        $reason = '[tool.poetry] section present, no [tool.uv]'
    } elseif ($hasUvSection -and $hasPoetrySection) {
        # Dual-mode: fall through to lock files (reason set below)
        $reason = '[tool.uv] and [tool.poetry] both present - checking lock files'
    } elseif ($hasProjectSection -and -not $hasPoetrySection) {
        $pm     = 'uv'
        $reason = '[project] table (PEP 621) present, no [tool.poetry]'
    }

    # Lock-file tiebreaker (reached for dual-mode or no TOML signal)
    if ($reason -like '*lock files*' -or $reason -eq 'no signal found - using default') {
        if ($hasPoetryLock -and -not $hasUvLock) {
            $pm     = 'poetry'
            $reason = 'poetry.lock present, no uv.lock'
        } elseif ($hasUvLock -and -not $hasPoetryLock) {
            $pm     = 'uv'
            $reason = 'uv.lock present, no poetry.lock'
        } elseif ($hasUvLock -and $hasPoetryLock) {
            $uvTime     = (Get-Item -LiteralPath $uvLock).LastWriteTimeUtc
            $poetryTime = (Get-Item -LiteralPath $poetryLock).LastWriteTimeUtc
            if ($uvTime -ge $poetryTime) {
                $pm     = 'uv'
                $reason = 'uv.lock more recently written than poetry.lock'
            } else {
                $pm     = 'poetry'
                $reason = 'poetry.lock more recently written than uv.lock'
            }
        }
    }

    [pscustomobject]@{
        PackageManager    = $pm
        Reason            = $reason
        HasPoetryBackend  = $hasPoetryBackend
        HasUvSection      = $hasUvSection
        HasPoetrySection  = $hasPoetrySection
        HasProjectSection = $hasProjectSection
        HasUvLock         = $hasUvLock
        HasPoetryLock     = $hasPoetryLock
    }
}

Export-ModuleMember -Function Get-ProjectMetadata, Get-PreferredPackageManager, Get-PmDetectionReport