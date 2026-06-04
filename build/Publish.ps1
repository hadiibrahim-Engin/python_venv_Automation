#Requires -Version 5.1
<#
.SYNOPSIS
    Publishes the built module package to a configurable NuGet-compatible feed.

.DESCRIPTION
    Backend-agnostic publisher. Works with Azure Artifacts, GitHub Packages, an
    internal NuGet feed, or a file-based repository - the backend is selected via
    -RepositoryName / -RepositoryUri, never via hardcoded values. Prefers
    PSResourceGet (Publish-PSResource) and falls back to PowerShellGet
    (Publish-Module). Fails clearly when credentials are required but missing,
    and never echoes the API key.

.NOTES
    Run build\Build.ps1 first so the staged module exists under artifacts/.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $RepositoryName,
    [Parameter(Mandatory)] [string] $RepositoryUri,
    [Parameter()]          [string] $ApiKey,
    [switch] $Prerelease
)

$ErrorActionPreference = 'Stop'
$repoRoot   = Split-Path -Parent $PSScriptRoot
$moduleName = 'PythonVenvAutomation'
$version    = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
$stageDir   = Join-Path (Join-Path (Join-Path $repoRoot 'artifacts') 'staging') (Join-Path $moduleName $version)

if (-not (Test-Path -LiteralPath $stageDir -PathType Container)) {
    throw "Staged module not found at $stageDir. Run build\Build.ps1 first."
}

# Most hosted NuGet feeds (Azure Artifacts, GitHub Packages) require auth on
# publish. Fail closed if no key is available rather than producing a confusing
# downstream 401.
if (-not $ApiKey -and $env:NUGET_API_KEY) { $ApiKey = $env:NUGET_API_KEY }
$looksHosted = $RepositoryUri -match '^https?://'
if ($looksHosted -and -not $ApiKey) {
    throw 'No API key supplied. Pass -ApiKey or set $env:NUGET_API_KEY (use a pipeline secret). Refusing to publish without credentials.'
}

$usePSResource = [bool](Get-Command 'Publish-PSResource' -ErrorAction SilentlyContinue)

# Register the target repository if it is not already known.
if ($usePSResource) {
    if (-not (Get-PSResourceRepository -Name $RepositoryName -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($RepositoryName, 'Register PSResource repository')) {
            Register-PSResourceRepository -Name $RepositoryName -Uri $RepositoryUri -Trusted -ErrorAction Stop
        }
    }
} else {
    if (-not (Get-PSRepository -Name $RepositoryName -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($RepositoryName, 'Register PSRepository')) {
            Register-PSRepository -Name $RepositoryName -SourceLocation $RepositoryUri -PublishLocation $RepositoryUri -InstallationPolicy Trusted -ErrorAction Stop
        }
    }
}

Write-Host "Publishing $moduleName $version to '$RepositoryName' ..." -ForegroundColor Cyan
# NOTE: the API key is passed by value only; it is never written to the log.
if ($PSCmdlet.ShouldProcess("$moduleName $version", "Publish to $RepositoryName")) {
    if ($usePSResource) {
        $p = @{ Path = $stageDir; Repository = $RepositoryName; ErrorAction = 'Stop' }
        if ($ApiKey) { $p['ApiKey'] = $ApiKey }
        Publish-PSResource @p
    } else {
        $p = @{ Path = $stageDir; Repository = $RepositoryName; ErrorAction = 'Stop' }
        if ($ApiKey) { $p['NuGetApiKey'] = $ApiKey }
        Publish-Module @p
    }
}

Write-Host "Published $moduleName $version." -ForegroundColor Green
