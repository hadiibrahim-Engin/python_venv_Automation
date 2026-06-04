#Requires -Version 5.1
<#
.SYNOPSIS
    One-shot installer for the PythonVenvAutomation 'devsetup' command.

.DESCRIPTION
    Installs (or updates) the PythonVenvAutomation module for the current user
    from a configurable PowerShell repository, then generates the global command
    shims and writes the runtime config under %LOCALAPPDATA%. Requires no admin
    rights and is safe to run repeatedly.

    The artifact backend (Azure Artifacts, GitHub Packages, internal NuGet, or a
    file-based repository) is selected purely through -RepositoryName /
    -RepositoryUri - no core module code changes are needed to switch backends.

.EXAMPLE
    .\install.ps1
.EXAMPLE
    .\install.ps1 -RepositoryName CompanyPS -RepositoryUri https://example/nuget/v3/index.json
.EXAMPLE
    .\install.ps1 -AutoUpdatePolicy MinimumRequired -RequiredVersion 1.2.0
.EXAMPLE
    .\install.ps1 -DisableAutoUpdate
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # ---- Configurable placeholders (override per environment) --------------
    [string] $RepositoryName = 'CompanyPS',
    [string] $RepositoryUri  = 'https://REPLACE_WITH_INTERNAL_NUGET_FEED/v3/index.json',
    [string] $ModuleName     = 'PythonVenvAutomation',
    [string] $CommandName    = 'devsetup',

    [switch] $SkipRepositoryRegistration,
    [switch] $Force,

    [ValidateSet('LatestStable', 'MinimumRequired', 'Pinned', 'Disabled')]
    [string] $AutoUpdatePolicy = 'LatestStable',
    [string] $RequiredVersion,
    [switch] $DisableAutoUpdate
)

$ErrorActionPreference = 'Stop'

Write-Host "Installing $ModuleName (command: $CommandName) ..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Ensure a package-management stack is available.
#    Prefer Microsoft.PowerShell.PSResourceGet; fall back to PowerShellGet on
#    Windows PowerShell 5.1 where PSResourceGet may be absent.
# ---------------------------------------------------------------------------
$usePSResource = [bool](Get-Command 'Install-PSResource' -ErrorAction SilentlyContinue)
if (-not $usePSResource) {
    try {
        Install-Module -Name 'Microsoft.PowerShell.PSResourceGet' -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Import-Module 'Microsoft.PowerShell.PSResourceGet' -ErrorAction Stop
        $usePSResource = [bool](Get-Command 'Install-PSResource' -ErrorAction SilentlyContinue)
    } catch {
        Write-Warning "PSResourceGet unavailable; falling back to PowerShellGet. ($($_.Exception.Message))"
        $usePSResource = $false
    }
}

# ---------------------------------------------------------------------------
# 2. Register the configured repository (unless told to skip).
# ---------------------------------------------------------------------------
if (-not $SkipRepositoryRegistration) {
    if ($RepositoryUri -like '*REPLACE_WITH*') {
        Write-Warning "RepositoryUri is still a placeholder ($RepositoryUri). Pass -RepositoryUri or -SkipRepositoryRegistration."
    } elseif ($usePSResource) {
        if (-not (Get-PSResourceRepository -Name $RepositoryName -ErrorAction SilentlyContinue)) {
            if ($PSCmdlet.ShouldProcess($RepositoryName, 'Register PSResource repository')) {
                Register-PSResourceRepository -Name $RepositoryName -Uri $RepositoryUri -Trusted -ErrorAction Stop
            }
        }
    } else {
        if (-not (Get-PSRepository -Name $RepositoryName -ErrorAction SilentlyContinue)) {
            if ($PSCmdlet.ShouldProcess($RepositoryName, 'Register PSRepository')) {
                Register-PSRepository -Name $RepositoryName -SourceLocation $RepositoryUri -InstallationPolicy Trusted -ErrorAction Stop
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Install / update the module for CurrentUser (no admin rights).
# ---------------------------------------------------------------------------
$installFromRepo = -not ($RepositoryUri -like '*REPLACE_WITH*')
if ($installFromRepo -and $PSCmdlet.ShouldProcess($ModuleName, 'Install/update from repository')) {
    try {
        if ($usePSResource) {
            $p = @{ Name = $ModuleName; Repository = $RepositoryName; Scope = 'CurrentUser'; TrustRepository = $true; ErrorAction = 'Stop' }
            if ($AutoUpdatePolicy -eq 'Pinned' -and $RequiredVersion) { $p['Version'] = $RequiredVersion }
            Install-PSResource @p
        } else {
            $p = @{ Name = $ModuleName; Repository = $RepositoryName; Scope = 'CurrentUser'; Force = $true; ErrorAction = 'Stop' }
            if ($AutoUpdatePolicy -eq 'Pinned' -and $RequiredVersion) { $p['RequiredVersion'] = $RequiredVersion }
            Install-Module @p
        }
    } catch {
        throw "Failed to install $ModuleName from '$RepositoryName': $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 4. Import the module. Prefer the freshly installed copy; fall back to the
#    local repository copy next to this installer (dev / offline bootstrap).
# ---------------------------------------------------------------------------
try {
    Import-Module $ModuleName -Force -ErrorAction Stop
} catch {
    $localManifest = Join-Path $PSScriptRoot "$ModuleName\$ModuleName.psd1"
    if (Test-Path -LiteralPath $localManifest -PathType Leaf) {
        Write-Warning "Importing local module copy from $localManifest"
        Import-Module $localManifest -Force -ErrorAction Stop
    } else {
        throw "Could not import $ModuleName (installed or local at $localManifest)."
    }
}

# ---------------------------------------------------------------------------
# 5. Generate command shims + write runtime config under %LOCALAPPDATA%.
# ---------------------------------------------------------------------------
$installArgs = @{
    Force            = $true
    RepositoryName   = $RepositoryName
    RepositoryUri    = $RepositoryUri
    AutoUpdatePolicy = $AutoUpdatePolicy
}
if ($PSBoundParameters.ContainsKey('RequiredVersion')) { $installArgs['RequiredVersion'] = $RequiredVersion }
if ($DisableAutoUpdate) { $installArgs['DisableAutoUpdate'] = $true }

$result = Install-DevSetupCommand @installArgs

# ---------------------------------------------------------------------------
# 6. Report installed version + command name.
# ---------------------------------------------------------------------------
$info = Get-PythonVenvSetupInfo
Write-Host ''
Write-Host ("Installed module version : {0}" -f $(if ($info.InstalledVersion) { $info.InstalledVersion } else { '(local / not from feed)' })) -ForegroundColor Green
Write-Host ("Command name             : {0}" -f $result.CommandName) -ForegroundColor Green
Write-Host ("Runtime config           : {0}" -f $result.ConfigPath) -ForegroundColor DarkGray
