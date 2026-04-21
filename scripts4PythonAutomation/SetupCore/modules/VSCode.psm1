#Requires -Version 5.1
# =============================================================================
# Module  : VSCode.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    VS Code workspace configuration helpers.
#>

<#
.SYNOPSIS
    Writes python.defaultInterpreterPath into .vscode/settings.json.

.DESCRIPTION
    Ensures VS Code resolves the project-local interpreter at
    .venv\Scripts\python.exe using forward-slash path format.
    Existing keys in settings.json are preserved; only
    python.defaultInterpreterPath is updated.
#>
function Write-VSCodeInterpreterSetting {
    param(
        [Parameter(Mandatory=$true)][string] $VenvDir,
        [Parameter(Mandatory=$true)][string] $SettingsFile
    )
    $vscodeDir = [System.IO.Path]::GetFullPath((Split-Path $SettingsFile -Parent))
    if (-not (Test-Path -LiteralPath $vscodeDir -PathType Container)) {
        New-Item -ItemType Directory -Path $vscodeDir | Out-Null
    }
    # Normalize first, then convert to forward slashes for VS Code JSON storage
    $venvPython = ([System.IO.Path]::GetFullPath((Join-Path $VenvDir 'Scripts\python.exe'))) -replace '\\', '/'

    # Read existing settings and merge so we do not destroy other keys.
    $settings = [ordered]@{}
    if (Test-Path -LiteralPath $SettingsFile -PathType Leaf) {
        try {
            $existing = Get-Content $SettingsFile -Raw -ErrorAction Stop
            if ($existing) {
                $parsed = $existing | ConvertFrom-Json -ErrorAction Stop
                foreach ($prop in $parsed.PSObject.Properties) {
                    $settings[$prop.Name] = $prop.Value
                }
            }
        } catch {
            Write-Host ("  Warning: could not parse existing settings.json -- it will be overwritten. ({0})" -f $_.Exception.Message) -ForegroundColor DarkYellow
            $settings = [ordered]@{}
        }
    }

    $settings['python.defaultInterpreterPath'] = $venvPython
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsFile -Encoding UTF8
}