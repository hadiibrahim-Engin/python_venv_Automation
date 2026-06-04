function Get-DevSetupCommandName {
    <#
    .SYNOPSIS
        Returns the configured user-facing command name (default: devsetup).

    .DESCRIPTION
        Single accessor for the command name defined in config\CommandName.ps1.
        All code (shim generation, help text, installer output, PATH wiring,
        runtime config, tests) must call this instead of hardcoding 'devsetup',
        so renaming the command requires editing only config\CommandName.ps1.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not (Get-Variable -Name 'DevSetupCommandName' -Scope Script -ErrorAction SilentlyContinue)) {
        # Defensive fallback if the config was not dot-sourced for some reason.
        return 'devsetup'
    }

    $name = $Script:DevSetupCommandName
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "DevSetup command name is not configured. Set `$Script:DevSetupCommandName in config\CommandName.ps1."
    }
    return $name.Trim()
}
