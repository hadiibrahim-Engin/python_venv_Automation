function Get-DevSetupRuntimeConfig {
    <#
    .SYNOPSIS
        Loads the runtime config, applying defaults for any missing keys.

    .DESCRIPTION
        Reads %LOCALAPPDATA%\Company\PythonVenvAutomation\config.json and returns
        a hashtable. Missing or unreadable config yields the built-in defaults so
        the shim/self-update logic always has a complete, well-typed object.

    .PARAMETER Path
        Optional explicit config path (used by tests). Defaults to
        Get-DevSetupRuntimeConfigPath.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $Path
    )

    $defaults = [ordered]@{
        ModuleName           = 'PythonVenvAutomation'
        RepositoryName       = 'CompanyPS'
        RepositoryUri        = 'https://REPLACE_WITH_INTERNAL_NUGET_FEED/v3/index.json'
        CommandName          = (Get-DevSetupCommandName)
        AutoUpdateEnabled    = $true
        AutoUpdatePolicy     = 'LatestStable'
        RequiredVersion      = $null
        AllowPrerelease      = $false
        AllowOfflineContinue = $true
        UpdateTimeoutSeconds  = 15
    }

    if (-not $Path) { $Path = Get-DevSetupRuntimeConfigPath }

    $config = @{}
    foreach ($k in $defaults.Keys) { $config[$k] = $defaults[$k] }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
                foreach ($prop in $parsed.PSObject.Properties) {
                    $config[$prop.Name] = $prop.Value
                }
            }
        } catch {
            Write-Warning ("Could not parse runtime config at {0}: {1}. Using defaults." -f $Path, $_.Exception.Message)
        }
    }

    return $config
}
