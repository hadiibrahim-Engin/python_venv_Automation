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
    $config.CodeCoverage.Path = @(
        (Join-Path $repoRoot 'PythonVenvAutomation\Public\*.ps1'),
        (Join-Path $repoRoot 'PythonVenvAutomation\Private\*.ps1'),
        (Join-Path $repoRoot 'scripts4PythonAutomation\SetupCore\modules\*.psm1')
    )
    $config.CodeCoverage.OutputPath = Join-Path $repoRoot 'coverage.xml'
    $config.CodeCoverage.OutputFormat = 'JaCoCo'
}

$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0) {
    throw ("Pester failed: {0} test(s) failed." -f $result.FailedCount)
}

if (-not $NoCoverage -and $result.CodeCoverage) {
    $coverage = [double]$result.CodeCoverage.CoveragePercent
    Write-Host ("Core code coverage: {0:N2}%" -f $coverage)
    if ($coverage -lt $MinimumCoverage) {
        throw ("Coverage {0:N2}% is below the required {1}%." -f $coverage, $MinimumCoverage)
    }
}

Write-Host ("All tests passed. Total={0}; Passed={1}; Failed={2}" -f $result.TotalCount, $result.PassedCount, $result.FailedCount) -ForegroundColor Green
