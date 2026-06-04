function Update-PythonVenvAutomation {
    <#
    .SYNOPSIS
        Manually updates the automation module and regenerates the command shims.

    .DESCRIPTION
        Backs the 'self-update' command. Forces an update check against the
        configured repository (honoring the policy, but never skipping just
        because AutoUpdateEnabled is false), regenerates the <CommandName>.ps1 /
        <CommandName>.cmd shims and bootstrap, rewrites runtime config, and prints
        the resulting installed version and configured command name.

    .PARAMETER SkipModuleUpdate
        Regenerate shims/config without contacting the repository (repair mode).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch] $SkipModuleUpdate
    )

    $commandName = Get-DevSetupCommandName
    $config = Get-DevSetupRuntimeConfig

    $result = $null
    if (-not $SkipModuleUpdate) {
        try {
            $result = Update-PythonVenvAutomationIfNeeded -Config $config -Force
        } catch {
            Write-Error ("Self-update failed: {0}" -f $_.Exception.Message)
            throw
        }
    }

    # Regenerate shims + bootstrap, and rewrite runtime config from the configured
    # command name so a rename propagates to the installed shims.
    if ($PSCmdlet.ShouldProcess('command shims', 'Regenerate')) {
        New-DevSetupShim -CommandName $commandName -Force | Out-Null
        Save-DevSetupRuntimeConfig -Config @{ CommandName = $commandName } | Out-Null
    }

    $installed = Get-InstalledPythonVenvAutomationVersion -ModuleName $config.ModuleName

    Write-Host ''
    if ($result -and $result.Updated) {
        Write-Host ("PythonVenvAutomation updated to {0}." -f $result.Target)
    } elseif (-not $SkipModuleUpdate) {
        Write-Host 'PythonVenvAutomation is already up to date.'
    }
    Write-Host ("Installed version : {0}" -f $(if ($installed) { $installed } else { '(none)' }))
    Write-Host ("Command name      : {0}" -f $commandName)

    return [pscustomobject]@{
        Updated          = [bool]($result -and $result.Updated)
        InstalledVersion = $installed
        CommandName      = $commandName
    }
}
