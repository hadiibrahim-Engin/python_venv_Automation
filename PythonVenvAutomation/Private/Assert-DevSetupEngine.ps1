function Assert-DevSetupEngine {
<#
.SYNOPSIS
    Fails with a clear message when the setup engine is not available.

.DESCRIPTION
    Several public commands need SetupCore. Without this guard the user would
    get "the term X is not recognized", which means nothing to them.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Feature)

    if ($Script:PythonVenvAutomationEngineLoaded) { return }
    throw ("'{0}' requires the DevSetup setup engine, which could not be loaded from '{1}'." -f `
        $Feature, $Script:PythonVenvAutomationEnginePath)
}
