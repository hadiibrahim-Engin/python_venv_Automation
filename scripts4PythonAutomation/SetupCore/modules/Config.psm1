#Requires -Version 5.1
# =============================================================================
# Module  : Config.psm1
# Purpose : Project-local setup configuration with fail-safe persistence.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ConfigFileName = '.setup-config.json'
$script:_configCache = @{}

function Get-SetupConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string] $ProjectRoot
    )
    Join-Path $ProjectRoot $script:ConfigFileName
}

function Clear-SetupConfigCache {
    [CmdletBinding()]
    param()
    $script:_configCache = @{}
}

function Read-SetupConfig {
<#
.SYNOPSIS
    Reads .setup-config.json and returns a cached PSCustomObject.

.EXAMPLE
    $cfg = Read-SetupConfig -ProjectRoot $PWD.Path
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string] $ProjectRoot
    )

    $key = ([System.IO.Path]::GetFullPath($ProjectRoot)).ToLowerInvariant()
    if ($script:_configCache.ContainsKey($key)) { return $script:_configCache[$key] }

    $path = Get-SetupConfigPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $script:_configCache[$key] = $null
        return $null
    }

    try {
        $parsed = (Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
        $script:_configCache[$key] = $parsed
        return $parsed
    }
    catch {
        Write-Warning ("[Config] Could not read {0}: {1}" -f $script:ConfigFileName, $_.Exception.Message)
        $script:_configCache[$key] = $null
        return $null
    }
}

function Write-SetupConfig {
<#
.SYNOPSIS
    Writes or updates .setup-config.json.

.DESCRIPTION
    Persistence failures are never silently ignored. In non-interactive/CI mode
    the function throws so the pipeline fails. In interactive mode, the user is
    explicitly asked whether setup may continue without saving configuration.

.PARAMETER NonInteractive
    When true, write failures throw immediately.

.EXAMPLE
    Write-SetupConfig -ProjectRoot $root -Values @{ PackageManager='uv' }

.EXAMPLE
    Write-SetupConfig -ProjectRoot $root -Values $values -NonInteractive
#>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string] $ProjectRoot,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [hashtable] $Values,

        [Parameter()]
        [switch] $NonInteractive
    )

    $path = Get-SetupConfigPath -ProjectRoot $ProjectRoot
    $config = [ordered]@{}
    $existing = Read-SetupConfig -ProjectRoot $ProjectRoot
    if ($existing) {
        foreach ($prop in $existing.PSObject.Properties) { $config[$prop.Name] = $prop.Value }
    }
    foreach ($key in $Values.Keys) { $config[$key] = $Values[$key] }
    if (-not $config.Contains('_comment')) {
        $config['_comment'] = 'Auto-managed by setup-core.ps1. Edit to override setup defaults.'
    }

    if (-not $PSCmdlet.ShouldProcess($path, 'Write setup configuration')) { return $false }

    try {
        $json = $config | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath $path -Value $json -Encoding UTF8 -ErrorAction Stop
        $script:_configCache.Remove(([System.IO.Path]::GetFullPath($ProjectRoot)).ToLowerInvariant())
        return $true
    }
    catch {
        $message = "Could not persist $script:ConfigFileName: $($_.Exception.Message)"
        $isCi = ($env:CI -match '^(1|true|yes)$')
        if ($NonInteractive -or $isCi) {
            throw $message
        }

        Write-Warning $message
        $answer = Read-Host 'Continue setup without saving configuration? [y/N]'
        $normalized = if ($answer) { $answer.Trim().ToLowerInvariant() } else { '' }
        if ($normalized -in @('y','yes')) {
            Write-Warning 'Continuing without persisted setup configuration.'
            return $false
        }
        throw "$message User declined to continue without persistence."
    }
}

function Merge-SetupConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string] $ProjectRoot,
        [Parameter(Mandatory=$true)][ValidateNotNull()][hashtable] $Ctx
    )

    $config = Read-SetupConfig -ProjectRoot $ProjectRoot
    if (-not $config) { return }

    $applied = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @('PinnedPoetryVersion','PinnedUvVersion')) {
        if (-not $Ctx[$key] -and $config.PSObject.Properties.Name -contains $key -and $config.$key) {
            $Ctx[$key] = $config.$key
            $applied.Add(("{0}={1}" -f $key, $config.$key))
        }
    }
    if ($applied.Count -gt 0) {
        Write-Host ("  [Config] Applying .setup-config.json: {0}" -f ($applied -join ', ')) -ForegroundColor DarkGray
    }
}

Export-ModuleMember -Function Get-SetupConfigPath, Read-SetupConfig, Write-SetupConfig, Merge-SetupConfig, Clear-SetupConfigCache
