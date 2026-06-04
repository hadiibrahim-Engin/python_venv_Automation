#Requires -Version 5.1
<#
.SYNOPSIS
    Sets the module version in the single source of truth (VERSION) and keeps the
    manifest ModuleVersion in sync.

.DESCRIPTION
    Validates the requested version is semantic (X.Y.Z), writes the repo-root
    VERSION file, and updates PythonVenvAutomation.psd1. Optionally validates the
    version against a Git tag (vX.Y.Z) for release builds.

.EXAMPLE
    .\build\Update-Version.ps1 -Version 1.2.0
.EXAMPLE
    .\build\Update-Version.ps1 -Version 1.2.0 -ValidateGitTag v1.2.0
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $Version,
    [string] $ValidateGitTag
)

$ErrorActionPreference = 'Stop'
$repoRoot     = Split-Path -Parent $PSScriptRoot
$versionFile  = Join-Path $repoRoot 'VERSION'
$manifestPath = Join-Path $repoRoot 'PythonVenvAutomation\PythonVenvAutomation.psd1'

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version '$Version' is not valid semantic versioning (expected X.Y.Z)."
}

if ($ValidateGitTag) {
    $expected = "v$Version"
    if ($ValidateGitTag -ne $expected) {
        throw "Git tag '$ValidateGitTag' does not match version '$Version' (expected '$expected')."
    }
    Write-Host "Git tag '$ValidateGitTag' matches version '$Version'." -ForegroundColor Green
}

# VERSION file
if ($PSCmdlet.ShouldProcess($versionFile, "Set version $Version")) {
    Set-Content -LiteralPath $versionFile -Value $Version -NoNewline:$false -Encoding ASCII
}

# Manifest ModuleVersion
$manifestText = Get-Content -LiteralPath $manifestPath -Raw
$newText = [regex]::Replace($manifestText, "(?m)^(\s*ModuleVersion\s*=\s*')[^']+(')", "`${1}$Version`${2}")
if ($newText -eq $manifestText) {
    throw "Could not find ModuleVersion in $manifestPath to update."
}
if ($PSCmdlet.ShouldProcess($manifestPath, "Set ModuleVersion $Version")) {
    Set-Content -LiteralPath $manifestPath -Value $newText -Encoding UTF8
}

Write-Host "Version set to $Version (VERSION + manifest)." -ForegroundColor Green
