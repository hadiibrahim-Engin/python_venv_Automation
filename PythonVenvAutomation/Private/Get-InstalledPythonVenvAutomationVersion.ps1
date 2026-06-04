function Get-InstalledPythonVenvAutomationVersion {
    <#
    .SYNOPSIS
        Returns the newest locally-installed version of the module, or $null.

    .PARAMETER ModuleName
        Module to inspect. Defaults to PythonVenvAutomation.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [string] $ModuleName = 'PythonVenvAutomation'
    )

    $found = Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($found) { return [version]$found.Version }
    return $null
}
