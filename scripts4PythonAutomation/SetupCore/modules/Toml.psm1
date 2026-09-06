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
    PEP 621 `[project]` is TOOL-NEUTRAL: its presence says nothing about which
    package manager owns the project. Detection therefore works on *strong*
    signals only, and refuses to guess when the evidence is contradictory or
    absent.

    Strong uv signals      : [tool.uv] / [tool.uv.*] section, uv.lock
    Strong poetry signals  : build-backend = "poetry.core.masonry.api",
                             [tool.poetry] / [tool.poetry.*] section, poetry.lock

    Resolution:
      1. Strong signals for BOTH managers      -> Ambiguous.
         Lock-file mtime is deliberately NOT used as a tie-breaker: which file
         was written last is an artifact of tooling order, not a statement of
         intent, and silently picking one corrupts the project.
      2. Strong signals for exactly one        -> that manager (Resolved).
      3. No strong signals but [project] present -> Ambiguous (PEP 621 only).
      4. Nothing at all                        -> poetry (Default).

.OUTPUTS
    PSCustomObject with:
        PackageManager    - 'uv' | 'poetry' | $null when Status is 'Ambiguous'
        Status            - 'Resolved' | 'Ambiguous' | 'Default'
        AmbiguityCode     - $null, 'PYPROJECT_PM_AMBIGUOUS' or
                            'PYPROJECT_MULTIPLE_LOCKFILES'
        Candidates        - managers still in play when Status is 'Ambiguous'
        Reason            - human-readable string naming the winning evidence
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

            $hasPoetryBackend  = [bool]($clean -match 'poetry\.core\.masonry\.api')
            $hasUvSection      = [bool]($clean -match '(?m)^\s*\[tool\.uv[\].]')
            $hasPoetrySection  = [bool]($clean -match '(?m)^\s*\[tool\.poetry[\].]')
            $hasProjectSection = [bool]($clean -match '(?m)^\s*\[project\]')
        }
    }

    # --- Collect strong evidence per manager -------------------------------
    $uvEvidence = @()
    if ($hasUvSection) { $uvEvidence += '[tool.uv] section' }
    if ($hasUvLock)    { $uvEvidence += 'uv.lock' }

    $poetryEvidence = @()
    if ($hasPoetryBackend) { $poetryEvidence += 'build-backend = "poetry.core.masonry.api"' }
    if ($hasPoetrySection) { $poetryEvidence += '[tool.poetry] section' }
    if ($hasPoetryLock)    { $poetryEvidence += 'poetry.lock' }

    $pm            = $null
    $status        = 'Resolved'
    $ambiguityCode = $null
    $candidates    = @()

    if ($uvEvidence.Count -gt 0 -and $poetryEvidence.Count -gt 0) {
        $status        = 'Ambiguous'
        $candidates    = @('uv', 'poetry')
        $ambiguityCode = if ($hasUvLock -and $hasPoetryLock) { 'PYPROJECT_MULTIPLE_LOCKFILES' } else { 'PYPROJECT_PM_AMBIGUOUS' }
        $reason        = 'conflicting evidence - uv: {0}; poetry: {1}' -f ($uvEvidence -join ', '), ($poetryEvidence -join ', ')
    }
    elseif ($uvEvidence.Count -gt 0) {
        $pm     = 'uv'
        $reason = 'uv evidence only: {0}' -f ($uvEvidence -join ', ')
    }
    elseif ($poetryEvidence.Count -gt 0) {
        $pm     = 'poetry'
        $reason = 'poetry evidence only: {0}' -f ($poetryEvidence -join ', ')
    }
    elseif ($hasProjectSection) {
        # PEP 621 alone is tool-neutral - refuse to guess.
        $status        = 'Ambiguous'
        $candidates    = @('uv', 'poetry')
        $ambiguityCode = 'PYPROJECT_PM_AMBIGUOUS'
        $reason        = '[project] (PEP 621) is tool-neutral and no [tool.uv]/[tool.poetry] or lock file is present'
    }
    else {
        $pm     = 'poetry'
        $status = 'Default'
        $reason = 'no signal found - using default'
    }

    [pscustomobject]@{
        PackageManager    = $pm
        Status            = $status
        AmbiguityCode     = $ambiguityCode
        Candidates        = $candidates
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
    $report = Get-PmDetectionReport -ProjectRoot $ProjectRoot
    if ($report.Status -eq 'Ambiguous') {
        # Callers that only want a string cannot express "needs a decision";
        # returning $null here would be silently coerced to a manager later.
        throw ("Package manager is ambiguous for '{0}': {1}" -f $ProjectRoot, $report.Reason)
    }
    return $report.PackageManager
}


Export-ModuleMember -Function `
    Get-ProjectMetadata, `
    Get-PreferredPackageManager, `
    Get-PmDetectionReport, `
    Get-TomlContent, `
    Clear-TomlCache
