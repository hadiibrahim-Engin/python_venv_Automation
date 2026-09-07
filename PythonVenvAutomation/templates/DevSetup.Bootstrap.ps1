#Requires -Version 5.1
# =============================================================================
# DevSetup.Bootstrap.ps1
# -----------------------------------------------------------------------------
# Dot-sourced by the generated command shim BEFORE the DevSetup module is
# imported, so the version it activates is the one that actually runs.
#
# ARCHITECTURAL BOUNDARY (Part D). This file knows only:
#     distribution repository, update channel, local versions, update lock,
#     manifest validation, SHA256 validation, Authenticode validation,
#     staging, activation, rollback, starting the real DevSetup version.
#
# It must NEVER learn about pyproject.toml, Poetry, uv, Python discovery,
# .venv, dependency management, VS Code or Tcl. Those live in the versioned
# payload it activates, not in the bootstrap. Architecture.Tests.ps1 enforces
# this by scanning the file.
#
# It is intentionally standalone: no dependency on any module being importable,
# because its whole job is to make a module importable.
# =============================================================================

$script:DevSetupBootstrapVersion = '2.0.0'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Get-DevSetupBootConfig {
<#
.SYNOPSIS
    Loads config.json, applying defaults for anything missing.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $ConfigPath)

    $config = @{
        CommandName          = 'devsetup'
        DistributionUri      = ''
        DistributionBranch   = 'distribution'
        Channel              = 'stable'
        AutoUpdateEnabled    = $true
        AllowOfflineContinue = $true
        GitTimeoutSeconds    = 60
        LockWaitSeconds      = 90
        LockStaleMinutes     = 15
        KeepVersions         = 3
    }
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                foreach ($p in ($raw | ConvertFrom-Json -ErrorAction Stop).PSObject.Properties) {
                    $config[$p.Name] = $p.Value
                }
            }
        } catch {
            Write-Warning ("DevSetup: configuration could not be read ({0}). Using defaults." -f $_.Exception.Message)
        }
    }
    return $config
}

function Get-DevSetupBootPaths {
<#
.SYNOPSIS
    The install layout under %LOCALAPPDATA%\Company\DevSetup.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [string] $InstallRoot)

    [pscustomobject]@{
        Root         = $InstallRoot
        Bin          = Join-Path $InstallRoot 'bin'
        Bootstrap    = Join-Path $InstallRoot 'bootstrap'
        Distribution = Join-Path $InstallRoot 'distribution'
        Versions     = Join-Path $InstallRoot 'versions'
        Staging      = Join-Path $InstallRoot 'staging'
        Logs         = Join-Path $InstallRoot 'logs'
        State        = Join-Path $InstallRoot 'state'
        StateFile    = Join-Path (Join-Path $InstallRoot 'state') 'current.json'
        LockFile     = Join-Path (Join-Path $InstallRoot 'state') 'update.lock'
        ConfigFile   = Join-Path $InstallRoot 'config.json'
    }
}

# ---------------------------------------------------------------------------
# State (Part F)
# ---------------------------------------------------------------------------

function Get-DevSetupBootState {
<#
.SYNOPSIS
    Reads state/current.json. A missing or corrupt file yields empty state.

.DESCRIPTION
    Corrupt state must not brick the installation: an unreadable file is
    treated as "nothing activated yet", which the caller repairs by installing
    the channel version.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $StateFile)

    $state = @{ version = $null; previousVersion = $null; activatedUtc = $null; failedVersions = @() }
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) { return $state }
    try {
        $raw = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $state }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($p in $parsed.PSObject.Properties) { $state[$p.Name] = $p.Value }
        if ($null -eq $state.failedVersions) { $state.failedVersions = @() }
        $state.failedVersions = @($state.failedVersions)
    } catch {
        Write-Verbose ("DevSetup: state file unreadable ({0}); treating as empty." -f $_.Exception.Message)
    }
    return $state
}

function Set-DevSetupBootState {
<#
.SYNOPSIS
    Writes state/current.json atomically.

.DESCRIPTION
    Written to a temp file in the same directory and then moved into place, so
    a crash mid-write can never leave a half-written state file that would make
    the installation look like it has no active version.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $StateFile,
        [Parameter(Mandatory)] [hashtable] $State
    )

    $dir = Split-Path -Parent $StateFile
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not $PSCmdlet.ShouldProcess($StateFile, 'Write activation state')) { return }

    # Read defensively: under Set-StrictMode -Version Latest, property-style
    # access to a missing hashtable key throws, and callers legitimately pass
    # partial state.
    function _get { param($h, $k) if ($h.ContainsKey($k)) { return $h[$k] } return $null }

    $ordered = [ordered]@{
        version         = _get $State 'version'
        previousVersion = _get $State 'previousVersion'
        activatedUtc    = _get $State 'activatedUtc'
        failedVersions  = @(_get $State 'failedVersions')
    }
    # Preserve anything else the caller tracked (lastKnownMinimum, and whatever
    # a future version adds); dropping it would silently disable the offline
    # minimumSupportedVersion check.
    foreach ($key in $State.Keys) {
        if (-not $ordered.Contains($key)) { $ordered[$key] = $State[$key] }
    }
    $temp = '{0}.{1}.tmp' -f $StateFile, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    Set-Content -LiteralPath $temp -Value ($ordered | ConvertTo-Json -Depth 5) -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $StateFile -Force
}

# ---------------------------------------------------------------------------
# Update lock (Part H)
# ---------------------------------------------------------------------------

function Test-DevSetupBootProcessAlive {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [int] $ProcessId)
    if ($ProcessId -le 0) { return $false }
    try { return [bool](Get-Process -Id $ProcessId -ErrorAction Stop) } catch { return $false }
}

function Enter-DevSetupBootLock {
<#
.SYNOPSIS
    Takes the update lock, detecting locks left behind by crashed processes.

.DESCRIPTION
    The lock file records the owning PID and a timestamp. A lock is considered
    stale when its process is gone, or when it is older than StaleMinutes (the
    PID may have been reused, or the owner may be on another machine sharing a
    roamed profile).

.OUTPUTS
    $true when the lock was acquired.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $WaitSeconds = 90,
        [int] $StaleMinutes = 15
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $stale = $false
            try {
                $info = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $ownerPid = 0
                if ($info.PSObject.Properties.Name -contains 'processId') { $ownerPid = [int]$info.processId }
                if (-not (Test-DevSetupBootProcessAlive -ProcessId $ownerPid)) { $stale = $true }
            } catch {
                $stale = $true   # unreadable lock is a crashed writer
            }
            if (-not $stale) {
                $age = (Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime
                if ($age.TotalMinutes -ge $StaleMinutes) { $stale = $true }
            }
            if ($stale) {
                Write-Verbose 'DevSetup: removing a stale update lock.'
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            } else {
                Start-Sleep -Milliseconds 400
                continue
            }
        }

        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $payload = [System.Text.Encoding]::UTF8.GetBytes((@{
                    processId = $PID
                    host      = [System.Environment]::MachineName
                    takenUtc  = (Get-Date).ToUniversalTime().ToString('o')
                } | ConvertTo-Json -Compress))
                $stream.Write($payload, 0, $payload.Length)
            } finally { $stream.Dispose() }
            return $true
        } catch {
            Start-Sleep -Milliseconds 400
        }
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Exit-DevSetupBootLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Git transport
# ---------------------------------------------------------------------------

function Invoke-DevSetupBootGit {
<#
.SYNOPSIS
    Runs git with an argument list and a timeout. Never builds a shell string.

.OUTPUTS
    PSCustomObject with Succeeded, ExitCode, StdOut, StdErr, TimedOut.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $WorkingDirectory,
        [int] $TimeoutSeconds = 60
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    foreach ($a in $Arguments) { $null = $psi.ArgumentList.Add($a) }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    # Never let git stop for interactive credentials in an unattended run;
    # the credential helper (GCM/Entra) either has a token or it does not.
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        $null = $process.Start()
        $stdOutTask = $process.StandardOutput.ReadToEndAsync()
        $stdErrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            return [pscustomobject]@{ Succeeded = $false; ExitCode = -1; StdOut = ''; StdErr = 'timeout'; TimedOut = $true }
        }
        $out = $stdOutTask.GetAwaiter().GetResult()
        $err = $stdErrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            Succeeded = ($process.ExitCode -eq 0)
            ExitCode  = $process.ExitCode
            StdOut    = [string]$out
            StdErr    = [string]$err
            TimedOut  = $false
        }
    } catch {
        return [pscustomobject]@{ Succeeded = $false; ExitCode = -1; StdOut = ''; StdErr = $_.Exception.Message; TimedOut = $false }
    } finally {
        $process.Dispose()
    }
}

function Sync-DevSetupBootDistribution {
<#
.SYNOPSIS
    Ensures the local distribution clone exists and is up to date.

.DESCRIPTION
    A missing or damaged clone is repaired by re-cloning. Only the distribution
    branch is fetched, shallow, so the client never downloads source history.

.OUTPUTS
    PSCustomObject with Succeeded and Reason.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $DistributionPath,
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $Branch,
        [int] $TimeoutSeconds = 60
    )

    if (-not $PSCmdlet.ShouldProcess($DistributionPath, 'Synchronize the distribution clone')) {
        return [pscustomobject]@{ Succeeded = $false; Reason = 'WhatIf' }
    }

    $isRepo = $false
    if (Test-Path -LiteralPath $DistributionPath -PathType Container) {
        $probe = Invoke-DevSetupBootGit -Arguments @('rev-parse', '--git-dir') -WorkingDirectory $DistributionPath -TimeoutSeconds $TimeoutSeconds
        $isRepo = $probe.Succeeded
        if (-not $isRepo) {
            Write-Verbose 'DevSetup: distribution clone is damaged; re-cloning.'
            Remove-Item -LiteralPath $DistributionPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $isRepo) {
        $parent = Split-Path -Parent $DistributionPath
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $clone = Invoke-DevSetupBootGit -TimeoutSeconds $TimeoutSeconds -Arguments @(
            'clone', '--quiet', '--single-branch', '--branch', $Branch, '--depth', '1', $Uri, $DistributionPath)
        if (-not $clone.Succeeded) {
            return [pscustomobject]@{ Succeeded = $false; Reason = ("clone failed: {0}" -f $clone.StdErr.Trim()) }
        }
        return [pscustomobject]@{ Succeeded = $true; Reason = 'cloned' }
    }

    $fetch = Invoke-DevSetupBootGit -Arguments @('fetch', '--quiet', '--depth', '1', 'origin', $Branch) -WorkingDirectory $DistributionPath -TimeoutSeconds $TimeoutSeconds
    if (-not $fetch.Succeeded) {
        return [pscustomobject]@{ Succeeded = $false; Reason = ("fetch failed: {0}" -f $fetch.StdErr.Trim()) }
    }

    # A shallow distribution clone is a pure mirror; resetting to the fetched
    # tip avoids the non-fast-forward failures a force-push would cause.
    $reset = Invoke-DevSetupBootGit -Arguments @('reset', '--hard', ("origin/{0}" -f $Branch), '--quiet') -WorkingDirectory $DistributionPath -TimeoutSeconds $TimeoutSeconds
    if (-not $reset.Succeeded) {
        return [pscustomobject]@{ Succeeded = $false; Reason = ("update failed: {0}" -f $reset.StdErr.Trim()) }
    }
    return [pscustomobject]@{ Succeeded = $true; Reason = 'updated' }
}

# ---------------------------------------------------------------------------
# Decision (Part E)
# ---------------------------------------------------------------------------

function Get-DevSetupBootDecision {
<#
.SYNOPSIS
    Decides what to do, given the local state and what the channel offers.

.DESCRIPTION
    Pure function - no I/O - so every branch is directly testable.

    Offline rules:
      * unreachable + local >= last known minimum  -> continue with a warning
      * unreachable + local below that minimum     -> stop with a clear message
      * force=true in the channel                  -> no offline fallback

.OUTPUTS
    Hashtable with Action ('none' | 'update' | 'install' | 'fail'),
    Target and Reason.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][string] $InstalledVersion,
        [AllowNull()][string] $ChannelVersion,
        [AllowNull()][string] $MinimumSupportedVersion,
        [bool] $ChannelReachable = $true,
        [bool] $Force = $false,
        [bool] $AllowOfflineContinue = $true,
        [string[]] $FailedVersions = @()
    )

    function _d { param($a, $t, $r) @{ Action = $a; Target = $t; Reason = $r } }
    function _v { param($s) if ([string]::IsNullOrWhiteSpace($s)) { return $null }
                  try { return [version]$s } catch { return $null } }

    $installed = _v $InstalledVersion
    $offered   = _v $ChannelVersion
    $minimum   = _v $MinimumSupportedVersion

    if (-not $ChannelReachable) {
        if ($null -eq $installed) {
            return _d 'fail' $null 'No local version is installed and the distribution repository cannot be reached.'
        }
        if ($Force) {
            return _d 'fail' $null 'This version is mandatory, but the distribution repository cannot be reached.'
        }
        if ($minimum -and $installed -lt $minimum) {
            return _d 'fail' $null ("The installed version {0} is no longer supported (minimum {1}) and the distribution repository cannot be reached." -f $installed, $minimum)
        }
        if (-not $AllowOfflineContinue) {
            return _d 'fail' $null 'The distribution repository cannot be reached and offline use is disabled.'
        }
        return _d 'none' $installed ("Could not check for updates. Continuing with the installed version {0}." -f $installed)
    }

    if ($null -eq $offered) { return _d 'fail' $null 'The update channel does not name a usable version.' }

    if ($null -ne $installed -and $minimum -and $installed -lt $minimum) {
        # Below the supported floor: updating is not optional any more.
        return _d 'update' $offered ("The installed version {0} is below the supported minimum {1}." -f $installed, $minimum)
    }

    if ($null -eq $installed) { return _d 'install' $offered ("Installing DevSetup {0}." -f $offered) }
    if ($installed -ge $offered) { return _d 'none' $installed 'The installed version is current.' }

    # Do not reinstall a version that already failed to activate (Part G).
    if (@($FailedVersions) -contains $offered.ToString()) {
        return _d 'none' $installed ("Version {0} previously failed to start; staying on {1}." -f $offered, $installed)
    }

    return _d 'update' $offered ("A newer version is available: {0} -> {1}." -f $installed, $offered)
}

# ---------------------------------------------------------------------------
# Package validation (Part F)
# ---------------------------------------------------------------------------

function Get-DevSetupBootFileSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-DevSetupBootTextSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

function Test-DevSetupBootPackage {
<#
.SYNOPSIS
    Validates a package directory before anything is copied out of it.

.DESCRIPTION
    Order matters and is deliberate:
      1. manifest.json parses and carries the required fields
      2. SHA256SUMS.txt matches the hash pinned in the manifest
      3. every listed file matches its hash, and no unlisted file exists
      4. Authenticode (Windows only, when requested)

    Nothing is trusted before the step that proves it.

.OUTPUTS
    PSCustomObject with IsValid, Errors, Manifest.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $PackageDir,
        [Parameter(Mandatory)] [string] $ExpectedVersion,
        [switch] $RequireAuthenticode
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $manifestPath = Join-Path $PackageDir 'manifest.json'

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return [pscustomobject]@{ IsValid = $false; Errors = @("manifest.json is missing in $PackageDir"); Manifest = $null }
    }

    $manifest = $null
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { return [pscustomobject]@{ IsValid = $false; Errors = @("manifest.json is not valid JSON: $($_.Exception.Message)"); Manifest = $null } }

    foreach ($field in @('schemaVersion', 'product', 'version', 'contentPath', 'checksums', 'checksumsSha256', 'fileCount')) {
        if ($manifest.PSObject.Properties.Name -notcontains $field) { $errors.Add("manifest.json is missing '$field'.") }
    }
    if ($errors.Count -gt 0) { return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray(); Manifest = $manifest } }

    if ([int]$manifest.schemaVersion -ne 1) { $errors.Add("Unsupported manifest schemaVersion $($manifest.schemaVersion).") }
    if ([string]$manifest.product -ne 'DevSetup') { $errors.Add("Unexpected product '$($manifest.product)'.") }
    if ([string]$manifest.version -ne $ExpectedVersion) { $errors.Add("manifest version '$($manifest.version)' does not match '$ExpectedVersion'.") }
    if ($errors.Count -gt 0) { return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray(); Manifest = $manifest } }

    $checksumPath = Join-Path $PackageDir ([string]$manifest.checksums)
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        return [pscustomobject]@{ IsValid = $false; Errors = @("Checksum list is missing: $checksumPath"); Manifest = $manifest }
    }
    $listText = Get-Content -LiteralPath $checksumPath -Raw -Encoding UTF8
    if ($null -eq $listText) { $listText = '' }
    if ((Get-DevSetupBootTextSha256 -Text $listText) -ne [string]$manifest.checksumsSha256) {
        return [pscustomobject]@{ IsValid = $false; Errors = @('The checksum list does not match the hash pinned in manifest.json.'); Manifest = $manifest }
    }

    $contentDir = Join-Path $PackageDir ([string]$manifest.contentPath)
    if (-not (Test-Path -LiteralPath $contentDir -PathType Container)) {
        return [pscustomobject]@{ IsValid = $false; Errors = @("Content directory is missing: $contentDir"); Manifest = $manifest }
    }
    $root = (Resolve-Path -LiteralPath $contentDir).Path

    $listed = @{}
    foreach ($line in ($listText -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.TrimEnd("`r") -split '  ', 2
        if ($parts.Count -ne 2) { $errors.Add("Malformed checksum line: $line"); continue }
        $expected = $parts[0].Trim().ToLowerInvariant()
        $relative = $parts[1].Trim()
        $listed[$relative] = $true
        $full = Join-Path $root ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $errors.Add("Missing file: $relative"); continue }
        if ((Get-DevSetupBootFileSha256 -Path $full) -ne $expected) { $errors.Add("Checksum mismatch: $relative") }
    }
    foreach ($file in (Get-ChildItem -LiteralPath $root -Recurse -File)) {
        $relative = ($file.FullName.Substring($root.Length).TrimStart([char]'\', [char]'/')) -replace '\\', '/'
        if (-not $listed.ContainsKey($relative)) { $errors.Add("Unlisted file present: $relative") }
    }
    if ($listed.Count -ne [int]$manifest.fileCount) {
        $errors.Add("fileCount $($manifest.fileCount) does not match the checksum list ($($listed.Count)).")
    }

    if ($RequireAuthenticode -and $errors.Count -eq 0) {
        foreach ($e in (Test-DevSetupBootAuthenticode -ContentPath $root)) { $errors.Add($e) }
    }

    [pscustomobject]@{ IsValid = ($errors.Count -eq 0); Errors = $errors.ToArray(); Manifest = $manifest }
}

function Test-DevSetupBootAuthenticode {
<#
.SYNOPSIS
    Returns an error per PowerShell file whose Authenticode signature is not Valid.

.DESCRIPTION
    Skipped entirely off Windows, where Get-AuthenticodeSignature does not exist.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $ContentPath)

    $errors = New-Object System.Collections.Generic.List[string]
    if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) { return $errors.ToArray() }

    foreach ($file in (Get-ChildItem -LiteralPath $ContentPath -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1')) {
        $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
        if ($signature.Status -ne 'Valid') {
            $errors.Add(("Signature is {0}: {1}" -f $signature.Status, $file.Name))
        }
    }
    return $errors.ToArray()
}

# ---------------------------------------------------------------------------
# Staging, activation, rollback (Parts F / G)
# ---------------------------------------------------------------------------

function Test-DevSetupBootSelfTest {
<#
.SYNOPSIS
    Proves a staged version can actually load before it is activated.

.DESCRIPTION
    Two checks, both in a CHILD process so a broken payload cannot poison the
    running session:
      1. every .ps1/.psm1/.psd1 parses
      2. the module manifest imports

.OUTPUTS
    PSCustomObject with Succeeded and Message.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $VersionPath,
        [int] $TimeoutSeconds = 120
    )

    $manifest = Get-ChildItem -LiteralPath $VersionPath -Recurse -Filter 'PythonVenvAutomation.psd1' -File |
        Select-Object -First 1
    if (-not $manifest) {
        return [pscustomobject]@{ Succeeded = $false; Message = 'The package does not contain PythonVenvAutomation.psd1.' }
    }

    $script = @'
param($Root, $Manifest)
$ErrorActionPreference = 'Stop'
$bad = @()
Get-ChildItem -LiteralPath $Root -Recurse -Include '*.ps1','*.psm1','*.psd1' -File | ForEach-Object {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) { $bad += $_.FullName }
}
if ($bad.Count -gt 0) { Write-Output ("PARSE_FAILED: " + ($bad -join '; ')); exit 2 }
Import-Module $Manifest -Force -DisableNameChecking -ErrorAction Stop
Write-Output 'OK'
exit 0
'@

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("devsetup-selftest-{0}.ps1" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    Set-Content -LiteralPath $tempScript -Value $script -Encoding UTF8
    try {
        $exe = (Get-Process -Id $PID).Path
        if (-not $exe) { $exe = 'pwsh' }
        $result = Invoke-DevSetupBootProcess -FilePath $exe -Arguments @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $tempScript, $VersionPath, $manifest.FullName) -TimeoutSeconds $TimeoutSeconds

        if ($result.TimedOut) { return [pscustomobject]@{ Succeeded = $false; Message = 'Self-test timed out.' } }
        if ($result.ExitCode -ne 0) {
            $detail = ($result.StdErr + ' ' + $result.StdOut).Trim()
            return [pscustomobject]@{ Succeeded = $false; Message = ("Self-test failed: {0}" -f $detail) }
        }
        return [pscustomobject]@{ Succeeded = $true; Message = 'Self-test passed.' }
    } finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DevSetupBootProcess {
<#
.SYNOPSIS
    Runs a process with an argument list and a timeout.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [int] $TimeoutSeconds = 120
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    foreach ($a in $Arguments) { $null = $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        $null = $process.Start()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'timeout'; TimedOut = $true }
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = [string]$outTask.GetAwaiter().GetResult()
            StdErr   = [string]$errTask.GetAwaiter().GetResult()
            TimedOut = $false
        }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = $_.Exception.Message; TimedOut = $false }
    } finally {
        $process.Dispose()
    }
}

function Install-DevSetupBootVersion {
<#
.SYNOPSIS
    Stages, validates, self-tests and atomically activates one version.

.DESCRIPTION
    Never writes into the active version directory. The sequence is:

        package -> staging/<v> -> validate -> self-test -> versions/<v>
                -> current.json switched atomically

    A failure at any point leaves the previously active version untouched and
    records the version in failedVersions so the next run does not retry it in
    a loop (Part G).

.OUTPUTS
    PSCustomObject with Succeeded, Version, Message.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Paths,
        [Parameter(Mandatory)] [string] $PackageDir,
        [Parameter(Mandatory)] [string] $Version,
        [switch] $RequireAuthenticode,
        [switch] $SkipSelfTest
    )

    if (-not $PSCmdlet.ShouldProcess($Version, 'Install and activate DevSetup version')) {
        return [pscustomobject]@{ Succeeded = $false; Version = $Version; Message = 'WhatIf' }
    }

    $stagingDir = Join-Path $Paths.Staging $Version
    $targetDir  = Join-Path $Paths.Versions $Version
    $state = Get-DevSetupBootState -StateFile $Paths.StateFile

    try {
        # 1. Validate the package in place, before copying anything out of it.
        $check = Test-DevSetupBootPackage -PackageDir $PackageDir -ExpectedVersion $Version -RequireAuthenticode:$RequireAuthenticode
        if (-not $check.IsValid) { throw ("package validation failed: {0}" -f ($check.Errors -join '; ')) }

        # 2. Stage.
        if (Test-Path -LiteralPath $stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force }
        New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
        $contentDir = Join-Path $PackageDir ([string]$check.Manifest.contentPath)
        # Enumerate and copy each child: -LiteralPath does not expand '*', and
        # switching to -Path would make a real path containing [ ] a wildcard.
        foreach ($item in (Get-ChildItem -LiteralPath $contentDir -Force)) {
            Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $stagingDir $item.Name) -Recurse -Force
        }

        # 3. Self-test the staged copy in a child process.
        if (-not $SkipSelfTest) {
            $selfTest = Test-DevSetupBootSelfTest -VersionPath $stagingDir
            if (-not $selfTest.Succeeded) { throw $selfTest.Message }
        }

        # 4. Move into versions/<v>. Copy-then-swap so a half-copied target is
        #    never visible under the real name.
        if (Test-Path -LiteralPath $targetDir) { Remove-Item -LiteralPath $targetDir -Recurse -Force }
        if (-not (Test-Path -LiteralPath $Paths.Versions -PathType Container)) {
            New-Item -ItemType Directory -Path $Paths.Versions -Force | Out-Null
        }
        Move-Item -LiteralPath $stagingDir -Destination $targetDir -Force

        # 5. Flip current.json atomically.
        $previous = if ($state.ContainsKey('version')) { $state.version } else { $null }
        $state.previousVersion = $previous
        $state.version = $Version
        $state.activatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $state.failedVersions = @(@(if ($state.ContainsKey('failedVersions')) { $state.failedVersions } else { @() }) | Where-Object { $_ -ne $Version })
        Set-DevSetupBootState -StateFile $Paths.StateFile -State $state -Confirm:$false

        return [pscustomobject]@{ Succeeded = $true; Version = $Version; Message = ("Activated {0}." -f $Version) }
    }
    catch {
        $message = $_.Exception.Message
        Write-Verbose ("DevSetup: activation of {0} failed: {1}" -f $Version, $message)

        if (Test-Path -LiteralPath $stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $targetDir)  { Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue }

        # Remember the failure so the next run does not retry the same version.
        $failed = @(@(if ($state.ContainsKey('failedVersions')) { $state.failedVersions } else { @() }) + $Version | Select-Object -Unique)
        $state.failedVersions = $failed
        Set-DevSetupBootState -StateFile $Paths.StateFile -State $state -Confirm:$false

        return [pscustomobject]@{ Succeeded = $false; Version = $Version; Message = $message }
    }
}

function Remove-DevSetupBootOldVersion {
<#
.SYNOPSIS
    Keeps the newest N versions plus the active and previous one.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Paths,
        [int] $Keep = 3
    )

    if (-not (Test-Path -LiteralPath $Paths.Versions -PathType Container)) { return }
    $state = Get-DevSetupBootState -StateFile $Paths.StateFile
    $protected = @(
        $(if ($state.ContainsKey('version')) { $state.version } else { $null })
        $(if ($state.ContainsKey('previousVersion')) { $state.previousVersion } else { $null })
    ) | Where-Object { $_ }

    $all = Get-ChildItem -LiteralPath $Paths.Versions -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending

    $index = 0
    foreach ($dir in $all) {
        $index++
        if ($index -le $Keep) { continue }
        if ($protected -contains $dir.Name) { continue }
        if ($PSCmdlet.ShouldProcess($dir.FullName, 'Remove superseded DevSetup version')) {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


# ---------------------------------------------------------------------------
# Orchestration (Part E)
# ---------------------------------------------------------------------------

function Get-DevSetupBootActiveModulePath {
<#
.SYNOPSIS
    Path to the module manifest of the currently activated version, or $null.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [pscustomobject] $Paths)

    $state = Get-DevSetupBootState -StateFile $Paths.StateFile
    if (-not $state.version) { return $null }
    $dir = Join-Path $Paths.Versions $state.version
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    $manifest = Get-ChildItem -LiteralPath $dir -Recurse -Filter 'PythonVenvAutomation.psd1' -File | Select-Object -First 1
    if (-not $manifest) { return $null }
    return $manifest.FullName
}

function Invoke-DevSetupBootAutoUpdate {
<#
.SYNOPSIS
    The every-run update check. Returns $true when the shim should relaunch.

.DESCRIPTION
    Runs on EVERY devsetup start - there is deliberately no 12h/24h cache - but
    a network failure never blocks the user: an unreachable repository falls
    back to the installed version as long as it is still supported.

    Technical git/HTTP/PowerShell errors are never surfaced to end users; they
    go to -Verbose and the structured log, while the user sees one sentence.

.OUTPUTS
    [bool] - $true when a new version was activated and the caller should
    restart so the new files are the ones loaded.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $CommandName,
        [Parameter(Mandatory)] [string] $ConfigPath,
        [switch] $Force,
        [switch] $RequireAuthenticode
    )

    $installRoot = Split-Path -Parent $ConfigPath
    $paths  = Get-DevSetupBootPaths -InstallRoot $installRoot
    $config = Get-DevSetupBootConfig -ConfigPath $ConfigPath

    if (-not $Force -and -not [bool]$config.AutoUpdateEnabled) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$config.DistributionUri)) {
        Write-Verbose 'DevSetup: no distribution repository configured; skipping the update check.'
        return $false
    }

    $state = Get-DevSetupBootState -StateFile $paths.StateFile

    if (-not (Enter-DevSetupBootLock -Path $paths.LockFile -WaitSeconds ([int]$config.LockWaitSeconds) -StaleMinutes ([int]$config.LockStaleMinutes))) {
        # Another terminal is updating. Re-read the state: if it finished, we
        # simply use whatever it activated (Part H).
        Write-Verbose 'DevSetup: another process holds the update lock.'
        $after = Get-DevSetupBootState -StateFile $paths.StateFile
        if ($after.version -and $after.version -ne $state.version) { return $true }
        return $false
    }

    try {
        # Re-read under the lock: another terminal may have just finished.
        $state = Get-DevSetupBootState -StateFile $paths.StateFile

        $sync = Sync-DevSetupBootDistribution `
            -DistributionPath $paths.Distribution `
            -Uri ([string]$config.DistributionUri) `
            -Branch ([string]$config.DistributionBranch) `
            -TimeoutSeconds ([int]$config.GitTimeoutSeconds) `
            -Confirm:$false

        $channelVersion = $null
        $minimumSupported = $null
        $channelForce = $false
        $reachable = $sync.Succeeded

        if ($reachable) {
            $channelPath = Join-Path (Join-Path $paths.Distribution 'channels') ("{0}.json" -f $config.Channel)
            try {
                $channel = Get-Content -LiteralPath $channelPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                $channelVersion   = [string]$channel.version
                $minimumSupported = [string]$channel.minimumSupportedVersion
                $channelForce     = [bool]$channel.force
                # Remember the floor so an offline run can still enforce it.
                $state.lastKnownMinimum = $minimumSupported
                Set-DevSetupBootState -StateFile $paths.StateFile -State $state -Confirm:$false
            } catch {
                Write-Verbose ("DevSetup: channel '{0}' could not be read: {1}" -f $config.Channel, $_.Exception.Message)
                $reachable = $false
            }
        } else {
            Write-Verbose ("DevSetup: distribution sync failed: {0}" -f $sync.Reason)
        }

        if (-not $reachable -and $state.ContainsKey('lastKnownMinimum')) {
            $minimumSupported = [string]$state.lastKnownMinimum
        }

        $decision = Get-DevSetupBootDecision `
            -InstalledVersion $state.version `
            -ChannelVersion $channelVersion `
            -MinimumSupportedVersion $minimumSupported `
            -ChannelReachable $reachable `
            -Force $channelForce `
            -AllowOfflineContinue ([bool]$config.AllowOfflineContinue) `
            -FailedVersions @($state.failedVersions)

        switch ($decision.Action) {
            'fail' {
                Write-Verbose ("DevSetup: {0}" -f $decision.Reason)
                throw (New-DevSetupBootUserError -Code 'DS-U102' -Detail $decision.Reason -CommandName $CommandName)
            }
            'none' {
                if (-not $reachable) { Write-Warning ("DevSetup: {0}" -f $decision.Reason) }
                else { Write-Verbose ("DevSetup: {0}" -f $decision.Reason) }
                return $false
            }
        }

        $target = [string]$decision.Target
        Write-Host ''
        Write-Host 'DevSetup wird aktualisiert...'
        Write-Host ("{0} -> {1}" -f $(if ($state.version) { $state.version } else { '(neu)' }), $target)

        $packageDir = Join-Path (Join-Path $paths.Distribution 'packages') $target
        $result = Install-DevSetupBootVersion `
            -Paths $paths -PackageDir $packageDir -Version $target `
            -RequireAuthenticode:$RequireAuthenticode -Confirm:$false

        if (-not $result.Succeeded) {
            Write-Verbose ("DevSetup: {0}" -f $result.Message)
            if ($state.version) {
                # The previous version is untouched and still active (Part G).
                Write-Host ''
                Write-Host 'Eine neue DevSetup-Version konnte nicht gestartet werden.'
                Write-Host ''
                Write-Host 'Die vorherige funktionierende Version wurde automatisch wiederhergestellt.'
                Write-Host ''
                Write-Host 'Sie koennen weiterarbeiten.'
                Write-Host ''
                Write-Host 'Fehlercode: DS-U104'
                Write-Host ''
                return $false
            }
            throw (New-DevSetupBootUserError -Code 'DS-U103' -Detail $result.Message -CommandName $CommandName)
        }

        Write-Host ''
        Write-Host '[ok] Update erfolgreich'
        Write-Host ''
        Remove-DevSetupBootOldVersion -Paths $paths -Keep ([int]$config.KeepVersions) -Confirm:$false
        return $true
    }
    finally {
        Exit-DevSetupBootLock -Path $paths.LockFile
    }
}

function New-DevSetupBootUserError {
<#
.SYNOPSIS
    Builds the one-paragraph message an end user is allowed to see.

.DESCRIPTION
    The bootstrap cannot import SupportCodes.psm1 (it runs before any module
    is loadable), so it carries the handful of DS-U1xx texts it needs.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Code,
        [Parameter()] [AllowEmptyString()] [string] $Detail,
        [Parameter()] [string] $CommandName = 'devsetup'
    )

    $texts = @{
        'DS-U101' = 'DevSetup konnte nicht aktualisiert werden. Es wird mit der lokal installierten Version weitergearbeitet.'
        'DS-U102' = 'DevSetup ist nicht auf einem unterstuetzten Stand und die Aktualisierung ist derzeit nicht moeglich.'
        'DS-U103' = 'Das Update-Paket konnte nicht ueberprueft werden. Es wurde nichts installiert.'
        'DS-U104' = 'Eine neue DevSetup-Version konnte nicht gestartet werden. Die vorherige Version ist weiterhin aktiv.'
        'DS-U105' = 'Ein anderes Fenster aktualisiert DevSetup gerade. Bitte kurz warten und erneut versuchen.'
    }
    $title = if ($texts.ContainsKey($Code)) { $texts[$Code] } else { 'DevSetup konnte nicht gestartet werden.' }

    if ($Detail) { Write-Verbose ("DevSetup {0}: {1}" -f $Code, $Detail) }

    return (@(
        ''
        $title
        ''
        ("Fehlercode: {0}" -f $Code)
        ''
        'Bitte fuehren Sie bei Bedarf aus:'
        ''
        ("    {0} support" -f $CommandName)
        ''
    ) -join [Environment]::NewLine)
}


Write-Verbose ("DevSetup bootstrap {0} loaded." -f $script:DevSetupBootstrapVersion)
