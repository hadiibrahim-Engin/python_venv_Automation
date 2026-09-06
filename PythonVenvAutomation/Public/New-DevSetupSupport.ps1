function New-DevSetupSupport {
<#
.SYNOPSIS
    Creates a redacted support bundle for the current project.

.DESCRIPTION
    Every file written into the archive is passed through the central
    redaction layer first, so tokens, passwords and credential URLs never
    leave the machine.

.EXAMPLE
    New-DevSetupSupport
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][ValidateScript({ -not $_ -or (Test-Path -LiteralPath $_ -PathType Container) })][string] $ProjectRoot,
        [Parameter()][string] $OutputDirectory,
        [Parameter()][switch] $PassThru
    )

    Set-StrictMode -Version Latest
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }
    if (-not $OutputDirectory) { $OutputDirectory = $ProjectRoot }

    Assert-DevSetupEngine -Feature 'devsetup support'

    $info = $null
    try { $info = Get-PythonVenvSetupInfo } catch { $info = $null }

    $params = @{
        ProjectRoot     = $ProjectRoot
        OutputDirectory = $OutputDirectory
        DevSetupInfo    = $info
        WhatIf          = [bool]$WhatIfPreference
    }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $params.Confirm = [bool]$PSBoundParameters['Confirm'] }

    $bundle = New-DevSetupSupportBundle @params
    if ($PassThru) { return $bundle }

    Write-Host ''
    if ($bundle.Created) {
        Write-Host 'Support-Paket erstellt:'
        Write-Host ('  {0}' -f $bundle.ZipPath)
        Write-Host ''
        Write-Host 'Es enthaelt keine Kennwoerter, Tokens oder Zugangsdaten.'
    } else {
        Write-Host 'Es wurde kein Support-Paket erstellt.'
    }
    Write-Host ''
    return $null
}
