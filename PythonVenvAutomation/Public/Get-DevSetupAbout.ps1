function Get-DevSetupAbout {
<#
.SYNOPSIS
    Version, channel, install path and project status in one object.

.DESCRIPTION
    Read-only. Intended for `devsetup about` and for pasting into a support
    request; every value is redacted before it is returned.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][ValidateScript({ -not $_ -or (Test-Path -LiteralPath $_ -PathType Container) })][string] $ProjectRoot,
        [Parameter()][switch] $PassThru
    )

    Set-StrictMode -Version Latest
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }

    $info = Get-PythonVenvSetupInfo
    $config = Get-DevSetupRuntimeConfig

    # A managed installation is authoritative for version, bin directory and
    # channel; the legacy PSModulePath-based values do not apply to it.
    $install = Get-DevSetupInstallInfo
    $installedVersion = $info.InstalledVersion
    $binDirectory     = $info.BinDirectory
    $channel          = $(if ($config.PSObject.Properties.Name -contains 'Channel' -and $config.Channel) { $config.Channel } else { 'stable' })

    if ($install.IsManaged) {
        $installedVersion = $install.Version
        $binDirectory     = $install.BinDirectory
        if (Test-Path -LiteralPath $install.ConfigPath -PathType Leaf) {
            try {
                $installConfig = Get-Content -LiteralPath $install.ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                if ($installConfig.PSObject.Properties.Name -contains 'Channel' -and $installConfig.Channel) {
                    $channel = [string]$installConfig.Channel
                }
            } catch {
                Write-Verbose ("about: install config unreadable: {0}" -f $_.Exception.Message)
            }
        }
    }

    $packageManager = 'unbekannt'
    $requiresPython = 'unbekannt'
    if ($Script:PythonVenvAutomationEngineLoaded) {
        try {
            Clear-PyProjectHealthCache
            $health = Get-PyProjectHealthReport -ProjectRoot $ProjectRoot -NoCache
            if ($health.PackageManager) { $packageManager = $health.PackageManager }
            if ($health.Metadata.RequiresPython) { $requiresPython = $health.Metadata.RequiresPython }
        } catch {
            Write-Verbose ("about: project inspection failed: {0}" -f $_.Exception.Message)
        }
    }

    $about = [pscustomobject]@{
        CommandName       = $info.CommandName
        InstalledVersion  = $(if ($installedVersion) { $installedVersion } else { 'Quellverzeichnis' })
        Installation      = $(if ($install.IsManaged) { $install.InstallRoot } else { 'nicht installiert (Quellcheckout)' })
        ModuleRoot        = $info.ModuleRoot
        BinDirectory      = $binDirectory
        Channel           = $channel
        AutoUpdateEnabled = $info.AutoUpdateEnabled
        AutoUpdatePolicy  = $info.AutoUpdatePolicy
        EngineLoaded      = $info.EngineLoaded
        ProjectRoot       = (Resolve-Path -LiteralPath $ProjectRoot).Path
        PackageManager    = $packageManager
        RequiresPython    = $requiresPython
        PowerShell        = $PSVersionTable.PSVersion.ToString()
        OS                = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim()
    }

    if ($Script:PythonVenvAutomationEngineLoaded) { $about = Protect-SecretObject -InputObject $about }
    if ($PassThru) { return $about }

    Write-Host ''
    Write-Host 'DevSetup'
    Write-Host ''
    foreach ($prop in $about.PSObject.Properties) {
        Write-Host ('  {0,-18} {1}' -f $prop.Name, $prop.Value)
    }
    Write-Host ''
    return $null
}
