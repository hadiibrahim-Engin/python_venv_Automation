#Requires -Version 5.1
<#
.SYNOPSIS
    Validation entry point for CI and local checks.

.DESCRIPTION
    Performs (in order):
      1. PowerShell syntax validation of every .ps1/.psm1/.psd1 in the module,
         build, install, and tests trees.
      2. Test-ModuleManifest.
      3. Imports the module and verifies the public command surface.
      4. Verifies the command-name configuration and that generated shim names +
         help text use the configured command name.
      5. Runs the Pester test suite (which mocks the engine - the real Python
         setup pipeline is never executed).

    Never runs Start-Setup against a real project.
#>
[CmdletBinding()]
param(
    [switch] $SkipPester
)

$ErrorActionPreference = 'Stop'
$repoRoot   = Split-Path -Parent $PSScriptRoot
$moduleName = 'PythonVenvAutomation'
$manifest   = Join-Path $repoRoot "$moduleName\$moduleName.psd1"

$failures = New-Object System.Collections.Generic.List[string]

# 1. Syntax validation.
Write-Host '== Syntax validation ==' -ForegroundColor Cyan
$scanDirs = @(
    (Join-Path $repoRoot $moduleName),
    (Join-Path $repoRoot 'build'),
    (Join-Path $repoRoot 'tests')
)
$scanFiles = @()
foreach ($d in $scanDirs) {
    if (Test-Path -LiteralPath $d) {
# Only PowerShell sources (incl. the .ps1.template shim) - not the .cmd template.
        $scanFiles += Get-ChildItem -Path $d -Recurse -Include '*.ps1', '*.psm1', '*.psd1', '*.ps1.template' -File
    }
}
$scanFiles += Get-Item (Join-Path $repoRoot 'install.ps1') -ErrorAction SilentlyContinue
foreach ($f in ($scanFiles | Where-Object { $_ })) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) { $failures.Add("Syntax: $($f.Name): $($e.Message)") }
    }
}
Write-Host ("  Parsed {0} files." -f ($scanFiles | Where-Object { $_ }).Count)

# 2. Manifest.
Write-Host '== Test-ModuleManifest ==' -ForegroundColor Cyan
try { $null = Test-ModuleManifest -Path $manifest; Write-Host '  Manifest OK.' }
catch { $failures.Add("Manifest: $($_.Exception.Message)") }

# 3. Import + public surface.
Write-Host '== Import + public commands ==' -ForegroundColor Cyan
Import-Module $manifest -Force
$expected = @('Invoke-PythonVenvSetup', 'Install-DevSetupCommand', 'Update-PythonVenvAutomation', 'Get-PythonVenvSetupInfo')
foreach ($cmd in $expected) {
    if (-not (Get-Command $cmd -Module $moduleName -ErrorAction SilentlyContinue)) {
        $failures.Add("Missing exported command: $cmd")
    }
}
# Private helpers must NOT be exported.
if (Get-Command 'Get-DevSetupCommandName' -Module $moduleName -ErrorAction SilentlyContinue) {
    $failures.Add('Private helper Get-DevSetupCommandName is exported but should not be.')
}

# 4. Command-name config wiring.
Write-Host '== Command-name configuration ==' -ForegroundColor Cyan
$name = & (Get-Module $moduleName) { Get-DevSetupCommandName }
if ($name -ne 'devsetup') { $failures.Add("Default command name expected 'devsetup' but got '$name'.") }
$help = & (Get-Module $moduleName) { Write-DevSetupHelp }
if ($help -notmatch [regex]::Escape("$name -")) { $failures.Add('Help text does not use the configured command name.') }

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host '== FAILURES ==' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    throw "Validation failed with $($failures.Count) error(s)."
}
Write-Host 'Static validation passed.' -ForegroundColor Green

# 5. Pester suite (mock-based; no real pipeline).
if (-not $SkipPester) {
    $pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pester) {
        Write-Warning 'Pester is not installed; skipping the Pester suite. Install with: Install-Module Pester -Scope CurrentUser'
    } else {
        Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
        $config = New-PesterConfiguration
        $config.Run.Path = (Join-Path $repoRoot 'tests')
        $config.Run.Exit = $true
        $config.Output.Verbosity = 'Detailed'
        Invoke-Pester -Configuration $config
    }
}

Write-Host ''
Write-Host 'All validation completed.' -ForegroundColor Green
