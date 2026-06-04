function Get-PythonVenvSetupInfo {
    <#
    .SYNOPSIS
        Returns diagnostic information about the installed automation command.

    .DESCRIPTION
        Reports the configured command name, module version, expected shim/config
        paths, engine availability, and the effective runtime config. Useful for
        troubleshooting an installation without running the setup pipeline.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $commandName = Get-DevSetupCommandName
    $binDir      = Get-DevSetupBinDirectory
    $config      = Get-DevSetupRuntimeConfig
    $installed   = Get-InstalledPythonVenvAutomationVersion -ModuleName $config.ModuleName

    return [pscustomobject]@{
        CommandName       = $commandName
        ModuleName        = $config.ModuleName
        InstalledVersion  = $installed
        EngineLoaded      = [bool]$Script:PythonVenvAutomationEngineLoaded
        EnginePath        = $Script:PythonVenvAutomationEnginePath
        BinDirectory      = $binDir
        PsShimPath        = (Join-Path $binDir ("{0}.ps1" -f $commandName))
        CmdShimPath       = (Join-Path $binDir ("{0}.cmd" -f $commandName))
        BootstrapPath     = (Join-Path $binDir 'DevSetup.Bootstrap.ps1')
        RuntimeConfigPath = (Get-DevSetupRuntimeConfigPath)
        RepositoryName    = $config.RepositoryName
        RepositoryUri     = $config.RepositoryUri
        AutoUpdateEnabled = $config.AutoUpdateEnabled
        AutoUpdatePolicy  = $config.AutoUpdatePolicy
        RequiredVersion   = $config.RequiredVersion
        ModuleRoot        = $Script:PythonVenvAutomationModuleRoot
    }
}
