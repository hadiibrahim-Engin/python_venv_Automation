#Requires -Version 5.1
# =============================================================================
# Module  : Config.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Reads and writes the project-level setup preferences file (.setup-config.json).

.DESCRIPTION
    .setup-config.json lives in the project root and persists user preferences
    across setup runs.  It acts as a project-wide default layer:

        CLI params  >  .setup-config.json  >  auto-detection  >  built-in defaults

    The file is intentionally minimal - only settings that benefit from
    persistence are stored here.  Machine-specific settings (code signing,
    DigiCert path) stay CLI-only.

    Schema (all fields optional):
    {
      "PackageManager"      : "auto" | "uv" | "poetry",
      "PinnedPoetryVersion" : null   | "1.8.3",
      "PinnedUvVersion"     : null   | "0.6.14",
      "_comment"            : "..."
    }
#>

$script:ConfigFileName = '.setup-config.json'

# Module-level read cache.
# Read-SetupConfig is called twice per setup run (once in Resolve-PackageManager,
# once in Merge-SetupConfig — both inside the same DETECT step).  The cache
# ensures the file is only read from disk once.
# Call Clear-SetupConfigCache between test runs or after Write-SetupConfig.
$script:_configCache = @{}

# ---------------------------------------------------------------------------
# Path helper
# ---------------------------------------------------------------------------
function Get-SetupConfigPath {
<#
.SYNOPSIS Returns the full path to .setup-config.json for a given project root.#>
    param([Parameter(Mandatory=$true)][string] $ProjectRoot)
    Join-Path $ProjectRoot $script:ConfigFileName
}

function Clear-SetupConfigCache {
<#
.SYNOPSIS Clears the in-memory read cache. Call between test runs.#>
    $script:_configCache = @{}
}

# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------
function Read-SetupConfig {
<#
.SYNOPSIS
    Reads .setup-config.json and returns its contents as a PSCustomObject,
    or $null when the file does not exist or is malformed.
    Result is cached in memory so the file is only read once per module lifetime.
#>
    param([Parameter(Mandatory=$true)][string] $ProjectRoot)

    $key = $ProjectRoot.ToLowerInvariant()
    if ($script:_configCache.ContainsKey($key)) {
        return $script:_configCache[$key]
    }

    $path = Get-SetupConfigPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path $path -PathType Leaf)) {
        $script:_configCache[$key] = $null
        return $null
    }

    try {
        $raw    = Get-Content $path -Raw -Encoding UTF8 -ErrorAction Stop
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $script:_configCache[$key] = $parsed
        return $parsed
    } catch {
        Write-Host ("[WARN] [Config] Could not read {0}: {1}" -f $script:ConfigFileName, $_.Exception.Message) -ForegroundColor Yellow
        $script:_configCache[$key] = $null
        return $null
    }
}


# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------
function Write-SetupConfig {
<#
.SYNOPSIS
    Writes (or updates) .setup-config.json with the supplied key/value pairs.

.DESCRIPTION
    Merges $Values over the existing file content so that keys not present in
    $Values are preserved.  Creates the file if it does not exist yet.

.PARAMETER ProjectRoot
    Project directory.

.PARAMETER Values
    Hashtable of fields to write / update.

.EXAMPLE
    Write-SetupConfig -ProjectRoot $root -Values @{ PackageManager = 'uv' }
#>
    param(
        [Parameter(Mandatory=$true)][string] $ProjectRoot,
        [Parameter(Mandatory=$true)][hashtable] $Values
    )

    $path = Get-SetupConfigPath -ProjectRoot $ProjectRoot

    # Start from existing content (preserve unknown keys)
    $config = [ordered]@{}
    $existing = Read-SetupConfig -ProjectRoot $ProjectRoot
    if ($existing) {
        foreach ($prop in $existing.PSObject.Properties) {
            $config[$prop.Name] = $prop.Value
        }
    }

    # Apply the new values
    foreach ($key in $Values.Keys) {
        $config[$key] = $Values[$key]
    }

    # Always stamp with a _comment so users understand the file
    if (-not $config.Contains('_comment')) {
        $config['_comment'] = 'Auto-managed by setup-core.ps1. Edit to override setup defaults.'
    }

    try {
        $config | ConvertTo-Json -Depth 3 | Set-Content $path -Encoding UTF8 -ErrorAction Stop
        # Invalidate the read cache so the next Read-SetupConfig call sees the new content.
        $script:_configCache.Remove($ProjectRoot.ToLowerInvariant())
    } catch {
        Write-Host ("[WARN] [Config] Could not write {0}: {1}" -f $script:ConfigFileName, $_.Exception.Message) -ForegroundColor Yellow
    }
}


# ---------------------------------------------------------------------------
# Apply to context
# ---------------------------------------------------------------------------
function Merge-SetupConfig {
<#
.SYNOPSIS
    Applies non-PM config-file preferences to a setup context hashtable.

.DESCRIPTION
    Reads .setup-config.json and fills in pinned tool versions that were not
    explicitly supplied via CLI. Dependency scope is intentionally CLI-only so
    one production-only run cannot surprise later developer setups.

    PackageManager is intentionally NOT handled here — PM resolution is the
    sole responsibility of Resolve-PackageManager (PackageManager.psm1), which
    reads the config file independently as part of its priority chain.

.OUTPUTS
    Nothing. Mutates $Ctx in place.
#>
    param(
        [Parameter(Mandatory=$true)][string]    $ProjectRoot,
        [Parameter(Mandatory=$true)][hashtable] $Ctx
    )

    $config = Read-SetupConfig -ProjectRoot $ProjectRoot
    if (-not $config) { return }

    $applied = [System.Collections.Generic.List[string]]::new()

    # PinnedVersions: fill if not already set by the caller
    foreach ($key in @('PinnedPoetryVersion', 'PinnedUvVersion')) {
        if (-not $Ctx[$key] -and
            $config.PSObject.Properties.Name -contains $key -and
            $config.$key) {
            $Ctx[$key] = $config.$key
            $applied.Add(("{0}={1}" -f $key, $config.$key))
        }
    }

    if ($applied.Count -gt 0) {
        Write-Host ("  [Config] Applying .setup-config.json: {0}" -f ($applied -join ', ')) -ForegroundColor DarkGray
    }
}


Export-ModuleMember -Function Get-SetupConfigPath, Read-SetupConfig, Write-SetupConfig, Merge-SetupConfig, Clear-SetupConfigCache
