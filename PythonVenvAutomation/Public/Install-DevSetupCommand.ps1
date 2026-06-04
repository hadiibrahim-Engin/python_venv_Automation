function Install-DevSetupCommand {
    <#
    .SYNOPSIS
        Installs the global command shims for the configured command name.

    .DESCRIPTION
        Generates <CommandName>.ps1 / <CommandName>.cmd and the bootstrap helper
        into a user-local bin directory, writes the runtime config, and adds the
        bin directory to the current user's PATH (idempotently). Requires no admin
        rights. The generated command name always comes from Get-DevSetupCommandName,
        even though this function's own name contains 'DevSetup'.

    .PARAMETER Force
        Overwrite existing shims/bootstrap.

    .PARAMETER RepositoryName
        PowerShell repository name to record in runtime config.

    .PARAMETER RepositoryUri
        Repository URI to record in runtime config.

    .PARAMETER AutoUpdatePolicy
        LatestStable | MinimumRequired | Pinned | Disabled.

    .PARAMETER RequiredVersion
        Target version for MinimumRequired / Pinned policies.

    .PARAMETER DisableAutoUpdate
        Convenience switch: sets AutoUpdateEnabled=false and policy=Disabled.

    .OUTPUTS
        PSCustomObject describing the installed command (paths + command name).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch] $Force,
        [string] $RepositoryName,
        [string] $RepositoryUri,
        [ValidateSet('LatestStable', 'MinimumRequired', 'Pinned', 'Disabled')]
        [string] $AutoUpdatePolicy,
        [string] $RequiredVersion,
        [switch] $DisableAutoUpdate
    )

    $commandName = Get-DevSetupCommandName
    $binDir      = Get-DevSetupBinDirectory -Create

    # 1. Generate the shims + bootstrap.
    $shims = New-DevSetupShim -BinDirectory $binDir -CommandName $commandName -Force:$Force

    # 2. Compose and write the runtime config (next to bin, under the vendor root).
    $configValues = @{ CommandName = $commandName }
    if ($PSBoundParameters.ContainsKey('RepositoryName'))   { $configValues.RepositoryName = $RepositoryName }
    if ($PSBoundParameters.ContainsKey('RepositoryUri'))    { $configValues.RepositoryUri  = $RepositoryUri }
    if ($PSBoundParameters.ContainsKey('AutoUpdatePolicy')) { $configValues.AutoUpdatePolicy = $AutoUpdatePolicy }
    if ($PSBoundParameters.ContainsKey('RequiredVersion'))  { $configValues.RequiredVersion  = $RequiredVersion }
    if ($DisableAutoUpdate) {
        $configValues.AutoUpdateEnabled = $false
        $configValues.AutoUpdatePolicy  = 'Disabled'
    }
    $configPath = Save-DevSetupRuntimeConfig -Config $configValues

    # 3. Add bin to the current-user PATH (idempotent) + the live process PATH.
    Add-DevSetupBinToPath -BinDirectory $binDir

    # 4. Success message using the configured command name.
    if (-not $WhatIfPreference) {
        Write-Host ''
        Write-Host 'Installation complete.'
        Write-Host ''
        Write-Host 'Open a new PowerShell or CMD window and run:'
        Write-Host ''
        Write-Host ("  {0}" -f $commandName)
        Write-Host ''
    }

    return [pscustomobject]@{
        CommandName   = $commandName
        BinDirectory  = $binDir
        PsShimPath    = $shims.PsShimPath
        CmdShimPath   = $shims.CmdShimPath
        BootstrapPath = $shims.BootstrapPath
        ConfigPath    = $configPath
    }
}

function Add-DevSetupBinToPath {
    <#
    .SYNOPSIS
        Adds the bin directory to the current user's persistent PATH and to the
        live process PATH. Idempotent - never duplicates an existing entry.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $BinDirectory
    )

    $normalized = $BinDirectory.TrimEnd('\', '/')

    # Persist to the User PATH on Windows. On non-Windows hosts (unit testing)
    # the [Environment] User target is unavailable, so only the process PATH is
    # updated - which is all the tests need.
    $isWindows = ($env:OS -eq 'Windows_NT') -or ($PSVersionTable.PSObject.Properties['Platform'] -and $PSVersionTable.Platform -eq 'Win32NT')
    if ($isWindows) {
        $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
        $entries  = @()
        if ($userPath) { $entries = $userPath -split ';' | Where-Object { $_ } }
        $exists = $entries | Where-Object { $_.TrimEnd('\', '/') -ieq $normalized }
        if (-not $exists) {
            if ($PSCmdlet.ShouldProcess('User PATH', "Add $normalized")) {
                $newUserPath = if ($userPath) { ($userPath.TrimEnd(';') + ';' + $BinDirectory) } else { $BinDirectory }
                [System.Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
            }
        }
    }

    # Update the live process PATH so the command works in the current session.
    $sep = [System.IO.Path]::PathSeparator
    $procEntries = @()
    if ($env:Path) { $procEntries = $env:Path -split [regex]::Escape($sep) | Where-Object { $_ } }
    $procExists = $procEntries | Where-Object { $_.TrimEnd('\', '/') -ieq $normalized }
    if (-not $procExists) {
        if ($PSCmdlet.ShouldProcess('Process PATH', "Add $normalized")) {
            $env:Path = if ($env:Path) { ($env:Path.TrimEnd($sep) + $sep + $BinDirectory) } else { $BinDirectory }
        }
    }
}
