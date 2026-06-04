function Save-DevSetupRuntimeConfig {
    <#
    .SYNOPSIS
        Writes the runtime config JSON under %LOCALAPPDATA%, merging over defaults.

    .DESCRIPTION
        Persists the lightweight config consumed by the generated shim. Any keys
        omitted from -Config keep their current/default value, so callers can
        update a single field (for example CommandName after a rename) without
        rewriting the whole file.

    .PARAMETER Config
        Hashtable of config values to persist/merge.

    .PARAMETER Path
        Optional explicit config path (used by tests).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Config,

        [string] $Path
    )

    if (-not $Path) { $Path = Get-DevSetupRuntimeConfigPath }

    # Start from current/default values so partial updates are non-destructive.
    $merged = Get-DevSetupRuntimeConfig -Path $Path
    foreach ($key in $Config.Keys) {
        $merged[$key] = $Config[$key]
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = ([pscustomobject]$merged | ConvertTo-Json -Depth 6)
    if ($PSCmdlet.ShouldProcess($Path, 'Write runtime config')) {
        Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
    }
    return $Path
}
