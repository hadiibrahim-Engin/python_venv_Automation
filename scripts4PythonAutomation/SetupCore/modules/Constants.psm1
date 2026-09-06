#Requires -Version 5.1
# =============================================================================
# Module  : Constants.psm1
# Purpose : Central source for setup constants and formerly scattered magic values.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Keep this module data-only. Callers receive a copy so they cannot mutate the
# shared defaults accidentally during a setup run.
$script:SetupConstants = [ordered]@{
    ConfigFileName = '.setup-config.json'

    PackageManagers = [ordered]@{
        Auto   = 'auto'
        Uv     = 'uv'
        Poetry = 'poetry'
        PipRequirements = 'pip-requirements'
    }

    Git = [ordered]@{
        RemoteName          = 'origin'
        FetchTimeoutSeconds = 10  # bounded remote call; avoids hanging setup on VPN/credential/network failures
        MaxTimeoutSeconds   = 120
        DefaultPullStrategy = 'SkipIfDirty'
        AllowedPullStrategies = @('SkipIfDirty', 'ErrorIfDirty')
    }

    Input = [ordered]@{
        MaxBooleanTextLength = 10 # enough for true/false/yes/no/on/off while rejecting unexpectedly large input
        MaxStrategyTextLength = 32
    }

    CodeSigning = [ordered]@{
        DefaultDigiCertUtilityExe = 'C:\Program Files\DigiCertUtility\DigiCertUtil.exe'
    }

    Retry = [ordered]@{
        MaxRetry = 8   # historical retry budget; at ~700 ms backoff this is roughly five seconds of waiting
        DelayMs  = 700
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

    # JSON round-trip gives us a deep copy and is compatible with Windows
    # PowerShell 5.1, which this project still supports.
    $script:SetupConstants | ConvertTo-Json -Depth 6 | ConvertFrom-Json
}

Export-ModuleMember -Function Get-SetupConstants
