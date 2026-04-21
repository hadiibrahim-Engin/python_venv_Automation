#Requires -Version 5.1
# =============================================================================
# Module  : Detection.psm1
# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Package manager detection and resolution.

.DESCRIPTION
    Single-responsibility module: determines which package manager a project
    uses. Setup-Core.psm1 and PackageManager.psm1 contain zero knowledge of
    this decision process — they call Invoke-PmDetection and use the result.

    Resolution priority (first match wins):
      1. CLI argument       -PackageManager uv|poetry
      2. .setup-config.json only when the user previously pinned via CLI;
                            auto-detected results are never persisted there.
      3. pyproject.toml     build backend → [tool.*] sections → [project]
                            table → lock files
      4. Built-in default   poetry
#>

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'UI.psm1')     -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Toml.psm1')   -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Config.psm1') -Force -DisableNameChecking -ErrorAction Stop


# ---------------------------------------------------------------------------
# Resolve the active package manager
# ---------------------------------------------------------------------------
function Resolve-PackageManager {
<#
.SYNOPSIS
    Returns which package manager to use, and why.

.DESCRIPTION
    Single authoritative function for PM selection. Call once per setup run.
    No other code path should make this decision.

.PARAMETER CliChoice
    The raw -PackageManager CLI argument: 'uv', 'poetry', or 'auto'.

.PARAMETER ProjectRoot
    Project root directory to scan.

.OUTPUTS
    PSCustomObject:
        PackageManager   - 'uv' | 'poetry'
        Source           - 'cli' | 'config-file' | 'detected' | 'default'
        DetectionReport  - from Get-PmDetectionReport, or $null
        ConfigPath       - path to .setup-config.json that was read, or $null
#>
    param(
        [Parameter(Mandatory=$true)][string] $CliChoice,
        [Parameter(Mandatory=$true)][string] $ProjectRoot
    )

    # Priority 1: explicit CLI override
    if ($CliChoice -ne 'auto') {
        return [pscustomobject]@{
            PackageManager  = $CliChoice
            Source          = 'cli'
            DetectionReport = $null
            ConfigPath      = $null
        }
    }

    # Priority 2: user-pinned config file
    # Only fires when the user ran with an explicit -PackageManager that was
    # saved to .setup-config.json.  Auto-detected values are never persisted,
    # so this cannot create a stale-cache loop on TOML changes.
    $configPath = Join-Path $ProjectRoot '.setup-config.json'
    $config     = Read-SetupConfig -ProjectRoot $ProjectRoot
    if ($config -and
        $config.PSObject.Properties.Name -contains 'PackageManager' -and
        $config.PackageManager -in @('uv', 'poetry')) {

        return [pscustomobject]@{
            PackageManager  = $config.PackageManager
            Source          = 'config-file'
            DetectionReport = $null
            ConfigPath      = $configPath
        }
    }

    # Priority 3 & 4: TOML scan + built-in default
    # Get-PmDetectionReport handles both (defaults to 'poetry' when no signal).
    $report = Get-PmDetectionReport -ProjectRoot $ProjectRoot
    $src    = if ($report.Reason -eq 'no signal found - using default') { 'default' } else { 'detected' }

    return [pscustomobject]@{
        PackageManager  = $report.PackageManager
        Source          = $src
        DetectionReport = $report
        ConfigPath      = $null
    }
}


# ---------------------------------------------------------------------------
# Apply detection to context and emit log lines
# ---------------------------------------------------------------------------
function Invoke-PmDetection {
<#
.SYNOPSIS
    Resolves the package manager, mutates $Ctx, and logs every signal.

.DESCRIPTION
    This is the single call the orchestrator (Setup-Core.psm1) makes inside
    the DETECT pipeline step. It:
      1. Applies non-PM config-file preferences (PinnedVersions, IncludeDev).
      2. Calls Resolve-PackageManager to determine the winning PM.
      3. Writes the result back into $Ctx.
      4. Emits structured log lines via Write-LogDetail so the operator can
         see exactly which evidence drove the decision.

    By keeping all of this logic here, Setup-Core.psm1 contains zero PM
    knowledge beyond a single one-liner call.

.PARAMETER Ctx
    The mutable setup context hashtable.  The following keys are written:
        PackageManager   - 'uv' | 'poetry'
        PmSource         - 'cli' | 'config-file' | 'detected' | 'default'
        PmDetectionReport - raw signals, or $null
#>
    param([Parameter(Mandatory=$true)][hashtable] $Ctx)

    # Apply non-PM config-file preferences (PinnedVersions, IncludeDev).
    Merge-SetupConfig -ProjectRoot $Ctx.ProjectRoot -Ctx $Ctx

    # Resolve PM using the full priority chain.
    $resolved              = Resolve-PackageManager -CliChoice $Ctx.PackageManager -ProjectRoot $Ctx.ProjectRoot
    $Ctx.PackageManager    = $resolved.PackageManager
    $Ctx.PmSource          = $resolved.Source
    $Ctx.PmDetectionReport = $resolved.DetectionReport

    # Emit structured evidence log.
    switch ($resolved.Source) {
        'cli' {
            Write-LogDetail -Key 'source'   -Value 'CLI argument (-PackageManager)'
            Write-LogDetail -Key 'selected' -Value $Ctx.PackageManager
        }
        'config-file' {
            Write-LogDetail -Key 'source'      -Value '.setup-config.json  (pinned by a previous CLI-explicit run)'
            Write-LogDetail -Key 'config_path' -Value $resolved.ConfigPath
            Write-LogDetail -Key 'selected'    -Value $Ctx.PackageManager
            Write-LogDetail -Key 'tip'         -Value 'Remove .setup-config.json to re-detect from pyproject.toml.'
        }
        'detected' {
            $r = $resolved.DetectionReport
            Write-LogDetail -Key 'source'          -Value 'auto-detected from pyproject.toml / lock files'
            Write-LogDetail -Key 'decided_by'      -Value $r.Reason
            Write-LogDetail -Key 'poetry_backend'  -Value $r.HasPoetryBackend
            Write-LogDetail -Key 'uv_section'      -Value $r.HasUvSection
            Write-LogDetail -Key 'poetry_section'  -Value $r.HasPoetrySection
            Write-LogDetail -Key 'project_section' -Value $r.HasProjectSection
            Write-LogDetail -Key 'uv_lock'         -Value $r.HasUvLock
            Write-LogDetail -Key 'poetry_lock'     -Value $r.HasPoetryLock
            Write-LogDetail -Key 'selected'        -Value $Ctx.PackageManager
        }
        'default' {
            Write-LogDetail -Key 'source'   -Value 'no signal found in pyproject.toml or lock files'
            Write-LogDetail -Key 'selected' -Value $Ctx.PackageManager
            Write-LogDetail -Key 'tip'      -Value 'Add [tool.uv] or [tool.poetry] to pyproject.toml for explicit detection.'
        }
    }
}


Export-ModuleMember -Function Resolve-PackageManager, Invoke-PmDetection