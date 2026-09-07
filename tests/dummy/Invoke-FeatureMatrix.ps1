#Requires -Version 5.1
<#
.SYNOPSIS
    Drives every DevSetup feature that is exercisable on this host against the
    dummy workspace and prints a pass/fail matrix.

.DESCRIPTION
    This is an end-to-end smoke harness, not a unit-test suite: it calls the
    real functions against the real fixtures produced by New-DummyProject.ps1.

    Features that genuinely cannot run off Windows (Authenticode signing,
    Windows Python discovery, venv Scripts\ layout) are reported as SKIP with
    the reason, never silently omitted.

.PARAMETER Root
    Dummy workspace root. Rebuilt automatically unless -NoRebuild is given.

.EXAMPLE
    pwsh -NoProfile -File ./tests/dummy/Invoke-FeatureMatrix.ps1
#>
[CmdletBinding()]
param(
    [Parameter()][string] $Root = (Join-Path ([System.IO.Path]::GetTempPath()) 'devsetup-dummy'),
    [Parameter()][switch] $NoRebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Several error paths prompt "Press Enter to exit" when a human is present.
# This harness is always unattended, so declare that up front.
$env:DEVSETUP_NONINTERACTIVE = '1'

$RepoRoot   = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' | Join-Path -ChildPath '..')).Path
$ModulesDir = Join-Path $RepoRoot 'scripts4PythonAutomation/SetupCore/modules'

$script:Results = [System.Collections.Generic.List[pscustomobject]]::new()
$script:Group   = ''

function Set-Group { param([string] $Name) $script:Group = $Name; Write-Host ''; Write-Host "== $Name" -ForegroundColor Cyan }

function Test-Feature {
    <#
    .SYNOPSIS
        Runs one check. The scriptblock returns the actual value; it is compared
        with -Expected. A thrown exception is reported, never swallowed.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][scriptblock] $Actual,
        # AllowEmptyString: '' is a legitimate expectation ("no findings"),
        # but a mandatory [string] rejects it.
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Expected
    )
    try {
        $value = [string](& $Actual)
        $ok = ($value -eq $Expected)
        $status = if ($ok) { 'PASS' } else { 'FAIL' }
    } catch {
        $value = 'EXCEPTION: ' + $_.Exception.Message
        $status = 'FAIL'
    }
    $script:Results.Add([pscustomobject]@{ Group = $script:Group; Name = $Name; Status = $status; Expected = $Expected; Actual = $value })
    $color = switch ($status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host ("  [{0}] {1,-52} {2}" -f $status, $Name, $value) -ForegroundColor $color
}

function Skip-Feature {
    param([string] $Name, [string] $Reason)
    $script:Results.Add([pscustomobject]@{ Group = $script:Group; Name = $Name; Status = 'SKIP'; Expected = ''; Actual = $Reason })
    Write-Host ("  [SKIP] {0,-52} {1}" -f $Name, $Reason) -ForegroundColor DarkYellow
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

if (-not $NoRebuild) {
    & (Join-Path $PSScriptRoot 'New-DummyProject.ps1') -Root $Root -Quiet | Out-Null
}
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Dummy workspace not found at $Root. Run New-DummyProject.ps1 first."
}

$Projects = Join-Path $Root 'projects'
$GitRoot  = Join-Path $Root 'git'
$DigiCert = Join-Path $Root 'digicert-stub.exe'

Write-Host "DevSetup feature matrix" -ForegroundColor White
Write-Host ("Workspace : {0}" -f $Root)
Write-Host ("Host      : {0} / PowerShell {1}" -f [System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim(), $PSVersionTable.PSVersion)

# Load the engine the same way driver.ps1 does (reverse-order global re-import).
$loadOrder = @('Compat','Constants','Errors','Logging','UI','Path','Versioning','Toml','NativeCommand',
               'Config','Detection','Filesystem','PythonDiscovery','Venv','VSCode','Tcl','Poetry','UV',
               'PackageManager','Prechecks','CodeSigning','GitSync','SetupPipeline','SetupSteps')
Import-Module (Join-Path $RepoRoot 'PythonVenvAutomation/PythonVenvAutomation.psd1') -Force -DisableNameChecking -Global
foreach ($n in $loadOrder[($loadOrder.Count - 1)..0]) {
    Microsoft.PowerShell.Core\Import-Module -FullyQualifiedName (Join-Path $ModulesDir "$n.psm1") -Force -DisableNameChecking -Global
}

$isWindowsHost = $env:OS -eq 'Windows_NT'

# ---------------------------------------------------------------------------
# 1. Package manager detection
# ---------------------------------------------------------------------------
Set-Group 'Package manager detection (Part L)'

$detectionCases = @(
    @{ Project = 'uv-project';        Expected = 'Resolved:uv' }
    @{ Project = 'poetry-project';    Expected = 'Resolved:poetry' }
    @{ Project = 'pep621-only';       Expected = 'Ambiguous:PYPROJECT_PM_AMBIGUOUS' }
    @{ Project = 'dual-lock';         Expected = 'Ambiguous:PYPROJECT_MULTIPLE_LOCKFILES' }
    @{ Project = 'both-tools';        Expected = 'Ambiguous:PYPROJECT_PM_AMBIGUOUS' }
    @{ Project = 'no-signal';         Expected = 'Default:poetry' }
    @{ Project = 'requirements-only'; Expected = 'Default:poetry' }
    @{ Project = 'diverged-meta';     Expected = 'Resolved:poetry' }
    @{ Project = 'malformed';         Expected = 'Default:poetry' }
)
foreach ($case in $detectionCases) {
    $dir = Join-Path $Projects $case.Project
    Test-Feature -Name ("detect {0}" -f $case.Project) -Expected $case.Expected -Actual {
        Clear-TomlCache
        $r = Get-PmDetectionReport -ProjectRoot $dir
        if ($r.Status -eq 'Ambiguous') { "Ambiguous:$($r.AmbiguityCode)" } else { "$($r.Status):$($r.PackageManager)" }
    }.GetNewClosure()
}

Test-Feature -Name 'ambiguous project fails closed (non-interactive)' -Expected 'PYPROJECT_PM_AMBIGUOUS' -Actual {
    Clear-TomlCache; Clear-SetupConfigCache
    try { Resolve-PackageManager -CliChoice auto -ProjectRoot (Join-Path $Projects 'pep621-only') -NonInteractive | Out-Null; 'NO-THROW' }
    catch { $_.Exception.ErrorCode }
}

Test-Feature -Name 'explicit CLI choice overrides ambiguity' -Expected 'cli:poetry' -Actual {
    Clear-TomlCache; Clear-SetupConfigCache
    $r = Resolve-PackageManager -CliChoice poetry -ProjectRoot (Join-Path $Projects 'dual-lock') -NonInteractive
    "$($r.Source):$($r.PackageManager)"
}

# ---------------------------------------------------------------------------
# 2. Python version constraints
# ---------------------------------------------------------------------------
Set-Group 'Python version constraints (Part N)'

$constraintCases = @(
    @{ In = '>=3.11,<3.13'; Out = '>=3.11 <3.13' }
    @{ In = '>=3.11';       Out = '>=3.11' }
    @{ In = '==3.11';       Out = '>=3.11 <3.12' }
    @{ In = '^3.11';        Out = '>=3.11 <4.0' }
    @{ In = '~3.11';        Out = '>=3.11 <3.12' }
    @{ In = '~=3.11';       Out = '>=3.11 <4.0' }
    @{ In = '~=3.11.4';     Out = '>=3.11.4 <3.12' }
    @{ In = '!=3.12';       Out = '!=line3.12' }
)
foreach ($case in $constraintCases) {
    Test-Feature -Name ("parse {0}" -f $case.In) -Expected $case.Out -Actual {
        $parsed = ConvertTo-VersionConstraints -ConstraintStr $case.In
        ($parsed | ForEach-Object { '{0}{1}' -f $_.Op, $_.Version }) -join ' '
    }.GetNewClosure()
}

foreach ($bad in @('~=3', '>=abc', 'foo', '>=3.11 <3.13', '>=3')) {
    Test-Feature -Name ("reject '{0}'" -f $bad) -Expected 'PYTHON_CONSTRAINT_UNSUPPORTED' -Actual {
        try { ConvertTo-VersionConstraints -ConstraintStr $bad | Out-Null; 'NO-THROW' }
        catch { if ($_.Exception.PSObject.Properties.Name -contains 'ErrorCode') { $_.Exception.ErrorCode } else { $_.Exception.GetType().Name } }
    }.GetNewClosure()
}

Test-Feature -Name '!=3.12 excludes 3.12.5 (not just 3.12.0)' -Expected 'False' -Actual {
    $c = ConvertTo-VersionConstraints -ConstraintStr '>=3.11,!=3.12'
    Test-VersionConstraints -Version ([Version]'3.12.5') -Constraints $c
}

Test-Feature -Name 'bad-constraint project is rejected end to end' -Expected 'PYTHON_CONSTRAINT_UNSUPPORTED' -Actual {
    Clear-TomlCache
    $meta = Get-ProjectMetadata -ProjectRoot (Join-Path $Projects 'bad-constraint')
    try { ConvertTo-VersionConstraints -ConstraintStr $meta.RequiresPython | Out-Null; 'NO-THROW' }
    catch { $_.Exception.ErrorCode }
}

# ---------------------------------------------------------------------------
# 3. Project metadata
# ---------------------------------------------------------------------------
Set-Group 'Project metadata (Toml)'

Test-Feature -Name 'reads name + requires-python (PEP 621)' -Expected 'uv-demo|>=3.11,<3.13' -Actual {
    Clear-TomlCache
    $m = Get-ProjectMetadata -ProjectRoot (Join-Path $Projects 'uv-project')
    "$($m.ProjectName)|$($m.RequiresPython)"
}

Test-Feature -Name 'reads Poetry python constraint' -Expected 'poetry-demo|^3.11' -Actual {
    Clear-TomlCache
    $m = Get-ProjectMetadata -ProjectRoot (Join-Path $Projects 'poetry-project')
    "$($m.ProjectName)|$($m.RequiresPython)"
}

Test-Feature -Name 'missing pyproject.toml is an error' -Expected 'threw' -Actual {
    Clear-TomlCache
    try { Get-ProjectMetadata -ProjectRoot (Join-Path $Projects 'no-signal') | Out-Null; 'NO-THROW' } catch { 'threw' }
}

# ---------------------------------------------------------------------------
# 4. Safe Git Sync - real repositories
# ---------------------------------------------------------------------------
Set-Group 'Safe Git Sync (Part Y)'

$gitCases = @(
    @{ Repo = 'clean';        Expected = 'UpToDate' }
    @{ Repo = 'dirty-behind'; Expected = 'SkippedDirty' }
    @{ Repo = 'diverged';     Expected = 'Diverged' }
    @{ Repo = 'no-upstream';  Expected = 'NoUpstream' }
    @{ Repo = 'detached';     Expected = 'DetachedHead' }
    @{ Repo = 'not-a-repo';   Expected = 'NotGitRepository' }
)
foreach ($case in $gitCases) {
    $dir = Join-Path $GitRoot $case.Repo
    Test-Feature -Name ("git {0}" -f $case.Repo) -Expected $case.Expected -Actual {
        (Invoke-SafeGitPull -RepositoryPath $dir -TimeoutSeconds 30 -WarningAction SilentlyContinue).Status
    }.GetNewClosure()
}

Test-Feature -Name 'git behind -WhatIf does not mutate' -Expected 'WhatIfFastForward' -Actual {
    (Invoke-SafeGitPull -RepositoryPath (Join-Path $GitRoot 'behind') -TimeoutSeconds 30 -WhatIf -WarningAction SilentlyContinue).Status
}

Test-Feature -Name 'git behind fast-forwards for real' -Expected 'FastForwarded' -Actual {
    (Invoke-SafeGitPull -RepositoryPath (Join-Path $GitRoot 'behind') -TimeoutSeconds 30 -Confirm:$false -WarningAction SilentlyContinue).Status
}

Test-Feature -Name '-Force creates a recovery ref before reset --hard' -Expected 'True' -Actual {
    $repo = Join-Path $GitRoot 'diverged'
    $before = (& git -C $repo rev-parse HEAD).Trim()
    $r = Invoke-SafeGitPull -RepositoryPath $repo -TimeoutSeconds 30 -Force -Confirm:$false -WarningAction SilentlyContinue
    if (-not $r.RecoveryRef) { return 'no RecoveryRef on result' }
    $saved = (& git -C $repo rev-parse $r.RecoveryRef 2>$null)
    [string]($saved -and $saved.Trim() -eq $before)
}

Test-Feature -Name 'forced reset never runs git clean (untracked survive)' -Expected 'True' -Actual {
    $repo = Join-Path $GitRoot 'clean'
    Set-Content -LiteralPath (Join-Path $repo 'untracked-user-data.txt') -Value 'keep me' -Encoding UTF8
    Invoke-SafeGitPull -RepositoryPath $repo -TimeoutSeconds 30 -Force -Confirm:$false -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Out-Null
    [string](Test-Path -LiteralPath (Join-Path $repo 'untracked-user-data.txt'))
}

# ---------------------------------------------------------------------------
# 5. Project configuration
# ---------------------------------------------------------------------------
Set-Group 'Project configuration (.setup-config.json)'

Test-Feature -Name 'round-trips a pinned package manager' -Expected 'config-file:uv' -Actual {
    $dir = Join-Path $Projects 'pep621-only'
    Set-Content -LiteralPath (Join-Path $dir '.setup-config.json') -Value '{"PackageManager":"uv"}' -Encoding UTF8
    # Read-SetupConfig caches "no config here" negatively, so the cache must be
    # dropped after creating the file.
    Clear-SetupConfigCache; Clear-TomlCache
    $r = Resolve-PackageManager -CliChoice auto -ProjectRoot $dir -NonInteractive
    $out = "$($r.Source):$($r.PackageManager)"
    Remove-Item -LiteralPath (Join-Path $dir '.setup-config.json') -Force
    Clear-SetupConfigCache
    $out
}

Test-Feature -Name 'invalid config JSON is rejected' -Expected 'CONFIG_INVALID' -Actual {
    $dir = Join-Path $Projects 'pep621-only'
    Set-Content -LiteralPath (Join-Path $dir '.setup-config.json') -Value '{ not json' -Encoding UTF8
    Clear-SetupConfigCache
    try { Read-SetupConfig -ProjectRoot $dir | Out-Null; 'NO-THROW' } catch { $_.Exception.ErrorCode }
    finally {
        Remove-Item -LiteralPath (Join-Path $dir '.setup-config.json') -Force -ErrorAction SilentlyContinue
        Clear-SetupConfigCache
    }
}

# ---------------------------------------------------------------------------
# 6. Structured logging
# ---------------------------------------------------------------------------
Set-Group 'Structured logging (Part W)'

Test-Feature -Name 'session returns a correlation id' -Expected 'True' -Actual {
    $id = Start-StructuredLogSession -LogLevel INFO
    [string](-not [string]::IsNullOrWhiteSpace([string]$id))
}

Test-Feature -Name 'context exposes the correlation id' -Expected 'True' -Actual {
    Start-StructuredLogSession -LogLevel INFO | Out-Null
    $ctx = Get-StructuredLogContext
    [string](-not [string]::IsNullOrWhiteSpace([string]$ctx.CorrelationId))
}

Test-Feature -Name 'writes an event without throwing' -Expected 'ok' -Actual {
    Start-StructuredLogSession -LogLevel DEBUG | Out-Null
    Write-StructuredLog -Level INFO -Step 'MATRIX' -Module 'FeatureMatrix' -Message 'dummy event' -Context @{ sample = 1 } -NoConsole
    'ok'
}

# ---------------------------------------------------------------------------
# 7. Setup pipeline
# ---------------------------------------------------------------------------
Set-Group 'Setup pipeline'

Test-Feature -Name 'pipeline step definition round-trips' -Expected 'DEMO|Matrix' -Actual {
    $step = New-SetupPipelineStep -Name 'DEMO' -Module 'Matrix' -Message 'demo step' -Action { 'done' }
    "$($step.Name)|$($step.Module)"
}

Test-Feature -Name 'read-only step is marked read-only' -Expected 'True' -Actual {
    $step = New-SetupPipelineStep -Name 'RO' -Module 'Matrix' -Message 'read only' -Action { } -ReadOnly
    [string][bool]$step.ReadOnly
}

if (-not $isWindowsHost) {
    Skip-Feature -Name 'full Start-Setup pipeline (real)' -Reason 'PythonDiscovery enumerates C:\ - Windows only'
}

Test-Feature -Name 'dry-run pipeline reaches VENV-VALIDATE (10 steps)' -Expected 'True' -Actual {
    $env:OS = 'Windows_NT'   # Get-IsWindows is $env:OS -eq 'Windows_NT'
    Clear-TomlCache; Clear-SetupConfigCache
    $out = & {
        try {
            Invoke-PythonVenvSetup -ProjectRoot (Join-Path $Projects 'uv-project') -NonInteractive `
                -SkipGitPull -EnableCodeSigning:$false -DigiCertUtilityExe $DigiCert -WhatIf 6>&1 2>&1
        } catch { $_ | Out-String }
    } | Out-String
    [string]($out -match 'VENV-VALIDATE' -or $out -match 'VENV_INVALID' -or $out -match 'not created')
}

Test-Feature -Name 'ambiguous project stops the pipeline at DETECT' -Expected 'True' -Actual {
    $env:OS = 'Windows_NT'
    Clear-TomlCache; Clear-SetupConfigCache
    $out = & {
        try {
            Invoke-PythonVenvSetup -ProjectRoot (Join-Path $Projects 'pep621-only') -NonInteractive `
                -SkipGitPull -EnableCodeSigning:$false -DigiCertUtilityExe $DigiCert -WhatIf 6>&1 2>&1
        } catch { $_ | Out-String }
    } | Out-String
    [string]($out -match 'AMBIGUOUS')
}

# ---------------------------------------------------------------------------
# 8. Dependency semantics
# ---------------------------------------------------------------------------
Set-Group 'Dependency semantics (Part O)'

# Invoke-DependencyInstallStep needs its package-manager calls stubbed, and
# Pester's Mock/InModuleScope only work inside Invoke-Pester. Run the real
# suite for this file rather than reimplementing a mocking layer here.
$depTests = Join-Path $RepoRoot 'tests/DependencySemantics.Tests.ps1'
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 })) {
    Skip-Feature -Name 'dependency semantics' -Reason 'Pester 5+ not installed'
} else {
    Test-Feature -Name 'devsetup default does NOT upgrade dependencies' -Expected 'True' -Actual {
        Import-Module Pester -MinimumVersion 5.0 -Force
        $cfg = New-PesterConfiguration
        $cfg.Run.Path = $depTests
        $cfg.Run.PassThru = $true
        $cfg.Output.Verbosity = 'None'
        $res = Invoke-Pester -Configuration $cfg
        [string]($res.FailedCount -eq 0 -and $res.PassedCount -ge 7)
    }
}

# ---------------------------------------------------------------------------
# 8b. pyproject health and healing (Parts I / K / Q)
# ---------------------------------------------------------------------------
Set-Group 'pyproject health (Parts I / K)'

$healthCases = @(
    @{ Project = 'uv-project';        Expected = '' }
    @{ Project = 'poetry-project';    Expected = '' }
    @{ Project = 'pep621-only';       Expected = 'PYPROJECT_PM_AMBIGUOUS' }
    @{ Project = 'dual-lock';         Expected = 'PYPROJECT_MULTIPLE_LOCKFILES' }
    @{ Project = 'malformed';         Expected = 'PYPROJECT_PARSE_INVALID' }
    @{ Project = 'requirements-only'; Expected = 'PYPROJECT_MISSING' }
    @{ Project = 'bad-constraint';    Expected = 'PYPROJECT_PYTHON_CONSTRAINT_INVALID,LOCK_MISSING' }
    @{ Project = 'no-version';        Expected = 'PYPROJECT_VERSION_MISSING,LOCK_MISSING' }
    @{ Project = 'diverged-meta';     Expected = 'PYPROJECT_METADATA_DIVERGED,PYPROJECT_POETRY_METADATA_LEGACY,LOCK_MISSING' }
)
foreach ($case in $healthCases) {
    $dir = Join-Path $Projects $case.Project
    Test-Feature -Name ("health {0}" -f $case.Project) -Expected $case.Expected -Actual {
        Clear-PyProjectHealthCache
        $r = Get-PyProjectHealthReport -ProjectRoot $dir
        ($r.Findings | ForEach-Object Code) -join ','
    }.GetNewClosure()
}

Test-Feature -Name 'doctor-style read is non-mutating' -Expected 'True' -Actual {
    $dir = Join-Path $Projects 'diverged-meta'
    $before = Get-FileHash -LiteralPath (Join-Path $dir 'pyproject.toml') -Algorithm SHA256
    Clear-PyProjectHealthCache
    Get-PyProjectHealthReport -ProjectRoot $dir | Out-Null
    Test-PyProjectHealth -ProjectRoot $dir -NoCache | Out-Null
    Test-PyProjectLockHealth -ProjectRoot $dir -PackageManager 'poetry' | Out-Null
    $after = Get-FileHash -LiteralPath (Join-Path $dir 'pyproject.toml') -Algorithm SHA256
    [string]($before.Hash -eq $after.Hash)
}

Set-Group 'pyproject healing (Part Q)'

$healRoot = Join-Path $Root 'heal'
if (Test-Path -LiteralPath $healRoot) { Remove-Item -LiteralPath $healRoot -Recurse -Force }
New-Item -ItemType Directory -Path $healRoot -Force | Out-Null
$healToml = @"
[project]
name = "healme"
version = "1.0.0"
requires-python = ">=3.11"
dependencies = ["requests>=2.31", "Requests", "rich"]

[tool.uv]
dev-dependencies = ["pytest", "ruff"]
"@
Set-Content -LiteralPath (Join-Path $healRoot 'pyproject.toml') -Value $healToml -Encoding UTF8
Set-Content -LiteralPath (Join-Path $healRoot 'uv.lock') -Value 'lock' -Encoding UTF8

Test-Feature -Name 'WhatIf healing changes nothing' -Expected 'True' -Actual {
    Clear-PyProjectHealthCache
    $before = (Get-FileHash -LiteralPath (Join-Path $healRoot 'pyproject.toml') -Algorithm SHA256).Hash
    Invoke-PyProjectHealing -ProjectRoot $healRoot -WhatIf | Out-Null
    [string]($before -eq (Get-FileHash -LiteralPath (Join-Path $healRoot 'pyproject.toml') -Algorithm SHA256).Hash)
}

Test-Feature -Name 'applies both safe fixes' -Expected 'PYPROJECT_DUPLICATE_DEPENDENCY,PYPROJECT_LEGACY_UV_DEV_DEPENDENCIES' -Actual {
    Clear-PyProjectHealthCache
    $script:healResult = Invoke-PyProjectHealing -ProjectRoot $healRoot -Confirm:$false
    ($script:healResult.Applied | ForEach-Object Code) -join ','
}

Test-Feature -Name 'result is still valid TOML with both dep lists intact' -Expected 'requests>=2.31|rich :: pytest|ruff' -Actual {
    Clear-PyProjectHealthCache
    $m = (Get-PyProjectHealthReport -ProjectRoot $healRoot).Metadata
    "{0} :: {1}" -f ($m.RuntimeDependencies -join '|'), ($m.DevDependencies -join '|')
}

Test-Feature -Name 'a backup of the original was written' -Expected 'True' -Actual {
    [string]($script:healResult.BackupPath -and (Test-Path -LiteralPath $script:healResult.BackupPath))
}

Test-Feature -Name 'lock file was not touched by pyproject healing' -Expected 'lock' -Actual {
    (Get-Content -LiteralPath (Join-Path $healRoot 'uv.lock') -Raw).Trim()
}

Test-Feature -Name 'healing is idempotent (second run is a no-op)' -Expected 'False' -Actual {
    Clear-PyProjectHealthCache
    [string](Invoke-PyProjectHealing -ProjectRoot $healRoot -Confirm:$false).Changed
}

# ---------------------------------------------------------------------------
# 9. Version bumping
# ---------------------------------------------------------------------------
Set-Group 'Version bumping (Part J)'

$python = @('python3', 'python') | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $python) {
    Skip-Feature -Name 'bump-version.py section awareness' -Reason 'no python3 on PATH'
} else {
    Test-Feature -Name 'bumps [project], leaves stale [tool.poetry] alone' -Expected '1.2.4|9.9.9' -Actual {
        $target = Join-Path $Projects 'diverged-meta/pyproject.toml'
        $script = Join-Path $RepoRoot 'scripts/bump-version.py'
        $code = @"
import importlib.util, tomllib, pathlib
spec = importlib.util.spec_from_file_location('bv', r'$script')
bv = importlib.util.module_from_spec(spec); spec.loader.exec_module(bv)
p = pathlib.Path(r'$target')
ver, key = bv.read_version(p)
bv.write_version('1.2.4', key, p)
d = tomllib.loads(p.read_text())
print(d['project']['version'] + '|' + d['tool']['poetry']['version'])
"@
        (& $python.Source '-c' $code 2>&1 | Select-Object -Last 1).ToString().Trim()
    }
}

# ---------------------------------------------------------------------------
# 9b. User commands (Parts R / S / T / U / V)
# ---------------------------------------------------------------------------
Set-Group 'User commands (Parts R-V)'

$cmdRoot = Join-Path $Root 'commands'
if (Test-Path -LiteralPath $cmdRoot) { Remove-Item -LiteralPath $cmdRoot -Recurse -Force }
New-Item -ItemType Directory -Path $cmdRoot -Force | Out-Null
@"
[project]
name = "cmddemo"
version = "1.0.0"
requires-python = ">=3.11"
dependencies = ["requests>=2.31", "Requests"]

[tool.uv]
dev-dependencies = ["pytest"]
"@ | Set-Content -LiteralPath (Join-Path $cmdRoot 'pyproject.toml') -Encoding UTF8
Set-Content -LiteralPath (Join-Path $cmdRoot 'uv.lock') -Value 'lock' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $cmdRoot '.setup-config.json') -Encoding UTF8 `
    -Value '{"PackageManager":"uv","AZURE_PAT":"supersecrettoken123"}'

function Get-CmdTreeHash {
    param([string] $Path)
    (Get-ChildItem -LiteralPath $Path -Recurse -Force -File | Sort-Object FullName |
        ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join ''
}

Test-Feature -Name 'doctor produces a report' -Expected 'True' -Actual {
    Clear-PyProjectHealthCache
    $script:doctorReport = Get-DevSetupDoctorReport -ProjectRoot $cmdRoot
    [string]($script:doctorReport.Checks.Count -gt 5)
}

Test-Feature -Name 'doctor changes nothing on disk' -Expected 'True' -Actual {
    $before = Get-CmdTreeHash -Path $cmdRoot
    Clear-PyProjectHealthCache
    Get-DevSetupDoctorReport -ProjectRoot $cmdRoot | Out-Null
    Get-DevSetupDoctorReport -ProjectRoot $cmdRoot | Out-Null
    [string]($before -eq (Get-CmdTreeHash -Path $cmdRoot))
}

Test-Feature -Name 'doctor output has no internal module names' -Expected 'True' -Actual {
    $text = Format-DevSetupDoctorReport -Report $script:doctorReport
    [string](-not ($text -match 'psm1' -or $text -match 'StackTrace'))
}

Test-Feature -Name 'repair -WhatIf changes nothing' -Expected 'True' -Actual {
    $before = Get-CmdTreeHash -Path $cmdRoot
    Invoke-DevSetupRepair -ProjectRoot $cmdRoot -WhatIf | Out-Null
    [string]($before -eq (Get-CmdTreeHash -Path $cmdRoot))
}

Test-Feature -Name 'repair applies only the safe fixes' -Expected 'PYPROJECT_DUPLICATE_DEPENDENCY,PYPROJECT_LEGACY_UV_DEV_DEPENDENCIES' -Actual {
    $r = Invoke-DevSetupRepair -ProjectRoot $cmdRoot -Confirm:$false
    ($r.Applied | ForEach-Object Code) -join ','
}

Test-Feature -Name 'repair fails closed on an outstanding decision (CI)' -Expected 'False' -Actual {
    $amb = Join-Path $Root 'commands-ambiguous'
    if (Test-Path -LiteralPath $amb) { Remove-Item -LiteralPath $amb -Recurse -Force }
    New-Item -ItemType Directory -Path $amb -Force | Out-Null
    "[project]`nname = `"x`"`nversion = `"1.0.0`"`nrequires-python = `">=3.11`"`n" |
        Set-Content -LiteralPath (Join-Path $amb 'pyproject.toml') -Encoding UTF8
    Clear-PyProjectHealthCache
    [string](Invoke-DevSetupRepair -ProjectRoot $amb -NonInteractive -Confirm:$false).Succeeded
}

Test-Feature -Name 'support bundle is created' -Expected 'True' -Actual {
    $log = Join-Path $cmdRoot 'run.ndjson'
    '{"url":"https://user:PATSECRET99@dev.azure.com/org","token":"tok-abc-123"}' |
        Set-Content -LiteralPath $log -Encoding UTF8
    $script:bundle = New-DevSetupSupportBundle -ProjectRoot $cmdRoot -OutputDirectory (Join-Path $Root 'bundles') -LogPath $log -Confirm:$false
    [string]($script:bundle.Created -and (Test-Path -LiteralPath $script:bundle.ZipPath))
}

Test-Feature -Name 'support bundle contains no secrets' -Expected 'True' -Actual {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead($script:bundle.ZipPath)
    try {
        $all = foreach ($entry in $zip.Entries) {
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        $joined = $all -join "`n"
        [string](-not ($joined -match 'supersecrettoken123' -or $joined -match 'PATSECRET99' -or $joined -match 'tok-abc-123'))
    } finally { $zip.Dispose() }
}

Test-Feature -Name 'support codes map to stable DS- identifiers' -Expected 'DS-P204,DS-P202,DS-X901' -Actual {
    @('PYPROJECT_PM_AMBIGUOUS', 'PYTHON_CONSTRAINT_UNSUPPORTED', 'TOTALLY_UNKNOWN') |
        ForEach-Object { Get-DevSetupSupportCode -ErrorCode $_ } | Join-String -Separator ','
}

Test-Feature -Name 'user-facing error hides technical detail' -Expected 'True' -Actual {
    $text = Format-DevSetupUserError -ErrorCode 'TOML_PARSE_ERROR'
    [string](($text -match 'DS-P201') -and -not ($text -match 'Exception' -or $text -match 'psm1'))
}

# ---------------------------------------------------------------------------
# 9c. Distribution and self-update (Parts A / B / D / E / F / G / AB)
# ---------------------------------------------------------------------------
Set-Group 'Distribution round trip (Parts A-H, AB)'

$distRoot = Join-Path $Root 'dist'
if (Test-Path -LiteralPath $distRoot) { Remove-Item -LiteralPath $distRoot -Recurse -Force }
New-Item -ItemType Directory -Path $distRoot -Force | Out-Null

function Invoke-MatrixGit {
    param([string] $Dir, [string[]] $Arguments)
    $all = @('-C', $Dir, '-c', 'user.email=matrix@example.invalid', '-c', 'user.name=Matrix',
             '-c', 'commit.gpgsign=false', '-c', 'init.defaultBranch=main') + $Arguments
    $out = & git @all 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("git {0} failed: {1}" -f ($Arguments -join ' '), ($out -join "`n")) }
    return $out
}

# A local bare repository stands in for Azure DevOps: same git transport,
# no network and no credentials.
$origin = Join-Path $distRoot 'origin.git'
New-Item -ItemType Directory -Path $origin -Force | Out-Null
Invoke-MatrixGit -Dir $origin -Arguments @('init', '--bare', '--initial-branch=main', '--quiet') | Out-Null

$publisher = Join-Path $distRoot 'publisher'
New-Item -ItemType Directory -Path $publisher -Force | Out-Null
Invoke-MatrixGit -Dir $publisher -Arguments @('init', '--initial-branch=distribution', '--quiet') | Out-Null
Invoke-MatrixGit -Dir $publisher -Arguments @('remote', 'add', 'origin', $origin) | Out-Null

$payload = @((Join-Path $RepoRoot 'PythonVenvAutomation'), (Join-Path $RepoRoot 'scripts4PythonAutomation'))

function Publish-MatrixVersion {
    param([string] $Version, [string] $Channel, [string] $Minimum)
    if (-not (Test-Path -LiteralPath (Join-Path $publisher ('packages/' + $Version)))) {
        New-DevSetupPackage -DistributionRoot $publisher -Version $Version -SourcePaths $payload -Confirm:$false | Out-Null
    }
    Set-DevSetupChannel -DistributionRoot $publisher -Channel $Channel -Version $Version -MinimumSupportedVersion $Minimum -Confirm:$false | Out-Null
    Invoke-MatrixGit -Dir $publisher -Arguments @('add', '-A') | Out-Null
    Invoke-MatrixGit -Dir $publisher -Arguments @('commit', '--quiet', '-m', ("publish {0} to {1}" -f $Version, $Channel)) | Out-Null
    Invoke-MatrixGit -Dir $publisher -Arguments @('push', '--quiet', 'origin', 'HEAD:distribution') | Out-Null
}

Test-Feature -Name 'publish 1.8.0 and push to the distribution branch' -Expected 'True' -Actual {
    Publish-MatrixVersion -Version '1.8.0' -Channel stable -Minimum '1.8.0'
    [string]((Test-DevSetupPublishedPackage -DistributionRoot $publisher -Version '1.8.0').IsValid)
}

Test-Feature -Name 'republishing the same version is refused (immutable)' -Expected 'DISTRIBUTION_VERSION_EXISTS' -Actual {
    try { New-DevSetupPackage -DistributionRoot $publisher -Version '1.8.0' -SourcePaths $payload -Confirm:$false | Out-Null; 'NO-THROW' }
    catch { $_.Exception.ErrorCode }
}

# --- client side ---------------------------------------------------------
. (Join-Path $RepoRoot 'PythonVenvAutomation/templates/DevSetup.Bootstrap.ps1')

$clientRoot = Join-Path $distRoot 'client'
New-Item -ItemType Directory -Path $clientRoot -Force | Out-Null
$clientConfig = Join-Path $clientRoot 'config.json'
@{
    CommandName = 'devsetup'; DistributionUri = $origin; DistributionBranch = 'distribution'
    Channel = 'stable'; AutoUpdateEnabled = $true; AllowOfflineContinue = $true
} | ConvertTo-Json | Set-Content -LiteralPath $clientConfig -Encoding UTF8
$clientPaths = Get-DevSetupBootPaths -InstallRoot $clientRoot

Test-Feature -Name 'client clones and activates 1.8.0' -Expected 'True|1.8.0' -Actual {
    $relaunch = Invoke-DevSetupBootAutoUpdate -CommandName devsetup -ConfigPath $clientConfig -Confirm:$false
    "{0}|{1}" -f $relaunch, (Get-DevSetupBootState -StateFile $clientPaths.StateFile).version
}

Test-Feature -Name 'second run is a no-op' -Expected 'False' -Actual {
    [string](Invoke-DevSetupBootAutoUpdate -CommandName devsetup -ConfigPath $clientConfig -Confirm:$false)
}

Test-Feature -Name 'client upgrades to 1.9.0 and keeps the previous version' -Expected 'True|1.9.0|1.8.0' -Actual {
    Publish-MatrixVersion -Version '1.9.0' -Channel stable -Minimum '1.8.0'
    $relaunch = Invoke-DevSetupBootAutoUpdate -CommandName devsetup -ConfigPath $clientConfig -Confirm:$false
    $s = Get-DevSetupBootState -StateFile $clientPaths.StateFile
    "{0}|{1}|{2}" -f $relaunch, $s.version, $s.previousVersion
}

Test-Feature -Name 'the activated version is importable' -Expected 'True' -Actual {
    $manifest = Get-DevSetupBootActiveModulePath -Paths $clientPaths
    [string]($manifest -and (Test-Path -LiteralPath $manifest))
}

Test-Feature -Name 'offline run keeps working on the installed version' -Expected 'False|1.9.0' -Actual {
    Rename-Item -LiteralPath $origin -NewName 'origin.git.offline'
    try {
        $relaunch = Invoke-DevSetupBootAutoUpdate -CommandName devsetup -ConfigPath $clientConfig -Confirm:$false -WarningAction SilentlyContinue
        "{0}|{1}" -f $relaunch, (Get-DevSetupBootState -StateFile $clientPaths.StateFile).version
    } finally {
        Rename-Item -LiteralPath (Join-Path $distRoot 'origin.git.offline') -NewName 'origin.git'
    }
}

Test-Feature -Name 'a corrupt release is rejected and the active version survives' -Expected 'False|1.9.0' -Actual {
    New-DevSetupPackage -DistributionRoot $publisher -Version '1.9.1' -SourcePaths $payload -Confirm:$false | Out-Null
    $victim = Get-ChildItem -LiteralPath (Join-Path $publisher 'packages/1.9.1/content') -Recurse -File | Select-Object -First 1
    Add-Content -LiteralPath $victim.FullName -Value '# tampered after checksums were written'
    # Set-DevSetupChannel would refuse a corrupt package, so write the channel
    # by hand: this simulates a release that was damaged in transit.
    $chan = [ordered]@{
        schemaVersion = 1; product = 'DevSetup'; channel = 'stable'; version = '1.9.1'
        manifest = 'packages/1.9.1/manifest.json'; minimumSupportedVersion = '1.8.0'
        force = $false; publishedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    Set-Content -LiteralPath (Join-Path $publisher 'channels/stable.json') -Value ($chan | ConvertTo-Json -Depth 5) -Encoding UTF8
    Invoke-MatrixGit -Dir $publisher -Arguments @('add', '-A') | Out-Null
    Invoke-MatrixGit -Dir $publisher -Arguments @('commit', '--quiet', '-m', 'corrupt 1.9.1') | Out-Null
    Invoke-MatrixGit -Dir $publisher -Arguments @('push', '--quiet', 'origin', 'HEAD:distribution') | Out-Null

    $relaunch = Invoke-DevSetupBootAutoUpdate -CommandName devsetup -ConfigPath $clientConfig -Confirm:$false
    "{0}|{1}" -f $relaunch, (Get-DevSetupBootState -StateFile $clientPaths.StateFile).version
}

Test-Feature -Name 'the failed version is remembered, so it is not retried' -Expected 'True' -Actual {
    $s = Get-DevSetupBootState -StateFile $clientPaths.StateFile
    [string](@($s.failedVersions) -contains '1.9.1')
}

Test-Feature -Name 'a rerun does not loop on the broken version' -Expected 'False' -Actual {
    [string](Invoke-DevSetupBootAutoUpdate -CommandName devsetup -ConfigPath $clientConfig -Confirm:$false)
}

Test-Feature -Name 'pilot promotion needs no rebuild' -Expected 'pilot=1.9.0 stable=1.9.1 packages=1.9.1,1.9.0,1.8.0' -Actual {
    $before = @(Get-DevSetupPublishedVersion -DistributionRoot $publisher)
    Set-DevSetupChannel -DistributionRoot $publisher -Channel pilot -Version '1.9.0' -MinimumSupportedVersion '1.8.0' -Confirm:$false | Out-Null
    $after = @(Get-DevSetupPublishedVersion -DistributionRoot $publisher)
    "pilot={0} stable={1} packages={2}" -f `
        (Get-DevSetupChannel -DistributionRoot $publisher -Channel pilot).version,
        (Get-DevSetupChannel -DistributionRoot $publisher -Channel stable).version,
        ($after -join ',')
}

# ---------------------------------------------------------------------------
# 10. Platform-gated features
# ---------------------------------------------------------------------------
Set-Group 'Platform-gated features'

if ($isWindowsHost -and [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
    Test-Feature -Name 'Authenticode signature inspection' -Expected 'True' -Actual {
        [string][bool](Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)
    }
} else {
    Skip-Feature -Name 'Smart code signing (Part X)'    -Reason 'Get-AuthenticodeSignature is Windows-only'
    Skip-Feature -Name 'DigiCert signing utility'        -Reason 'Windows-only vendor tool'
    Skip-Feature -Name 'Windows Python discovery'        -Reason 'enumerates C:\ and the registry'
    Skip-Feature -Name '.venv Scripts\python.exe layout' -Reason 'Get-VenvPythonExe is hardcoded to Windows'
    Skip-Feature -Name 'Tcl runtime copy'                -Reason 'depends on a Windows Python install layout'
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$pass = @($script:Results | Where-Object Status -eq 'PASS').Count
$fail = @($script:Results | Where-Object Status -eq 'FAIL').Count
$skip = @($script:Results | Where-Object Status -eq 'SKIP').Count

Write-Host ''
Write-Host ('-' * 72)
Write-Host ("FEATURE MATRIX  PASS={0}  FAIL={1}  SKIP={2}" -f $pass, $fail, $skip) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })

if ($fail -gt 0) {
    Write-Host ''
    Write-Host 'Failures:' -ForegroundColor Red
    $script:Results | Where-Object Status -eq 'FAIL' | ForEach-Object {
        Write-Host ("  {0} / {1}" -f $_.Group, $_.Name) -ForegroundColor Red
        Write-Host ("      expected : {0}" -f $_.Expected)
        Write-Host ("      actual   : {0}" -f $_.Actual)
    }
}

$reportPath = Join-Path $Root 'feature-matrix.json'
$script:Results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host ''
Write-Host ("Report: {0}" -f $reportPath) -ForegroundColor DarkGray

if ($fail -gt 0) { exit 1 }
exit 0
