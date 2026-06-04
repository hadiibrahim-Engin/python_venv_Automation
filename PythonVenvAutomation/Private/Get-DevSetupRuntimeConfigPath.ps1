function Get-DevSetupRuntimeConfigPath {
    <#
    .SYNOPSIS
        Returns the path to the runtime config JSON under %LOCALAPPDATA%.

    .DESCRIPTION
        Resolves to %LOCALAPPDATA%\Company\PythonVenvAutomation\config.json.
        This lightweight config is written by install.ps1 / Install-DevSetupCommand
        and read by the generated shim BEFORE importing the main module, so the
        auto-update check can run against the configured repository.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Join-Path (Get-DevSetupRootDirectory) 'config.json')
}

function Get-DevSetupUpdateLockPath {
    <#
    .SYNOPSIS
        Returns the path to the update lock file used to serialize concurrent
        auto-update attempts across multiple terminals.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Join-Path (Get-DevSetupRootDirectory) 'update.lock')
}
