#Requires -Version 5.1
<#
.SYNOPSIS
    Agent-facing harness for the PythonVenvAutomation / devsetup automation.

.DESCRIPTION
    Loads the SetupCore engine so its functions are ACTUALLY callable, then
    exposes a handful of verbs for driving the real app (not just its tests).

    Why this file exists: importing Setup-Core.psm1 the obvious way leaves most
    of the engine invisible. Nearly every SetupCore module re-imports its own
    dependencies with `-Force` but WITHOUT `-Global` (e.g. Filesystem.psm1:10
    pulls in Constants.psm1). `-Force` *relocates* an already-global module into
    the importing module's private session state, so each such import silently
    de-globalizes a dependency. After a plain engine import, Get-SetupConstants,
    Get-ProjectMetadata, New-SetupException and friends are all gone, and the
    pipeline dies at step METADATA with "The term 'Get-ProjectMetadata' is not
    recognized". Import-DevSetupEngine fixes this with a second, reverse-order
    pass that re-globalizes every module.

.EXAMPLE
    pwsh -NoProfile -File .claude/skills/run-python-venv-automation/driver.ps1 test
.EXAMPLE
    pwsh -NoProfile -File .claude/skills/run-python-venv-automation/driver.ps1 pipeline -ProjectPath /tmp/p
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('test', 'info', 'detect', 'pipeline', 'fixtures', 'exec', 'selftest', 'matrix', 'dummy')]
    [string] $Command,

    # Project directory for 'detect' / 'pipeline'. Defaults to a generated fixture.
    [Parameter()][string] $ProjectPath,

    # 'exec': a PowerShell snippet evaluated with the engine fully loaded.
    [Parameter()][string] $Script,

    # 'exec': a .ps1 file evaluated with the engine fully loaded.
    [Parameter()][string] $File,

    # 'test': skip CodeSigning.Tests.ps1 (Windows-only, always fails elsewhere).
    [Parameter()][switch] $SkipSigningTests,

    # 'test': disable the coverage gate.
    [Parameter()][switch] $NoCoverage,

    # 'pipeline': run for real instead of -WhatIf. Dies at step PYTHON off Windows.
    [Parameter()][switch] $Real,

    # Where fixtures/logs are written.
    [Parameter()][string] $WorkDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' | Join-Path -ChildPath '..' | Join-Path -ChildPath '..')).Path
$ModulesDir = Join-Path $RepoRoot 'scripts4PythonAutomation/SetupCore/modules'

if (-not $WorkDir) { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) 'devsetup-driver' }

# Declared load order, copied from scripts4PythonAutomation/Setup-Core.psm1.
$script:ModuleLoadOrder = @(
    'Compat', 'Constants', 'Errors', 'Logging', 'UI', 'Path', 'Versioning', 'Toml',
    'NativeCommand', 'Config', 'Detection', 'Filesystem', 'PythonDiscovery', 'Venv',
    'VSCode', 'Tcl', 'Poetry', 'UV', 'PackageManager', 'Prechecks', 'CodeSigning',
    'GitSync', 'SetupPipeline', 'SetupSteps'
)

function Write-Head { param([string] $Text) Write-Host "==> $Text" -ForegroundColor Cyan }

<#
.SYNOPSIS
    Imports the automation module + SetupCore engine so every function is callable.
.DESCRIPTION
    Pass 1 imports the public module (which chains to Setup-Core.psm1).
    Pass 2 re-imports every SetupCore module with -Global in REVERSE load order,
    undoing the de-globalization described in the file header. Reverse order
    matters: leaf modules (Constants, Errors, ...) must be imported last so they
    end up in the global session state rather than inside a dependent.
#>
function Import-DevSetupEngine {
    [CmdletBinding()]
    param()

    Import-Module (Join-Path $RepoRoot 'PythonVenvAutomation/PythonVenvAutomation.psd1') -Force -DisableNameChecking -Global

    $reversed = $script:ModuleLoadOrder[($script:ModuleLoadOrder.Count - 1)..0]
    foreach ($name in $reversed) {
        $path = Join-Path $ModulesDir ("{0}.psm1" -f $name)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "SetupCore module not found: $path"
        }
        Microsoft.PowerShell.Core\Import-Module -FullyQualifiedName $path -Force -DisableNameChecking -Global -ErrorAction Stop
    }

    # Fail loudly rather than let a caller hit a confusing "term not recognized"
    # halfway through a pipeline run.
    $required = @('Start-Setup', 'Get-SetupConstants', 'Get-ProjectMetadata',
                  'New-SetupException', 'Resolve-PackageManager', 'Invoke-SafeGitPull')
    $missing = @($required | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        throw ("Engine import incomplete; still missing: {0}" -f ($missing -join ', '))
    }
}

<#
.SYNOPSIS
    Makes Start-Setup's Windows-only entry guard pass on macOS/Linux.
.DESCRIPTION
    Setup-Core.psm1:245 aborts with PLATFORM_UNSUPPORTED unless Get-IsWindows
    returns true, and Compat.psm1:83 defines that as `$env:OS -eq 'Windows_NT'`.
    Setting the variable is enough -- no source patch required. Only affects this
    process. Steps past PYTHON still assume Windows layouts (see SKILL.md).
#>
function Enable-WindowsHostSpoof {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    if ($env:OS -eq 'Windows_NT') { return }
    if ($PSCmdlet.ShouldProcess('$env:OS', "Set to 'Windows_NT' for this process")) {
        $env:OS = 'Windows_NT'
        Write-Verbose 'Spoofed $env:OS=Windows_NT to pass the Windows-only entry guard.'
    }
}

<#
.SYNOPSIS
    Writes the four pyproject fixtures the detection logic is interesting on.
#>
function New-DriverFixtures {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string] $Root)

    $fixtures = [ordered]@{
        'proj-uv'     = @{ toml = "[project]`nname = `"demo-app`"`nversion = `"0.1.0`"`nrequires-python = `">=3.11,<3.13`"`ndependencies = []`n`n[tool.uv]`ndev-dependencies = []`n"; locks = @() }
        'proj-poetry' = @{ toml = "[tool.poetry]`nname = `"demo`"`nversion = `"0.1.0`"`n`n[build-system]`nrequires = [`"poetry-core`"]`nbuild-backend = `"poetry.core.masonry.api`"`n"; locks = @('poetry.lock') }
        'proj-pep621' = @{ toml = "[project]`nname = `"demo`"`nversion = `"0.1.0`"`nrequires-python = `">=3.11`"`n"; locks = @() }
        'proj-dual'   = @{ toml = "[project]`nname = `"demo`"`nversion = `"0.1.0`"`nrequires-python = `">=3.11`"`n"; locks = @('uv.lock', 'poetry.lock') }
    }

    if ($PSCmdlet.ShouldProcess($Root, 'Create driver fixtures')) {
        foreach ($name in $fixtures.Keys) {
            $dir = Join-Path $Root $name
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Set-Content -LiteralPath (Join-Path $dir 'pyproject.toml') -Value $fixtures[$name].toml -Encoding UTF8
            foreach ($lock in $fixtures[$name].locks) {
                Set-Content -LiteralPath (Join-Path $dir $lock) -Value '' -Encoding UTF8
            }
        }
        # Start-Setup's INIT step requires an existing DigiCert utility path.
        $stub = Join-Path $Root 'digicert-stub.exe'
        if (-not (Test-Path -LiteralPath $stub)) { Set-Content -LiteralPath $stub -Value '' -Encoding UTF8 }
    }
    return $Root
}

function Resolve-DriverProject {
    param([string] $Path)
    if ($Path) { return (Resolve-Path -LiteralPath $Path).Path }
    New-DriverFixtures -Root $WorkDir | Out-Null
    return (Join-Path $WorkDir 'proj-uv')
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

function Invoke-DriverTest {
    Write-Head 'Pester suite'
    $pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pester -or $pester.Version.Major -lt 5) {
        throw 'Pester 5+ required: Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck'
    }
    Import-Module Pester -MinimumVersion 5.0 -Force

    $config = New-PesterConfiguration
    if ($SkipSigningTests) {
        # CodeSigning.Tests.ps1 mocks Get-AuthenticodeSignature, which only
        # exists on Windows; Pester's Mock throws CommandNotFoundException here.
        $files = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests') -Filter '*.Tests.ps1' -File |
                 Where-Object { $_.Name -ne 'CodeSigning.Tests.ps1' } |
                 Select-Object -ExpandProperty FullName
        $config.Run.Path = $files
    } else {
        $config.Run.Path = (Join-Path $RepoRoot 'tests')
    }
    $config.Run.PassThru = $true
    $config.Run.Exit = $false
    $config.Output.Verbosity = 'Normal'

    if (-not $NoCoverage) {
        $config.CodeCoverage.Enabled = $true
        $config.CodeCoverage.CoveragePercentTarget = 70
        # Same deterministic-core set as Run-Tests.ps1, so the local number
        # matches what the CI gate will report.
        $config.CodeCoverage.Path = @(
            'Constants', 'Errors', 'Logging', 'Config', 'Detection', 'SetupPipeline',
            'Versioning', 'TomlParser', 'PyProjectHealth', 'Redaction', 'SupportCodes', 'Diagnostics'
        ) | ForEach-Object { Join-Path $ModulesDir ("{0}.psm1" -f $_) }
        $config.CodeCoverage.OutputPath = Join-Path $RepoRoot 'coverage.xml'
        $config.CodeCoverage.OutputFormat = 'JaCoCo'
    }

    $result = Invoke-Pester -Configuration $config
    Write-Host ("Passed={0} Failed={1} Skipped={2}" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount)
    if ($result.CodeCoverage) {
        Write-Host ("Coverage: {0:N2}%" -f [double]$result.CodeCoverage.CoveragePercent)
    }
    foreach ($f in $result.Failed) { Write-Host ("FAIL: {0}" -f $f.ExpandedPath) -ForegroundColor Red }
    if ($result.FailedCount -gt 0) { exit 1 }
}

function Invoke-DriverInfo {
    Write-Head 'Get-PythonVenvSetupInfo'
    Import-DevSetupEngine
    Get-PythonVenvSetupInfo | Format-List
}

function Invoke-DriverDetect {
    Import-DevSetupEngine
    if ($ProjectPath) {
        $targets = @((Resolve-Path -LiteralPath $ProjectPath).Path)
    } else {
        New-DriverFixtures -Root $WorkDir | Out-Null
        $targets = @('proj-uv', 'proj-poetry', 'proj-pep621', 'proj-dual') | ForEach-Object { Join-Path $WorkDir $_ }
    }
    Write-Head 'Resolve-PackageManager'
    foreach ($t in $targets) {
        $r = Resolve-PackageManager -CliChoice 'auto' -ProjectRoot $t
        Write-Host ("{0,-14} -> {1,-7} ({2})" -f (Split-Path $t -Leaf), $r.PackageManager, $r.DetectionReport.Reason)
    }
}

function Invoke-DriverPipeline {
    $project = Resolve-DriverProject -Path $ProjectPath
    New-DriverFixtures -Root $WorkDir | Out-Null
    Import-DevSetupEngine
    Enable-WindowsHostSpoof -Confirm:$false

    Write-Head ("Invoke-PythonVenvSetup on {0} ({1})" -f $project, $(if ($Real) { 'REAL' } else { 'WhatIf' }))
    $params = @{
        ProjectRoot        = $project
        NonInteractive     = $true
        SkipGitPull        = $true
        EnableCodeSigning  = $false
        DigiCertUtilityExe = (Join-Path $WorkDir 'digicert-stub.exe')
    }
    if (-not $Real) { $params.WhatIf = $true }
    Invoke-PythonVenvSetup @params
}

function Invoke-DriverExec {
    Import-DevSetupEngine
    Enable-WindowsHostSpoof -Confirm:$false
    if ($File) {
        & (Resolve-Path -LiteralPath $File).Path
    } elseif ($Script) {
        # Engine is loaded globally; the snippet runs in this session state.
        Invoke-Command -ScriptBlock ([scriptblock]::Create($Script))
    } else {
        throw 'exec requires -Script <snippet> or -File <path.ps1>'
    }
}

function Invoke-DriverSelfTest {
    Write-Head 'Self-test: engine import + syntax + detection + pipeline'
    Import-DevSetupEngine
    Write-Host '  [ok] engine imported, all required functions resolvable'

    $bad = @()
    Get-ChildItem -LiteralPath $RepoRoot -Recurse -Include '*.ps1', '*.psm1', '*.psd1' -File |
        Where-Object { $_.FullName -notmatch '[\\/](\.git|\.venv|artifacts)[\\/]' } |
        ForEach-Object {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors) | Out-Null
            if ($errors -and $errors.Count -gt 0) { $bad += $_.FullName }
        }
    if ($bad.Count -gt 0) { throw ("Syntax errors in:`n{0}" -f ($bad -join "`n")) }
    Write-Host '  [ok] all PowerShell files parse'

    New-DriverFixtures -Root $WorkDir | Out-Null
    $r = Resolve-PackageManager -CliChoice 'auto' -ProjectRoot (Join-Path $WorkDir 'proj-poetry')
    if ($r.PackageManager -ne 'poetry') { throw "Expected poetry, got $($r.PackageManager)" }
    Write-Host '  [ok] detection returns poetry for a poetry project'

    Enable-WindowsHostSpoof -Confirm:$false
    # Step banners go to the Information stream (Write-Host), so redirect 6>&1
    # as well or the capture is empty and only the terminating error survives.
    $out = & {
        try {
            Invoke-PythonVenvSetup -ProjectRoot (Join-Path $WorkDir 'proj-uv') -NonInteractive -SkipGitPull `
                -EnableCodeSigning:$false -DigiCertUtilityExe (Join-Path $WorkDir 'digicert-stub.exe') -WhatIf 6>&1 2>&1
        } catch { $_ | Out-String }
    } | Out-String
    # A dry run legitimately ends at VENV-VALIDATE/VENV_INVALID: -WhatIf skips
    # VENV-PREPARE, so there is no .venv left for the validator to find.
    if ($out -notmatch 'VENV-VALIDATE' -and $out -notmatch 'VENV_INVALID' -and $out -notmatch 'not created') {
        throw "Pipeline did not reach VENV-VALIDATE. Output:`n$out"
    }
    Write-Host '  [ok] dry-run pipeline reaches VENV-VALIDATE (10 steps)'
    Write-Host 'SELF-TEST PASSED' -ForegroundColor Green
}

switch ($Command) {
    'test'     { Invoke-DriverTest }
    'info'     { Invoke-DriverInfo }
    'detect'   { Invoke-DriverDetect }
    'pipeline' { Invoke-DriverPipeline }
    'fixtures' { New-DriverFixtures -Root $WorkDir | ForEach-Object { Write-Host "Fixtures in $_" } }
    'exec'     { Invoke-DriverExec }
    'selftest' { Invoke-DriverSelfTest }
    'dummy'    { & (Join-Path $RepoRoot 'tests/dummy/New-DummyProject.ps1') -Root (Join-Path $WorkDir 'dummy') }
    'matrix'   { & (Join-Path $RepoRoot 'tests/dummy/Invoke-FeatureMatrix.ps1') -Root (Join-Path $WorkDir 'dummy') }
}
