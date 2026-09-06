function Invoke-DevSetupRepairCommand {
<#
.SYNOPSIS
    Applies only the repairs DevSetup considers safe.

.DESCRIPTION
    Findings classified NeedsDecision are never fixed automatically. In a
    non-interactive run they make the command fail so CI does not silently
    continue with an unresolved conflict.

.EXAMPLE
    Invoke-DevSetupRepairCommand -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][ValidateScript({ -not $_ -or (Test-Path -LiteralPath $_ -PathType Container) })][string] $ProjectRoot,
        [Parameter()][switch] $NonInteractive,
        [Parameter()][switch] $PassThru
    )

    Set-StrictMode -Version Latest
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }

    Assert-DevSetupEngine -Feature 'devsetup repair'

    $resolvedNonInteractive = [bool]$NonInteractive -or ($env:CI -match '^(1|true|yes|on)$')

    # ShouldProcess preferences do not cross module boundaries; forward them.
    $params = @{
        ProjectRoot    = $ProjectRoot
        NonInteractive = $resolvedNonInteractive
        WhatIf         = [bool]$WhatIfPreference
    }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $params.Confirm = [bool]$PSBoundParameters['Confirm'] }

    $result = Invoke-DevSetupRepair @params
    if ($PassThru) { return $result }

    if ($result.Changed) {
        Write-Host ''
        Write-Host ('Behoben: {0}' -f (($result.Applied | ForEach-Object Code) -join ', '))
        if ($result.BackupPath) { Write-Host ('Sicherung: {0}' -f $result.BackupPath) }
    } else {
        Write-Host ''
        Write-Host 'Es gab nichts sicher zu reparieren.'
    }

    if ($result.NeedsDecision.Count -gt 0) {
        Write-Host ''
        Write-Host 'Folgende Punkte benoetigen eine fachliche Entscheidung:'
        foreach ($f in $result.NeedsDecision) { Write-Host ('  - {0}' -f $f.Message) }
        if (-not $result.Succeeded) {
            throw (New-SetupException -Message 'Repair could not resolve every finding without a decision.' `
                -ErrorCode 'PYPROJECT_PM_AMBIGUOUS' -Step 'REPAIR' -Context @{ ProjectRoot = $ProjectRoot })
        }
    }
    Write-Host ''
    return $null
}
