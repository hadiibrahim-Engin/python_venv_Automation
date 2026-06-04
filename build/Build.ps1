#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a self-contained, distributable package of the PythonVenvAutomation
    module into artifacts/.

.DESCRIPTION
    Steps:
      1. Clean previous build output.
      2. Stage the module into a versioned staging folder.
      3. Bundle the setup engine (scripts4PythonAutomation) under engine/ so the
         package is self-contained.
      4. Validate the module manifest.
      5. Validate that VERSION and the manifest ModuleVersion agree (build fails
         on mismatch).
      6. Produce a package: a NuGet .nupkg when packaging cmdlets are available,
         always plus a portable .zip.

    Output is written under artifacts/.
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot   = Split-Path -Parent $PSScriptRoot
$moduleName = 'PythonVenvAutomation'
$moduleDir  = Join-Path $repoRoot $moduleName
$manifest   = Join-Path $moduleDir "$moduleName.psd1"
$versionFile = Join-Path $repoRoot 'VERSION'
$engineSrc  = Join-Path $repoRoot 'scripts4PythonAutomation'

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'artifacts' }
$stagingRoot = Join-Path $OutputDirectory 'staging'

# 1. Clean.
if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

# 5a. Read + cross-check versions early (fail fast).
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) { throw "VERSION file not found: $versionFile" }
$version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION '$version' is not semantic (X.Y.Z)." }

$manifestData = Import-PowerShellDataFile -LiteralPath $manifest
$manifestVersion = "$($manifestData.ModuleVersion)"
if ($manifestVersion -ne $version) {
    throw "Version mismatch: VERSION='$version' but manifest ModuleVersion='$manifestVersion'. Run build\Update-Version.ps1 -Version $version."
}
Write-Host "Version check OK: $version" -ForegroundColor Green

# 2. Stage the module (module files only; exclude any pre-existing engine copy).
$stageModuleDir = Join-Path (Join-Path $stagingRoot $moduleName) $version
New-Item -ItemType Directory -Path $stageModuleDir -Force | Out-Null
Copy-Item -Path (Join-Path $moduleDir '*') -Destination $stageModuleDir -Recurse -Force -Exclude @('engine')

# 3. Bundle the engine so the package is self-contained.
$stageEngineDir = Join-Path $stageModuleDir 'engine'
New-Item -ItemType Directory -Path $stageEngineDir -Force | Out-Null
Copy-Item -Path (Join-Path $engineSrc 'Setup-Core.psm1') -Destination $stageEngineDir -Force
Copy-Item -Path (Join-Path $engineSrc 'SetupCore') -Destination $stageEngineDir -Recurse -Force
foreach ($extra in @('activate-venv.ps1', 'Get-SetupHelp.ps1')) {
    $src = Join-Path $engineSrc $extra
    if (Test-Path -LiteralPath $src -PathType Leaf) { Copy-Item -Path $src -Destination $stageEngineDir -Force }
}

# 4. Validate the staged manifest.
$stagedManifest = Join-Path $stageModuleDir "$moduleName.psd1"
$null = Test-ModuleManifest -Path $stagedManifest
Write-Host "Staged manifest validated." -ForegroundColor Green

# 6. Package: portable zip (always) + .nupkg (when tooling is available).
$zipPath = Join-Path $OutputDirectory "$moduleName-$version.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $stageModuleDir '*') -DestinationPath $zipPath -Force
Write-Host "Wrote $zipPath" -ForegroundColor Green

$nupkgMade = $false
try {
    $tempRepoName = "LocalBuild_$([guid]::NewGuid().ToString('N'))"
    $tempRepoPath = Join-Path $OutputDirectory 'nuget'
    New-Item -ItemType Directory -Path $tempRepoPath -Force | Out-Null

    if (Get-Command 'Publish-PSResource' -ErrorAction SilentlyContinue) {
        Register-PSResourceRepository -Name $tempRepoName -Uri $tempRepoPath -Trusted -ErrorAction Stop
        try {
            Publish-PSResource -Path $stageModuleDir -Repository $tempRepoName -ErrorAction Stop
            $nupkgMade = $true
        } finally {
            Unregister-PSResourceRepository -Name $tempRepoName -ErrorAction SilentlyContinue
        }
    } elseif (Get-Command 'Publish-Module' -ErrorAction SilentlyContinue) {
        Register-PSRepository -Name $tempRepoName -SourceLocation $tempRepoPath -PublishLocation $tempRepoPath -InstallationPolicy Trusted -ErrorAction Stop
        try {
            # Publish-Module needs the module folder named exactly <ModuleName>.
            $publishDir = Join-Path (Join-Path $OutputDirectory 'publish') $moduleName
            New-Item -ItemType Directory -Path $publishDir -Force | Out-Null
            Copy-Item -Path (Join-Path $stageModuleDir '*') -Destination $publishDir -Recurse -Force
            Publish-Module -Path $publishDir -Repository $tempRepoName -ErrorAction Stop
            $nupkgMade = $true
        } finally {
            Unregister-PSRepository -Name $tempRepoName -ErrorAction SilentlyContinue
        }
    }
} catch {
    Write-Warning "NuGet package build skipped: $($_.Exception.Message)"
}

if ($nupkgMade) {
    Get-ChildItem -Path (Join-Path $OutputDirectory 'nuget') -Filter '*.nupkg' -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "Wrote $($_.FullName)" -ForegroundColor Green }
}

Write-Host ''
Write-Host "Build complete. Artifacts in: $OutputDirectory" -ForegroundColor Cyan

[pscustomobject]@{
    Version      = $version
    StagingDir   = $stageModuleDir
    ZipPath      = $zipPath
    NuGetCreated = $nupkgMade
    OutputDir    = $OutputDirectory
}
