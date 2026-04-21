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
      "IncludeDev"          : true   | false,
      "_comment"            : "..."
    }
#>

$script:ConfigFileName = '.setup-config.json'

# ---------------------------------------------------------------------------
# Path helper
# ---------------------------------------------------------------------------
function Get-SetupConfigPath {
<#
.SYNOPSIS Returns the full path to .setup-config.json for a given project root.#>
    param([Parameter(Mandatory=$true)][string] $ProjectRoot)
    Join-Path $ProjectRoot $script:ConfigFileName
}


# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------
function Read-SetupConfig {
<#
.SYNOPSIS
    Reads .setup-config.json and returns its contents as a PSCustomObject,
    or $null when the file does not exist or is malformed.
#>
    param([Parameter(Mandatory=$true)][string] $ProjectRoot)

    $path = Get-SetupConfigPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path $path -PathType Leaf)) { return $null }

    try {
        $raw = Get-Content $path -Raw -Encoding UTF8 -ErrorAction Stop
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Host ("[WARN] [Config] Could not read {0}: {1}" -f $script:ConfigFileName, $_.Exception.Message) -ForegroundColor Yellow
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
    Reads .setup-config.json and fills in PinnedVersions and IncludeDev that
    were not explicitly supplied via CLI.

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

    # IncludeDev: only override when the caller left it at the default ($true)
    if ($config.PSObject.Properties.Name -contains 'IncludeDev' -and
        $null -ne $config.IncludeDev -and
        $Ctx.IncludeDev -eq $true) {
        $Ctx.IncludeDev = [bool]$config.IncludeDev
        $applied.Add(("include_dev={0}" -f $config.IncludeDev))
    }

    if ($applied.Count -gt 0) {
        Write-Host ("  [Config] Applying .setup-config.json: {0}" -f ($applied -join ', ')) -ForegroundColor DarkGray
    }
}


Export-ModuleMember -Function Get-SetupConfigPath, Read-SetupConfig, Write-SetupConfig, Merge-SetupConfig