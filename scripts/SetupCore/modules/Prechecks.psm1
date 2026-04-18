#Requires -Version 5.1
# =============================================================================
# Module  : Prechecks.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Pre-setup diagnostic checks run before the main pipeline starts.

.DESCRIPTION
    Each check returns a result object.  The orchestrator (Start-Setup) calls
    Invoke-Prechecks and decides whether to continue or abort based on the
    returned ContinueSetup flag.

    Non-critical failures (e.g. DigiCert missing) cause setup to auto-disable
    the affected feature rather than aborting outright.
#>


# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------

function Test-NetworkAccess {
<#
.SYNOPSIS
    Verifies that at least one relevant network endpoint is reachable via TCP.

.DESCRIPTION
    Attempts a TCP connection to each of the supplied host:port pairs.
    Returns a check result object - passes when at least one endpoint responds.
    Fails non-critically: setup continues but a warning is shown and any steps
    that require internet access receive an early, clear diagnosis.

.PARAMETER Endpoints
    Array of hashtables, each with 'Host' and 'Port' keys.
    Defaults to PyPI and the UV / Poetry installer endpoints.

.PARAMETER TimeoutMs
    Per-endpoint TCP connect timeout in milliseconds. Default 3000.
#>
    param(
        [hashtable[]] $Endpoints = @(
            @{ Host = 'pypi.org';             Port = 443 },
            @{ Host = 'files.pythonhosted.org'; Port = 443 },
            @{ Host = 'astral.sh';            Port = 443 }   # uv installer
        ),
        [int] $TimeoutMs = 3000
    )

    # Phase 1 — fire all TCP connections before waiting on any.
    # This ensures the I/O overlaps; total wall-clock is bounded by TimeoutMs,
    # not N × TimeoutMs as with a sequential foreach.
    $probes = foreach ($ep in $Endpoints) {
        $label = "$($ep.Host):$($ep.Port)"
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar  = $tcp.BeginConnect($ep.Host, $ep.Port, $null, $null)
            [pscustomobject]@{ Label = $label; Tcp = $tcp; Ar = $ar; Ok = $false; Done = $false }
        } catch {
            [pscustomobject]@{ Label = $label; Tcp = $null; Ar = $null; Ok = $false; Done = $true }
        }
    }

    # Phase 2 — collect results against a shared deadline.
    $deadline    = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $reachable   = @()
    $unreachable = @()

    foreach ($probe in $probes) {
        if ($probe.Done) { $unreachable += $probe.Label; continue }   # failed to even start

        $remaining = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $ok        = $probe.Ar.AsyncWaitHandle.WaitOne($remaining, $false)
        try { $probe.Tcp.Close() } catch { }

        if ($ok) { $reachable   += $probe.Label }
        else      { $unreachable += $probe.Label }
    }

    $passed = ($reachable.Count -gt 0)
    $msg    = if ($passed) {
        "Network OK. Reached: $($reachable -join ', ')"
    } else {
        "No internet endpoints reachable. Tried: $($unreachable -join ', ')"
    }

    return [pscustomobject]@{
        Check    = 'Network'
        Passed   = $passed
        Critical = $false    # non-critical: setup continues; error surfaces at install step
        Message  = $msg
        Fix      = if (-not $passed) { 'Check proxy / firewall settings. VPN may be required.' } else { $null }
        AutoFix  = if (-not $passed) { { param($ctx) $ctx.NetworkAvailable = $false } } else { $null }
    }
}

function Test-DigiCertAvailable {
<#
.SYNOPSIS
    Verifies that the DigiCert utility executable exists at the expected path.

.OUTPUTS
    PSCustomObject { Check; Passed; Message; Fix; AutoFix }
    AutoFix is a scriptblock that callers may invoke to disable the feature
    gracefully instead of aborting.
#>
    param([Parameter(Mandatory=$true)][string] $DigiCertExe)

    if (Test-Path -LiteralPath $DigiCertExe -PathType Leaf) {
        return [pscustomobject]@{
            Check   = 'DigiCert'
            Passed  = $true
            Message = "DigiCert utility found: $DigiCertExe"
            Fix     = $null
            AutoFix = $null
        }
    }

    return [pscustomobject]@{
        Check   = 'DigiCert'
        Passed  = $false
        Critical = $false      # non-critical: setup can continue with signing disabled
        Message = "DigiCert utility NOT found at: $DigiCertExe"
        Fix     = "Install DigiCert Utility OR re-run setup with -EnableCodeSigning:`$false to skip signing."
        AutoFix = { param($ctx) $ctx.EnableCodeSigning = $false }
    }
}


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

function Invoke-Prechecks {
<#
.SYNOPSIS
    Runs all pre-setup checks and returns a consolidated result.

.DESCRIPTION
    Checks are evaluated in order.  Non-critical failures apply their AutoFix
    (e.g. disabling code signing) and continue.  Critical failures require
    explicit user confirmation (semi-auto) or cause an abort (autonomous).

.PARAMETER EnableCodeSigning
    When true, the DigiCert availability check is included.

.PARAMETER DigiCertExe
    Full path to DigiCertUtil.exe.

.PARAMETER NonInteractive
    When true (autonomous mode): non-critical failures apply AutoFix and
    continue; critical failures throw immediately.
    When false (semi-auto mode): the user is prompted on any failure.

.PARAMETER Ctx
    Reference to the setup context hashtable.  AutoFix scriptblocks receive
    this to disable features (e.g. ctx.EnableCodeSigning = $false).

.OUTPUTS
    PSCustomObject { AllPassed; ContinueSetup; Results }
#>
    param(
        [bool]     $EnableCodeSigning  = $true,
        [string]   $DigiCertExe        = 'C:\Program Files\DigiCertUtility\DigiCertUtil.exe',
        [bool]     $NonInteractive     = $false,
        [hashtable]$Ctx                = @{},
        # When $true (default), setup stops even on non-critical auto-fixed failures.
        # Pass $false to continue past non-critical failures (legacy behaviour).
        [bool]     $StopOnNonCritical  = $true
    )

    $results = [System.Collections.Generic.List[object]]::new()

    # --- Register checks ---
    # Network: always run so the user gets an early, clear failure if offline.
    $results.Add((Test-NetworkAccess))

    if ($EnableCodeSigning) {
        $results.Add((Test-DigiCertAvailable -DigiCertExe $DigiCertExe))
    }

    # --- Evaluate results ---
    $failed        = @($results | Where-Object { -not $_.Passed })
    $allPassed     = ($failed.Count -eq 0)
    $continueSetup = $allPassed

    if (-not $allPassed) {
        Write-Host ''
        Write-Host ('+{0}+' -f ('-' * 78)) -ForegroundColor Yellow
        Write-Host '|  [PRECHECK]  The following checks failed before setup started:' -ForegroundColor Yellow
        Write-Host ('+{0}+' -f ('-' * 78)) -ForegroundColor Yellow

        foreach ($r in $failed) {
            $critical = if ($r.PSObject.Properties.Name -contains 'Critical') { $r.Critical } else { $true }
            $label    = if ($critical) { '[CRITICAL]' } else { '[WARN]    ' }
            $color    = if ($critical) { 'Red' } else { 'Yellow' }
            Write-Host ("  $label  {0}" -f $r.Check)   -ForegroundColor $color
            Write-Host ("            {0}" -f $r.Message) -ForegroundColor DarkGray
            if ($r.Fix) {
                Write-Host ("  [FIX]      {0}" -f $r.Fix) -ForegroundColor Cyan
            }
        }
        Write-Host ''

        $nonCritical = @($failed | Where-Object { $_.PSObject.Properties.Name -contains 'Critical' -and -not $_.Critical })
        $critical    = @($failed | Where-Object { -not ($_.PSObject.Properties.Name -contains 'Critical') -or $_.Critical })

        # Apply AutoFix for all non-critical failures immediately
        foreach ($r in $nonCritical) {
            if ($r.AutoFix) {
                & $r.AutoFix $Ctx
                Write-Host ("  [AUTO-FIX] '{0}' feature auto-disabled." -f $r.Check) -ForegroundColor DarkYellow
            }
        }

        if ($critical.Count -gt 0) {
            # Critical failures - must abort or get explicit user confirmation
            if ($NonInteractive) {
                throw ("Setup aborted: {0} critical precheck(s) failed." -f $critical.Count)
            }
            $answer = (Read-Host '  Critical checks failed. Continue anyway? (yes / no)').Trim()
            $continueSetup = ($answer -ieq 'yes' -or $answer -ieq 'y')
            if (-not $continueSetup) {
                Write-Host '  Setup aborted by user.' -ForegroundColor Red
            }
        } else {
            # Only non-critical failures - auto-fixed above
            if ($StopOnNonCritical) {
                $continueSetup = $false
                Write-Host '  All failures were non-critical and have been auto-fixed.' -ForegroundColor DarkYellow
                Write-Host '  Setup will stop. Re-run with -ContinueOnPrecheckFailure to skip this guard.' -ForegroundColor Yellow
            } else {
                $continueSetup = $true
                Write-Host '  All failures were non-critical and have been auto-fixed. Continuing setup.' -ForegroundColor DarkYellow
            }
        }
    }

    [pscustomobject]@{
        AllPassed     = $allPassed
        ContinueSetup = $continueSetup
        Results       = $results
    }
}

Export-ModuleMember -Function Test-NetworkAccess, Test-DigiCertAvailable, Invoke-Prechecks
