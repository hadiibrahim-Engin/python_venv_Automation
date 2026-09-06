#Requires -Version 5.1
# =============================================================================
# Module  : Prechecks.psm1
# Purpose : Pre-setup diagnostics using centralized defaults.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Constants.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop

function Test-NetworkAccess {
<#
.SYNOPSIS
    Verifies that at least one relevant network endpoint is reachable via TCP.

.EXAMPLE
    Test-NetworkAccess
#>
    [CmdletBinding()]
    param(
        [hashtable[]] $Endpoints = @(
            @{ Host = 'pypi.org'; Port = 443 },
            @{ Host = 'files.pythonhosted.org'; Port = 443 },
            @{ Host = 'www.python.org'; Port = 443 }
        ),
        [int] $TimeoutMs = 0
    )

    if ($TimeoutMs -le 0) {
        $TimeoutMs = [int](Get-SetupConstants).Network.ProbeTimeoutMs
    }

    $probes = foreach ($ep in $Endpoints) {
        $label = "$($ep.Host):$($ep.Port)"
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar = $tcp.BeginConnect($ep.Host, $ep.Port, $null, $null)
            [pscustomobject]@{ Label=$label; Tcp=$tcp; Ar=$ar; Done=$false }
        } catch {
            [pscustomobject]@{ Label=$label; Tcp=$null; Ar=$null; Done=$true }
        }
    }

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $reachable = @()
    $unreachable = @()
    foreach ($probe in $probes) {
        if ($probe.Done) { $unreachable += $probe.Label; continue }
        $remaining = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $ok = $probe.Ar.AsyncWaitHandle.WaitOne($remaining, $false)
        try { $probe.Tcp.Close() } catch { }
        if ($ok) { $reachable += $probe.Label } else { $unreachable += $probe.Label }
    }

    $passed = ($reachable.Count -gt 0)
    [pscustomobject]@{
        Check = 'Network'
        Passed = $passed
        Critical = $false
        Message = if ($passed) { "Network OK. Reached: $($reachable -join ', ')" } else { "No internet endpoints reachable. Tried: $($unreachable -join ', ')" }
        Fix = if (-not $passed) { 'Check proxy / firewall settings. VPN may be required.' } else { $null }
        AutoFix = if (-not $passed) { { param($ctx) $ctx.NetworkAvailable = $false } } else { $null }
    }
}

function Test-DigiCertAvailable {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string] $DigiCertExe)

    if (Test-Path -LiteralPath $DigiCertExe -PathType Leaf) {
        return [pscustomobject]@{ Check='DigiCert'; Passed=$true; Critical=$true; Message="DigiCert utility found: $DigiCertExe"; Fix=$null; AutoFix=$null }
    }

    [pscustomobject]@{
        Check = 'DigiCert'
        Passed = $false
        Critical = $true
        Message = "DigiCert utility NOT found at: $DigiCertExe"
        Fix = 'Install DigiCert Utility or set DIGICERT_UTILITY_EXE / -DigiCertUtilityExe.'
        AutoFix = $null
    }
}

function Invoke-Prechecks {
<#
.SYNOPSIS
    Runs network and required DigiCert prechecks.

.EXAMPLE
    Invoke-Prechecks -DigiCertExe $env:DIGICERT_UTILITY_EXE -NonInteractive
#>
    [CmdletBinding()]
    param(
        [bool] $EnableCodeSigning = $true,
        [string] $DigiCertExe = '',
        [bool] $NonInteractive = $false,
        [hashtable] $Ctx = @{},
        [bool] $StopOnNonCritical = $false,
        [bool] $ReportOnly = $false
    )

    if (-not $DigiCertExe) {
        $constants = Get-SetupConstants
        $DigiCertExe = if ($env:DIGICERT_UTILITY_EXE) { $env:DIGICERT_UTILITY_EXE } else { [string]$constants.CodeSigning.DefaultDigiCertUtilityExe }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $results.Add((Test-NetworkAccess))
    $results.Add((Test-DigiCertAvailable -DigiCertExe $DigiCertExe))

    $failed = @($results | Where-Object { -not $_.Passed })
    $allPassed = ($failed.Count -eq 0)
    $continueSetup = $allPassed

    if (-not $allPassed) {
        Write-Host ''
        Write-Host ('+{0}+' -f ('-' * 78)) -ForegroundColor Yellow
        Write-Host '|  [PRECHECK]  The following checks failed before setup started:' -ForegroundColor Yellow
        Write-Host ('+{0}+' -f ('-' * 78)) -ForegroundColor Yellow

        foreach ($r in $failed) {
            $criticalFlag = if ($r.PSObject.Properties.Name -contains 'Critical') { $r.Critical } else { $true }
            $label = if ($criticalFlag) { '[CRITICAL]' } else { '[WARN]    ' }
            $color = if ($criticalFlag) { 'Red' } else { 'Yellow' }
            Write-Host ("  $label  {0}" -f $r.Check) -ForegroundColor $color
            Write-Host ("            {0}" -f $r.Message) -ForegroundColor DarkGray
            if ($r.Fix) { Write-Host ("  [FIX]      {0}" -f $r.Fix) -ForegroundColor Cyan }
        }

        $nonCritical = @($failed | Where-Object { $_.PSObject.Properties.Name -contains 'Critical' -and -not $_.Critical })
        $critical = @($failed | Where-Object { -not ($_.PSObject.Properties.Name -contains 'Critical') -or $_.Critical })

        foreach ($r in $nonCritical) {
            if ($r.AutoFix) { & $r.AutoFix $Ctx }
        }

        if ($critical.Count -gt 0) {
            $continueSetup = $false
            if ($ReportOnly) { Write-Host '  Report only: real setup would abort here.' -ForegroundColor Yellow }
            elseif ($NonInteractive) { Write-Host ("  Setup will abort: {0} critical precheck(s) failed." -f $critical.Count) -ForegroundColor Red }
            else { Write-Host '  Setup will abort. Resolve the critical precheck failure and re-run setup.' -ForegroundColor Red }
        } elseif ($StopOnNonCritical) {
            $continueSetup = $false
            Write-Host '  Setup will stop because strict non-critical precheck handling is enabled.' -ForegroundColor Yellow
        } else {
            $continueSetup = $true
            Write-Host '  Non-critical failures were applied to context. Continuing setup.' -ForegroundColor DarkYellow
        }
    }

    [pscustomobject]@{ AllPassed=$allPassed; ContinueSetup=$continueSetup; Results=$results }
}

Export-ModuleMember -Function Test-NetworkAccess, Test-DigiCertAvailable, Invoke-Prechecks
