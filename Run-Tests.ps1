#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(0,100)]
    [int] $MinimumCoverage = 70,

    [switch] $NoCoverage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot

$pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -or $pester.Version.Major -lt 5) {
    throw 'Pester 5 or newer is required. Install-Module Pester -Scope CurrentUser -Force'
}
Import-Module Pester -MinimumVersion 5.0 -Force

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $repoRoot 'tests'
$config.Run.PassThru = $true
$config.Run.Exit = $false
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = Join-Path $repoRoot 'test-results.xml'
$config.TestResult.OutputFormat = 'NUnitXml'

if (-not $NoCoverage) {
    $config.CodeCoverage.Enabled = $true
    $config.CodeCoverage.CoveragePercentTarget = $MinimumCoverage

    # Coverage gate intentionally targets deterministic core logic. Native/OS
    # integration modules such as GitSync, CodeSigning and SetupSteps are tested
    # with focused mocked behavior tests, but Pester's line instrumentation is
    # not representative for their external-process-heavy execution paths.
    $config.CodeCoverage.Path = @(
        (Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\Constants.psm1'),
        (Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\Errors.psm1'),
        (Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\Logging.psm1'),
        (Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\Config.psm1'),
        (Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\Detection.psm1'),
        (Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\SetupPipeline.psm1'),
        (Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\Versioning.psm1'),
        (Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\TomlParser.psm1'),
        (Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\PyProjectHealth.psm1'),
        (Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\Redaction.psm1'),
        (Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\SupportCodes.psm1'),
        (Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\Diagnostics.psm1')
    )
    $config.CodeCoverage.OutputPath = Join-Path $repoRoot 'coverage.xml'
    $config.CodeCoverage.OutputFormat = 'JaCoCo'
}

$result = Invoke-Pester -Configuration $config

$failedContainers = if ($result.PSObject.Properties.Name -contains 'FailedContainersCount') { [int]$result.FailedContainersCount } else { 0 }
$failedBlocks = if ($result.PSObject.Properties.Name -contains 'FailedBlocksCount') { [int]$result.FailedBlocksCount } else { 0 }
if ($result.FailedCount -gt 0 -or $failedContainers -gt 0 -or $failedBlocks -gt 0) {
    throw ("Pester failed: tests={0}, containers={1}, blocks={2}." -f $result.FailedCount, $failedContainers, $failedBlocks)
}

if (-not $NoCoverage -and $result.CodeCoverage) {
    $coverage = [double]$result.CodeCoverage.CoveragePercent
    Write-Host ("Deterministic core code coverage: {0:N2}%" -f $coverage)
    if ($coverage -lt $MinimumCoverage) {
        throw ("Coverage {0:N2}% is below the required {1}% for deterministic core logic." -f $coverage, $MinimumCoverage)
    }
}

Write-Host ("All tests passed. Total={0}; Passed={1}; Failed={2}" -f $result.TotalCount, $result.PassedCount, $result.FailedCount) -ForegroundColor Green

# Invoke-Pester can leave a non-zero native process exit code even when
# Run.Exit is disabled. Normalize success for CI after our explicit checks.
$global:LASTEXITCODE = 0
exit 0
