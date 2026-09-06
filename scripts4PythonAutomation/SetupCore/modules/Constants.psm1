#Requires -Version 5.1
# =============================================================================
# Module  : Constants.psm1
# Purpose : Central source for setup constants and formerly scattered magic values.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SetupConstants = [ordered]@{
    ConfigFileName = '.setup-config.json'

    PackageManagers = [ordered]@{
        Auto            = 'auto'
        Uv              = 'uv'
        Poetry          = 'poetry'
        PipRequirements = 'pip-requirements'
    }

    Git = [ordered]@{
        RemoteName            = 'origin'
        FetchTimeoutSeconds   = 10   # bounded remote call; avoids hanging setup on VPN/credential/network failures
        MaxTimeoutSeconds     = 120
        DefaultPullStrategy   = 'SkipIfDirty'
        AllowedPullStrategies = @('SkipIfDirty', 'ErrorIfDirty')
    }

    Network = [ordered]@{
        ProbeTimeoutMs = 3000 # probes run concurrently, so total precheck latency stays near 3s instead of N x 3s
    }

    Input = [ordered]@{
        MaxBooleanTextLength  = 10
        MaxStrategyTextLength = 32
        MaxInteractiveLength  = 1024
    }

    CodeSigning = [ordered]@{
        DefaultDigiCertUtilityExe = 'C:\Program Files\DigiCertUtility\DigiCertUtil.exe'
    }

    Retry = [ordered]@{
        MaxRetry         = 8   # historical robust-delete retry budget; with 700 ms delay this is roughly five seconds
        DelayMs          = 700
        CleanupMaxRetry  = 3   # stale directories are best-effort cleanup and should not block setup for long
        CleanupDelayMs   = 400
        QuarantineDelayS = 5   # give file handles time to close before background deletion retries
    }
}

function Get-SetupConstants {
<#
.SYNOPSIS
    Returns the centralized SetupCore constants.

.DESCRIPTION
    Returns a fresh object graph so consumers cannot alter module-scoped
    defaults for other callers in the same PowerShell session.

.EXAMPLE
    $constants = Get-SetupConstants
    $constants.Git.FetchTimeoutSeconds
#>
    [CmdletBinding()]
    param()

    $script:SetupConstants | ConvertTo-Json -Depth 6 | ConvertFrom-Json
}

Export-ModuleMember -Function Get-SetupConstants
