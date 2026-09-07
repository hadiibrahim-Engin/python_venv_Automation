#Requires -Version 5.1
<#
.SYNOPSIS
    One-time DevSetup installation for the current user.

.DESCRIPTION
    Installs DevSetup under %LOCALAPPDATA%\Company\DevSetup without requiring
    administrator rights, and puts a `devsetup` command on the user's PATH.
    After this, the user only ever types `devsetup`.

    Authentication to Azure DevOps goes through Git Credential Manager /
    Microsoft Entra. This script contains no PAT, never asks for one, and never
    writes credentials anywhere - git owns that entirely.

.PARAMETER DistributionUri
    Clone URL of the repository that carries the distribution branch.

.PARAMETER Channel
    stable (default) or pilot.

.EXAMPLE
    .\Install-DevSetup.ps1 -DistributionUri https://dev.azure.com/org/proj/_git/python_venv_Automation
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()][string] $DistributionUri,
    [Parameter()][string] $DistributionBranch = 'distribution',
    [Parameter()][ValidateSet('stable', 'pilot')][string] $Channel = 'stable',
    [Parameter()][string] $CommandName = 'devsetup',
    [Parameter()][string] $InstallRoot,
    [Parameter()][switch] $NoPathUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Output helpers - deliberately plain German, no technical detail.
# ---------------------------------------------------------------------------

function Write-Step   { param([string] $Text) Write-Host ("  {0}" -f $Text) }
function Write-Ok     { param([string] $Text) Write-Host ("  [ok] {0}" -f $Text) -ForegroundColor Green }
function Write-Problem {
    param([string] $Text, [string] $Code = 'DS-U101')
    Write-Host ''
    Write-Host ("  {0}" -f $Text) -ForegroundColor Yellow
    Write-Host ''
    Write-Host ("  Fehlercode: {0}" -f $Code)
    Write-Host ''
}

function Invoke-InstallerGit {
    <#
    .SYNOPSIS
        Runs git with an argument list (never a shell string) and a timeout.
    #>
    param([string[]] $Arguments, [string] $WorkingDirectory, [int] $TimeoutSeconds = 180)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    foreach ($a in $Arguments) { $null = $psi.ArgumentList.Add($a) }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        $null = $p.Start()
        $o = $p.StandardOutput.ReadToEndAsync()
        $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            try { $p.Kill($true) } catch { }
            return [pscustomobject]@{ Succeeded = $false; StdOut = ''; StdErr = 'timeout' }
        }
        return [pscustomobject]@{
            Succeeded = ($p.ExitCode -eq 0)
            StdOut    = [string]$o.GetAwaiter().GetResult()
            StdErr    = [string]$e.GetAwaiter().GetResult()
        }
    } finally { $p.Dispose() }
}

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'DevSetup Installation'
Write-Host ''

$problems = New-Object System.Collections.Generic.List[string]

if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    $problems.Add('PowerShell 5.1 oder neuer wird benoetigt.')
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $problems.Add('Git wurde nicht gefunden. Bitte installieren Sie Git fuer Windows und starten Sie danach erneut.')
}
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Problem -Text $p -Code 'DS-G502' }
    exit 1
}
Write-Ok 'Voraussetzungen'

# A credential helper is what makes the Entra sign-in work without a PAT.
$helper = Invoke-InstallerGit -Arguments @('config', '--get', 'credential.helper') -TimeoutSeconds 20
if (-not $helper.Succeeded -or [string]::IsNullOrWhiteSpace($helper.StdOut)) {
    Write-Step 'Hinweis: Es ist kein Git Credential Manager konfiguriert.'
    Write-Step 'Die Anmeldung an Azure DevOps oeffnet sich sonst moeglicherweise nicht automatisch.'
}

if (-not $InstallRoot) {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = Join-Path $HOME '.local/share' }
    $InstallRoot = Join-Path (Join-Path $localAppData 'Company') 'DevSetup'
}

if (-not $DistributionUri) {
    Write-Host ''
    Write-Host '  Bitte geben Sie die Adresse des DevSetup-Repositorys an.'
    Write-Host '  Beispiel: https://dev.azure.com/<org>/<projekt>/_git/python_venv_Automation'
    Write-Host ''
    $DistributionUri = (Read-Host '  Repository-Adresse')
    if ([string]::IsNullOrWhiteSpace($DistributionUri)) {
        Write-Problem -Text 'Ohne Repository-Adresse kann DevSetup nicht installiert werden.' -Code 'DS-U101'
        exit 1
    }
}

# Never persist credentials that a user pasted into the URL by accident.
if ($DistributionUri -match '^[a-z][a-z0-9+.\-]*://[^/@]*:[^/@]*@') {
    Write-Problem -Code 'DS-U101' -Text @'
Die angegebene Adresse enthaelt Zugangsdaten. Bitte verwenden Sie die normale
Repository-Adresse ohne Benutzername und Kennwort - die Anmeldung erfolgt
automatisch ueber Ihr Microsoft-Konto.
'@
    exit 1
}

if (-not $PSCmdlet.ShouldProcess($InstallRoot, 'Install DevSetup for the current user')) { exit 0 }

# ---------------------------------------------------------------------------
# 2. Layout
# ---------------------------------------------------------------------------

foreach ($dir in @($InstallRoot,
                   (Join-Path $InstallRoot 'bin'),
                   (Join-Path $InstallRoot 'bootstrap'),
                   (Join-Path $InstallRoot 'versions'),
                   (Join-Path $InstallRoot 'staging'),
                   (Join-Path $InstallRoot 'logs'),
                   (Join-Path $InstallRoot 'state'))) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}
Write-Ok 'Verzeichnisse'

# ---------------------------------------------------------------------------
# 3. Configuration (no secrets - only the repository address and the channel)
# ---------------------------------------------------------------------------

$configPath = Join-Path $InstallRoot 'config.json'
$config = [ordered]@{
    CommandName          = $CommandName
    DistributionUri      = $DistributionUri
    DistributionBranch   = $DistributionBranch
    Channel              = $Channel
    AutoUpdateEnabled    = $true
    AllowOfflineContinue = $true
    GitTimeoutSeconds    = 60
    LockWaitSeconds      = 90
    LockStaleMinutes     = 15
    KeepVersions         = 3
}
Set-Content -LiteralPath $configPath -Value ($config | ConvertTo-Json -Depth 5) -Encoding UTF8
Write-Ok 'Konfiguration'

# ---------------------------------------------------------------------------
# 4. Bootstrap + shims
# ---------------------------------------------------------------------------

$installerDir = Split-Path -Parent $PSCommandPath
$bootstrapSource = Join-Path $installerDir 'DevSetup.Bootstrap.ps1'
if (-not (Test-Path -LiteralPath $bootstrapSource -PathType Leaf)) {
    # Running from a source checkout rather than the distribution branch.
    $bootstrapSource = Join-Path (Split-Path -Parent $installerDir) 'PythonVenvAutomation/templates/DevSetup.Bootstrap.ps1'
}
if (-not (Test-Path -LiteralPath $bootstrapSource -PathType Leaf)) {
    Write-Problem -Text 'Die Installationsdateien sind unvollstaendig.' -Code 'DS-U103'
    exit 1
}
$bootstrapTarget = Join-Path (Join-Path $InstallRoot 'bootstrap') 'DevSetup.Bootstrap.ps1'
Copy-Item -LiteralPath $bootstrapSource -Destination $bootstrapTarget -Force

$binDir = Join-Path $InstallRoot 'bin'
$shimPs1 = Join-Path $binDir ("{0}.ps1" -f $CommandName)
$shimCmd = Join-Path $binDir ("{0}.cmd" -f $CommandName)

$shimPs1Body = @'
#Requires -Version 5.1
# GENERATED SHIM - do not edit. Re-run Install-DevSetup to regenerate.
# No param() block: $args must capture every token verbatim, including '--'.
$ErrorActionPreference = 'Stop'

$CommandName = '__COMMAND_NAME__'
$binDir      = $PSScriptRoot
$installRoot = Split-Path -Parent $binDir
$configPath  = Join-Path $installRoot 'config.json'
$bootstrap   = Join-Path (Join-Path $installRoot 'bootstrap') 'DevSetup.Bootstrap.ps1'

$rawArgs = @($args)
$noSelfUpdate = $false; $forceSelfUpdate = $false; $seenDashDash = $false
$passthrough = @(); $friendly = @()
foreach ($a in $rawArgs) {
    if     ($seenDashDash)                { $passthrough    += $a }
    elseif ($a -eq '--')                  { $seenDashDash    = $true }
    elseif ($a -eq '--no-self-update')    { $noSelfUpdate    = $true }
    elseif ($a -eq '--force-self-update') { $forceSelfUpdate = $true }
    else                                  { $friendly       += $a }
}
$command = if ($friendly.Count -gt 0) { "$($friendly[0])".ToLowerInvariant() } else { '' }

# Diagnostics must report the state the user actually has, so they never
# trigger an update first.
$readOnly = @('doctor', 'about', 'support', 'help')
$relaunchEnv = ($CommandName.ToUpperInvariant() -replace '[^A-Z0-9]', '_') + '_AUTO_UPDATE_RELAUNCHED'
$alreadyRelaunched = Test-Path "env:$relaunchEnv"

. $bootstrap

if ((-not $noSelfUpdate) -and (-not $alreadyRelaunched) -and ($readOnly -notcontains $command)) {
    try {
        $updated = Invoke-DevSetupBootAutoUpdate -CommandName $CommandName -ConfigPath $configPath -Force:$forceSelfUpdate -Confirm:$false
    } catch {
        Write-Host $_.Exception.Message
        exit 1
    }
    if ($updated) {
        Set-Item "env:$relaunchEnv" '1'
        try { $hostExe = (Get-Process -Id $PID).Path } catch { $hostExe = $null }
        if (-not $hostExe) { $hostExe = 'powershell.exe' }
        & $hostExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @rawArgs
        $code = $LASTEXITCODE
        Remove-Item "env:$relaunchEnv" -ErrorAction SilentlyContinue
        exit $code
    }
}

$paths = Get-DevSetupBootPaths -InstallRoot $installRoot
$moduleManifest = Get-DevSetupBootActiveModulePath -Paths $paths
if (-not $moduleManifest) {
    Write-Host ''
    Write-Host 'DevSetup ist noch nicht vollstaendig eingerichtet.'
    Write-Host ''
    Write-Host 'Fehlercode: DS-U103'
    Write-Host ''
    exit 1
}

try { Import-Module $moduleManifest -Force -DisableNameChecking -ErrorAction Stop }
catch {
    Write-Host ''
    Write-Host 'DevSetup konnte nicht geladen werden.'
    Write-Host ''
    Write-Host 'Fehlercode: DS-U104'
    Write-Host ''
    exit 1
}

try {
    switch ($command) {
        ''            { Invoke-PythonVenvSetup @passthrough }
        'setup'       { Invoke-PythonVenvSetup @passthrough }
        'doctor'      { Invoke-DevSetupDoctor @passthrough }
        'repair'      { Invoke-DevSetupRepairCommand @passthrough }
        'about'       { Get-DevSetupAbout @passthrough }
        'support'     { New-DevSetupSupport @passthrough }
        'update'      { Invoke-PythonVenvSetup -Mode update-venv @passthrough }
        'upgrade'     { Invoke-PythonVenvSetup -Mode update-venv -UpdateDependencies @passthrough }
        'rebuild'     { Invoke-PythonVenvSetup -ForceRecreateVenv @passthrough }
        'dry'         { Invoke-PythonVenvSetup -DryRun @passthrough }
        'prod'        { Invoke-PythonVenvSetup -ExcludeDev @passthrough }
        'list-python' { Invoke-PythonVenvSetup -ListMode @passthrough }
        'self-update' { Invoke-DevSetupBootAutoUpdate -CommandName $CommandName -ConfigPath $configPath -Force -Confirm:$false | Out-Null }
        'help' {
            @(
                "$CommandName - Python-Projektumgebung einrichten"
                ''
                'Verwendung:'
                "  $CommandName            Projekt arbeitsbereit machen"
                "  $CommandName doctor     Alles pruefen, nichts aendern"
                "  $CommandName repair     Nur sichere Reparaturen durchfuehren"
                "  $CommandName upgrade    Abhaengigkeiten bewusst aktualisieren"
                "  $CommandName rebuild    .venv neu erzeugen"
                "  $CommandName about      Version und Status anzeigen"
                "  $CommandName support    Support-Paket erzeugen"
                "  $CommandName help       Diese Hilfe"
            ) -join [Environment]::NewLine | Write-Host
        }
        default {
            Write-Host ("Unbekannter Befehl: {0}" -f $command)
            Write-Host ("Verwenden Sie '{0} help'." -f $CommandName)
            exit 2
        }
    }
    exit 0
} catch {
    Write-Host $_.Exception.Message
    exit 1
}
'@

Set-Content -LiteralPath $shimPs1 -Value ($shimPs1Body -replace '__COMMAND_NAME__', $CommandName) -Encoding UTF8

$shimCmdBody = @"
@echo off
where pwsh.exe >nul 2>&1
if %ERRORLEVEL%==0 (set "PS=pwsh.exe") else (set "PS=powershell.exe")
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0$CommandName.ps1" %*
exit /b %ERRORLEVEL%
"@
Set-Content -LiteralPath $shimCmd -Value $shimCmdBody -Encoding ASCII
Write-Ok 'Befehl eingerichtet'

# ---------------------------------------------------------------------------
# 5. PATH (user scope only, and only the bin directory)
# ---------------------------------------------------------------------------

if (-not $NoPathUpdate) {
    try {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($null -eq $userPath) { $userPath = '' }
        $entries = @($userPath -split ';' | Where-Object { $_ })
        if ($entries -notcontains $binDir) {
            $newPath = (@($entries) + $binDir) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            Write-Ok 'PATH ergaenzt'
        } else {
            Write-Ok 'PATH bereits eingetragen'
        }
        if (($env:Path -split [System.IO.Path]::PathSeparator) -notcontains $binDir) {
            $env:Path = $env:Path + [System.IO.Path]::PathSeparator + $binDir
        }
    } catch {
        Write-Step 'Hinweis: Der PATH konnte nicht automatisch ergaenzt werden.'
        Write-Step ("Fuegen Sie bei Bedarf manuell hinzu: {0}" -f $binDir)
    }
}

# ---------------------------------------------------------------------------
# 6. First update: clone the distribution and activate the channel version
# ---------------------------------------------------------------------------

Write-Step 'Verbinde mit dem Repository...'
. $bootstrapTarget
try {
    Invoke-DevSetupBootAutoUpdate -CommandName $CommandName -ConfigPath $configPath -Force -Confirm:$false | Out-Null
} catch {
    Write-Host $_.Exception.Message
    exit 1
}

$paths = Get-DevSetupBootPaths -InstallRoot $InstallRoot
$state = Get-DevSetupBootState -StateFile $paths.StateFile
if (-not $state.version) {
    Write-Problem -Text 'Es konnte keine DevSetup-Version installiert werden.' -Code 'DS-U103'
    exit 1
}
Write-Ok ("DevSetup {0}" -f $state.version)

# ---------------------------------------------------------------------------
# 7. Self-test
# ---------------------------------------------------------------------------

$moduleManifest = Get-DevSetupBootActiveModulePath -Paths $paths
if (-not $moduleManifest) {
    Write-Problem -Text 'Die Installation ist unvollstaendig.' -Code 'DS-U103'
    exit 1
}
$selfTest = Test-DevSetupBootSelfTest -VersionPath (Join-Path $paths.Versions $state.version)
if (-not $selfTest.Succeeded) {
    Write-Verbose $selfTest.Message
    Write-Problem -Text 'Die installierte Version konnte nicht geladen werden.' -Code 'DS-U104'
    exit 1
}
Write-Ok 'Selbsttest'

Write-Host ''
Write-Host 'DevSetup ist einsatzbereit.' -ForegroundColor Green
Write-Host ''
Write-Host '  Oeffnen Sie ein neues Terminal und wechseln Sie in Ihr Projekt.'
Write-Host ("  Geben Sie dort ein:   {0}" -f $CommandName)
Write-Host ''
exit 0
