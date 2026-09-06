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
        InstalledVersion  = $info.InstalledVersion
        ModuleRoot        = $info.ModuleRoot
        BinDirectory      = $info.BinDirectory
        Channel           = $(if ($config.PSObject.Properties.Name -contains 'Channel' -and $config.Channel) { $config.Channel } else { 'stable' })
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
