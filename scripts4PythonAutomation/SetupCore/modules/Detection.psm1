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
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'UI.psm1')     -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Toml.psm1')   -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Config.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Errors.psm1')  -Force -DisableNameChecking -Global -ErrorAction Stop


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
        [Parameter(Mandatory=$true)][string] $ProjectRoot,

        # When set, an ambiguous project is a hard error instead of a prompt.
        # CI and every scripted caller must pass this.
        [Parameter()][switch] $NonInteractive
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

    # Priority 3 & 4: TOML scan + built-in default.
    $report = Get-PmDetectionReport -ProjectRoot $ProjectRoot

    if ($report.Status -eq 'Ambiguous') {
        # Never guess. Either the operator decides, or we stop.
        $choice = Resolve-AmbiguousPackageManager -Report $report -ProjectRoot $ProjectRoot -NonInteractive:$NonInteractive
        return [pscustomobject]@{
            PackageManager  = $choice
            Source          = 'user-decision'
            DetectionReport = $report
            ConfigPath      = $null
        }
    }

    $src = if ($report.Status -eq 'Default') { 'default' } else { 'detected' }

    return [pscustomobject]@{
        PackageManager  = $report.PackageManager
        Source          = $src
        DetectionReport = $report
        ConfigPath      = $null
    }
}


<#
.SYNOPSIS
    Turns an ambiguous detection report into a decision, or fails cleanly.

.DESCRIPTION
    Non-interactive (CI, scripted, -NonInteractive): throws a SetupException
    carrying the report's AmbiguityCode so the caller can map it to a support
    code. Interactive: presents the evidence and asks the operator to pick.
    There is deliberately no automatic fallback.
#>
function Resolve-AmbiguousPackageManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][pscustomobject] $Report,
        [Parameter(Mandatory=$true)][string] $ProjectRoot,
        [Parameter()][switch] $NonInteractive
    )

    $code = if ($Report.AmbiguityCode) { $Report.AmbiguityCode } else { 'PYPROJECT_PM_AMBIGUOUS' }

    if ($NonInteractive) {
        throw (New-SetupException `
            -Message ("Package manager cannot be determined for '{0}'. {1}. Re-run with -PackageManager uv|poetry, or make the project explicit ([tool.uv] / [tool.poetry])." -f $ProjectRoot, $Report.Reason) `
            -ErrorCode $code `
            -Step 'DETECT' `
            -Context @{
                ProjectRoot   = $ProjectRoot
                Reason        = $Report.Reason
                Candidates    = ($Report.Candidates -join ',')
                HasUvLock     = $Report.HasUvLock
                HasPoetryLock = $Report.HasPoetryLock
            })
    }

    Write-Host ''
    Write-Host 'Der Package Manager fuer dieses Projekt ist nicht eindeutig.' -ForegroundColor Yellow
    Write-Host ("  Grund: {0}" -f $Report.Reason) -ForegroundColor DarkGray
    Write-Host '  [1] uv'
    Write-Host '  [2] poetry'

    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $answer = Read-Host 'Auswahl (1/2)'
        switch (([string]$answer).Trim().ToLowerInvariant()) {
            '1'      { return 'uv' }
            'uv'     { return 'uv' }
            '2'      { return 'poetry' }
            'poetry' { return 'poetry' }
        }
        Write-Host 'Bitte 1 oder 2 eingeben.' -ForegroundColor Yellow
    }

    throw (New-SetupException `
        -Message 'No valid package-manager selection was made.' `
        -ErrorCode $code -Step 'DETECT' -Context @{ ProjectRoot = $ProjectRoot })
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
      1. Applies non-PM config-file preferences (PinnedVersions).
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

    # Apply non-PM config-file preferences (PinnedVersions).
    Merge-SetupConfig -ProjectRoot $Ctx.ProjectRoot -Ctx $Ctx

    # Resolve PM using the full priority chain.
    $nonInteractive = $false
    if ($Ctx.ContainsKey('NonInteractive')) { $nonInteractive = [bool]$Ctx.NonInteractive }
    $resolved              = Resolve-PackageManager -CliChoice $Ctx.PackageManager -ProjectRoot $Ctx.ProjectRoot -NonInteractive:$nonInteractive
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
        'user-decision' {
            $r = $resolved.DetectionReport
            Write-LogDetail -Key 'source'     -Value 'ambiguous project - resolved by operator'
            Write-LogDetail -Key 'ambiguity'  -Value $r.AmbiguityCode
            Write-LogDetail -Key 'decided_by' -Value $r.Reason
            Write-LogDetail -Key 'selected'   -Value $Ctx.PackageManager
        }
        'default' {
            Write-LogDetail -Key 'source'   -Value 'no signal found in pyproject.toml or lock files'
            Write-LogDetail -Key 'selected' -Value $Ctx.PackageManager
            Write-LogDetail -Key 'tip'      -Value 'Add [tool.uv] or [tool.poetry] to pyproject.toml for explicit detection.'
        }
    }
}


Export-ModuleMember -Function Resolve-PackageManager, Invoke-PmDetection, Resolve-AmbiguousPackageManager
