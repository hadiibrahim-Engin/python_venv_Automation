function Get-DevSetupInstallInfo {
<#
.SYNOPSIS
    Describes the installation this module is running from.

.DESCRIPTION
    A module activated by the bootstrap lives at

        <InstallRoot>\versions\<version>\PythonVenvAutomation

    so both the install root and the running version can be derived from the
    module's own location. That is authoritative: reading the version from
    Get-Module -ListAvailable would miss it entirely, because versioned
    installations are never registered in PSModulePath.

    Returns IsManaged = $false when the module is running from a source
    checkout instead of a managed installation.

.OUTPUTS
    PSCustomObject with IsManaged, InstallRoot, Version, BinDirectory,
    StateFile and ConfigPath.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][string] $ModuleRoot)

    if (-not $ModuleRoot) { $ModuleRoot = $Script:PythonVenvAutomationModuleRoot }

    $result = [pscustomobject]@{
        IsManaged    = $false
        InstallRoot  = $null
        Version      = $null
        BinDirectory = $null
        StateFile    = $null
        ConfigPath   = $null
    }
    if (-not $ModuleRoot) { return $result }

    $versionDir = Split-Path -Parent $ModuleRoot            # versions\<version>
    if (-not $versionDir) { return $result }
    $versionsDir = Split-Path -Parent $versionDir           # versions
    if (-not $versionsDir -or (Split-Path -Leaf $versionsDir) -ne 'versions') { return $result }

    $installRoot = Split-Path -Parent $versionsDir
    if (-not $installRoot) { return $result }

    $result.IsManaged    = $true
    $result.InstallRoot  = $installRoot
    $result.Version      = Split-Path -Leaf $versionDir
    $result.BinDirectory = Join-Path $installRoot 'bin'
    $result.StateFile    = Join-Path (Join-Path $installRoot 'state') 'current.json'
    $result.ConfigPath   = Join-Path $installRoot 'config.json'
    return $result
}
