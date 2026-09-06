#Requires -Version 5.1
<#
.SYNOPSIS
    Module loader for PythonVenvAutomation.

.DESCRIPTION
    Loads the central command-name configuration, dot-sources every private and
    public function, and makes the existing setup engine (Start-Setup) available
    internally. Uses $PSScriptRoot throughout so the module imports correctly
    from any working directory.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Absolute module root, used by helpers to locate templates/, config/, engine/.
$Script:PythonVenvAutomationModuleRoot = $PSScriptRoot

# ---------------------------------------------------------------------------
# 1. Central command-name configuration (must load first - other code reads it).
# ---------------------------------------------------------------------------
$configFile = Join-Path $PSScriptRoot 'config\CommandName.ps1'
if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    throw "PythonVenvAutomation: missing command-name config at $configFile"
}
. $configFile

# ---------------------------------------------------------------------------
# 2. Dot-source all private functions, then all public functions.
#    Private first so public functions can call them at load time if needed.
# ---------------------------------------------------------------------------
$privateDir = Join-Path $PSScriptRoot 'Private'
$publicDir  = Join-Path $PSScriptRoot 'Public'

foreach ($dir in @($privateDir, $publicDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File |
        Sort-Object Name |
        ForEach-Object {
            . $_.FullName
        }
}

# ---------------------------------------------------------------------------
# 3. Locate and import the existing setup engine so Start-Setup is available
#    internally. The engine is searched in two locations:
#      a) bundled inside the packaged module (engine\Setup-Core.psm1), and
#      b) the source-tree location (..\scripts4PythonAutomation\Setup-Core.psm1).
#    build\Build.ps1 copies the engine into engine\ so the published package is
#    self-contained; in-repo development uses the source-tree copy.
# ---------------------------------------------------------------------------
$Script:PythonVenvAutomationEngineLoaded = $false
$engineCandidates = @(
    (Join-Path $PSScriptRoot 'engine\Setup-Core.psm1'),
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts4PythonAutomation\Setup-Core.psm1')
)
foreach ($engine in $engineCandidates) {
    if (Test-Path -LiteralPath $engine -PathType Leaf) {
        try {
            Microsoft.PowerShell.Core\Import-Module -FullyQualifiedName $engine -Force -DisableNameChecking -Global -ErrorAction Stop
            $Script:PythonVenvAutomationEnginePath = $engine
            $Script:PythonVenvAutomationEngineLoaded = $true
            break
        } catch {
            # The engine is Windows-only; on other hosts (or a partial checkout)
            # it may fail to load. Record the path attempted but keep the module
            # importable so command-name/install/self-update features still work.
            $Script:PythonVenvAutomationEnginePath = $engine
            Write-Verbose ("PythonVenvAutomation: setup engine could not be loaded: {0}" -f $_.Exception.Message)
        }
    }
}
# A missing engine is not a hard load failure: command-name, install, and
# self-update features must still work (and unit tests run cross-platform
# without the Windows-only engine). Invoke-PythonVenvSetup raises a clear
# error if the engine is genuinely needed but absent.

Export-ModuleMember -Function @(
    'Invoke-PythonVenvSetup',
    'Install-DevSetupCommand',
    'Update-PythonVenvAutomation',
    'Get-PythonVenvSetupInfo',
    'Invoke-DevSetupDoctor',
    'Invoke-DevSetupRepairCommand',
    'Get-DevSetupAbout',
    'New-DevSetupSupport'
)
