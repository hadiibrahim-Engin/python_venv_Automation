function Invoke-DevSetupDoctor {
<#
.SYNOPSIS
    Read-only diagnosis of DevSetup and the current project.

.DESCRIPTION
    Guaranteed not to modify anything: it deliberately does not declare
    SupportsShouldProcess because it never takes an action that would need it.

.PARAMETER ProjectRoot
    Project to inspect. Defaults to the current directory.

.PARAMETER Detailed
    Also show checks that were skipped and the detail of healthy checks.

.PARAMETER PassThru
    Return the report object instead of printing the short user output.

.EXAMPLE
    Invoke-DevSetupDoctor
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][ValidateScript({ -not $_ -or (Test-Path -LiteralPath $_ -PathType Container) })][string] $ProjectRoot,
        [Parameter()][switch] $Detailed,
        [Parameter()][switch] $PassThru
    )

    Set-StrictMode -Version Latest
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }

    Assert-DevSetupEngine -Feature 'devsetup doctor'

    $info = $null
    try { $info = Get-PythonVenvSetupInfo } catch { $info = $null }

    $report = Get-DevSetupDoctorReport -ProjectRoot $ProjectRoot -DevSetupInfo $info
    if ($PassThru) { return $report }

    Write-Host (Format-DevSetupDoctorReport -Report $report -Detailed:$Detailed)
    return $null
}
