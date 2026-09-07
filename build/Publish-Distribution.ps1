#Requires -Version 5.1
<#
.SYNOPSIS
    Publishes one version onto the distribution branch of this repository.

.DESCRIPTION
    Everything stays in ONE repository: the release lives on an orphan branch
    (default `distribution`) that shares no history with main, so developer
    clones of main never carry release payloads and the client can clone just
    that branch, shallow.

    The script is idempotent in the sense that matters: a version that is
    already published is never rewritten. Fixes ship as a new SemVer version.

    It performs no authentication of its own. In Azure Pipelines the Build
    Service identity is already configured on the checkout, so `git push`
    works without any PAT in YAML.

.PARAMETER Version
    The X.Y.Z version to publish. Defaults to the repository VERSION file.

.PARAMETER Channel
    Channel to point at this version after publishing. Use -NoPromote to
    publish without touching any channel.

.PARAMETER Push
    Actually push. Without it the commit is created locally only.

.EXAMPLE
    ./build/Publish-Distribution.ps1 -Version 1.9.0 -Channel stable -Push
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()][string] $Version,
    [Parameter()][ValidateSet('stable', 'pilot')][string] $Channel = 'stable',
    [Parameter()][string] $MinimumSupportedVersion,
    [Parameter()][string] $Branch = 'distribution',
    [Parameter()][string] $RemoteName = 'origin',
    [Parameter()][switch] $NoPromote,
    [Parameter()][switch] $ForceChannel,
    [Parameter()][switch] $Push
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $RepoRoot 'scripts4PythonAutomation/SetupCore/modules/Errors.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $RepoRoot 'scripts4PythonAutomation/SetupCore/modules/Distribution.psm1') -Force -DisableNameChecking -Global

function Invoke-PublishGit {
    param([string[]] $Arguments, [string] $WorkingDirectory = $RepoRoot, [switch] $AllowFailure)
    $output = & git -C $WorkingDirectory @Arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw ("git {0} failed: {1}" -f ($Arguments -join ' '), ($output -join "`n"))
    }
    return [pscustomobject]@{ Succeeded = ($LASTEXITCODE -eq 0); Output = ($output -join "`n") }
}

if (-not $Version) {
    $versionFile = Join-Path $RepoRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) { throw 'No -Version given and no VERSION file found.' }
    $Version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
}
$Version = (ConvertTo-DevSetupVersion -Version $Version).ToString()
if (-not $MinimumSupportedVersion) { $MinimumSupportedVersion = $Version }

Write-Host ("Publishing DevSetup {0} to branch '{1}' (channel: {2})" -f $Version, $Branch, $(if ($NoPromote) { 'none' } else { $Channel }))

# --- Work tree for the distribution branch ----------------------------------
# A separate worktree keeps main's checkout untouched while we commit release
# files to an unrelated branch.
$worktree = Join-Path ([System.IO.Path]::GetTempPath()) ("devsetup-dist-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))

$branchExists = (Invoke-PublishGit -Arguments @('ls-remote', '--exit-code', '--heads', $RemoteName, $Branch) -AllowFailure).Succeeded

try {
    if ($branchExists) {
        Invoke-PublishGit -Arguments @('fetch', '--quiet', $RemoteName, $Branch) | Out-Null
        Invoke-PublishGit -Arguments @('worktree', 'add', '--quiet', '--detach', $worktree, ("{0}/{1}" -f $RemoteName, $Branch)) | Out-Null
        Invoke-PublishGit -WorkingDirectory $worktree -Arguments @('checkout', '--quiet', '-B', $Branch) | Out-Null
    } else {
        # Orphan branch: no shared history with main by design.
        Invoke-PublishGit -Arguments @('worktree', 'add', '--quiet', '--detach', $worktree) | Out-Null
        Invoke-PublishGit -WorkingDirectory $worktree -Arguments @('checkout', '--quiet', '--orphan', $Branch) | Out-Null
        Invoke-PublishGit -WorkingDirectory $worktree -Arguments @('rm', '-rq', '--cached', '.') -AllowFailure | Out-Null
        Get-ChildItem -LiteralPath $worktree -Force |
            Where-Object { $_.Name -ne '.git' } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
    }

    # --- Immutability guard -------------------------------------------------
    $existing = @(Get-DevSetupPublishedVersion -DistributionRoot $worktree)
    if ($existing -contains $Version) {
        if ($NoPromote) {
            throw ("Version {0} is already published. Published versions are immutable." -f $Version)
        }
        Write-Host ("  Version {0} already exists - promoting the channel without rebuilding." -f $Version)
    } else {
        if (-not $PSCmdlet.ShouldProcess($Version, 'Build the release payload')) { return }
        New-DevSetupPackage `
            -DistributionRoot $worktree -Version $Version -Channel $Channel `
            -SourcePaths @(
                (Join-Path $RepoRoot 'PythonVenvAutomation'),
                (Join-Path $RepoRoot 'scripts4PythonAutomation')
            ) -Confirm:$false | Out-Null

        $verify = Test-DevSetupPublishedPackage -DistributionRoot $worktree -Version $Version
        if (-not $verify.IsValid) { throw ("The built package did not validate: {0}" -f ($verify.Errors -join '; ')) }
        Write-Host ("  Package built and verified ({0} files)." -f $verify.Manifest.fileCount)
    }

    # --- Installer files ----------------------------------------------------
    $installDir = Join-Path $worktree 'install'
    if (-not (Test-Path -LiteralPath $installDir -PathType Container)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }
    foreach ($file in @(
        (Join-Path $RepoRoot 'install/Install-DevSetup.ps1'),
        (Join-Path $RepoRoot 'install/Install-DevSetup.cmd'),
        (Join-Path $RepoRoot 'PythonVenvAutomation/templates/DevSetup.Bootstrap.ps1'))) {
        Copy-Item -LiteralPath $file -Destination $installDir -Force
    }

    if (-not $NoPromote) {
        Set-DevSetupChannel -DistributionRoot $worktree -Channel $Channel -Version $Version `
            -MinimumSupportedVersion $MinimumSupportedVersion -Force:$ForceChannel -Confirm:$false | Out-Null
        Write-Host ("  Channel '{0}' now points at {1}." -f $Channel, $Version)
    }

    # --- Commit -------------------------------------------------------------
    Invoke-PublishGit -WorkingDirectory $worktree -Arguments @('add', '-A') | Out-Null
    $status = Invoke-PublishGit -WorkingDirectory $worktree -Arguments @('status', '--porcelain')
    if ([string]::IsNullOrWhiteSpace($status.Output)) {
        Write-Host '  Nothing changed; no commit created.'
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Branch, 'Commit the release')) { return }
    $message = if ($NoPromote) { "publish DevSetup $Version" } else { "publish DevSetup $Version to $Channel" }
    Invoke-PublishGit -WorkingDirectory $worktree -Arguments @('commit', '--quiet', '-m', $message) | Out-Null
    Write-Host ('  Commit created.')

    if ($Push) {
        if (-not $PSCmdlet.ShouldProcess($RemoteName, ('Push {0}' -f $Branch))) { return }
        Invoke-PublishGit -WorkingDirectory $worktree -Arguments @('push', '--quiet', $RemoteName, ("HEAD:{0}" -f $Branch)) | Out-Null
        Write-Host ("  Pushed to {0}/{1}." -f $RemoteName, $Branch)
    } else {
        Write-Host '  -Push was not given; nothing was pushed.'
    }
}
finally {
    if (Test-Path -LiteralPath $worktree) {
        Invoke-PublishGit -Arguments @('worktree', 'remove', '--force', $worktree) -AllowFailure | Out-Null
        if (Test-Path -LiteralPath $worktree) { Remove-Item -LiteralPath $worktree -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
