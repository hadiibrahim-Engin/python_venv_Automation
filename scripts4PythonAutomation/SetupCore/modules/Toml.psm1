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

.DESCRIPTION
    Reads and caches pyproject.toml once per module lifetime so that multiple
    callers in the same setup run never read the same file more than once.
    The cache is keyed by resolved file path.
#>

# ---------------------------------------------------------------------------
# Module-level read cache — keyed by resolved file path.
# Avoids repeated disk reads when Get-ProjectMetadata, Get-PmDetectionReport,
# and Get-PreferredPackageManager are all called in the same setup run.
# ---------------------------------------------------------------------------
$script:_tomlCache = @{}

function Get-TomlContent {
<#
.SYNOPSIS
    Returns the raw text of pyproject.toml, reading from disk only once per
    path per module lifetime.
#>
    param([Parameter(Mandatory=$true)][string] $TomlPath)

    $key = $TomlPath.ToLowerInvariant()
    if ($script:_tomlCache.ContainsKey($key)) {
        return $script:_tomlCache[$key]
    }

    $raw = Get-Content $TomlPath -Raw -ErrorAction SilentlyContinue
    $script:_tomlCache[$key] = $raw
    return $raw
}

function Clear-TomlCache {
<#
.SYNOPSIS
    Clears the cached TOML content. Call between test runs.
#>
    $script:_tomlCache = @{}
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-TomlClean {
<#
.SYNOPSIS
    Strips full-line TOML comments from raw TOML text.
    Uses a single regex replace (faster than split/filter/join).
#>
    param([Parameter(Mandatory=$true)][string] $Raw)
    # Remove lines that are entirely comments (optional leading whitespace + #).
    # The (?m) flag makes ^ match start-of-line.
    # \r? handles Windows CRLF line endings.
    return ($Raw -replace '(?m)^\s*#[^\r\n]*\r?\n?', '')
}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

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

    $content = Get-TomlContent -TomlPath $tomlPath
    if (-not $content) {
        Exit-WithError -Message "pyproject.toml is empty or unreadable: $tomlPath"
    }

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
    Runs the full package-manager detection and returns every signal found.

.DESCRIPTION
    Detection priority (first match wins):

      1. Build-system backend  - most definitive authorship signal.
           build-backend = "poetry.core.masonry.api"  → poetry

      2. Explicit tool sections in pyproject.toml.
           [tool.uv] or [tool.uv.*]  present, no [tool.poetry.*] → uv
           [tool.poetry] or [tool.poetry.*] present, no [tool.uv*] → poetry

      3. PEP 621 [project] table without Poetry sections → uv.

      4. Lock files - what was most recently USED.
           uv.lock only    → uv
           poetry.lock only → poetry
           Both present    → the more recently written file wins.

      5. No signal → poetry (conservative default).

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
        $raw = Get-TomlContent -TomlPath $tomlPath
        if ($raw) {
            # Strip full-line TOML comments to avoid false matches on lines like:
            #   # [tool.uv.sources]  or  # build-backend = "poetry.core.masonry.api"
            $clean = Get-TomlClean -Raw $raw

            $hasPoetryBackend  = $clean -match 'poetry\.core\.masonry\.api'
            $hasUvSection      = $clean -match '(?m)^\s*\[tool\.uv[\].]'
            $hasPoetrySection  = $clean -match '(?m)^\s*\[tool\.poetry[\].]'
            $hasProjectSection = $clean -match '(?m)^\s*\[project\]'
        }
    }

    # Mirror the detection priority chain.
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


<#
.SYNOPSIS
    Infers the preferred package manager for a project directory.

.DESCRIPTION
    Thin wrapper around Get-PmDetectionReport that returns only the winning
    package manager string.  Exists for backward compatibility and simple
    callers that do not need the full detection report.
#>
function Get-PreferredPackageManager {
    param([Parameter(Mandatory=$true)][string] $ProjectRoot)
    return (Get-PmDetectionReport -ProjectRoot $ProjectRoot).PackageManager
}


Export-ModuleMember -Function `
    Get-ProjectMetadata, `
    Get-PreferredPackageManager, `
    Get-PmDetectionReport, `
    Get-TomlContent, `
    Clear-TomlCache
