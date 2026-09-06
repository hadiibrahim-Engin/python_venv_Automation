#Requires -Version 5.1
# =============================================================================
# Module  : Filesystem.psm1
# Purpose : File/process cleanup helpers with ShouldProcess support.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Constants.psm1') -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Path.psm1')      -Force -DisableNameChecking -ErrorAction Stop

function Initialize-Directory {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($PSCmdlet.ShouldProcess($Path, 'Create directory')) {
            New-Item -ItemType Directory -LiteralPath $Path | Out-Null
        }
    }
    $Path
}

function Stop-VenvProcesses {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param([Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string] $VenvDir)

    try { $venvFull = (Resolve-Path -LiteralPath $VenvDir -ErrorAction Stop).Path } catch { $venvFull = $VenvDir }
    $venvFullLower = $venvFull.ToLowerInvariant()
    $scriptDir = Join-Path $venvFull 'Scripts'
    $targets = @(
        (Join-Path $scriptDir 'python.exe'),
        (Join-Path $scriptDir 'pythonw.exe'),
        (Join-Path $scriptDir 'pip.exe'),
        (Join-Path $scriptDir 'poetry.exe')
    ) | ForEach-Object { $_.ToLowerInvariant() }

    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try {
            if (-not $_.Path) { return $false }
            $p = $_.Path.ToLowerInvariant()
            $p.StartsWith($venvFullLower) -or ($targets -contains $p)
        } catch { $false }
    }

    foreach ($p in $procs) {
        try {
            if ($PSCmdlet.ShouldProcess("PID $($p.Id) $($p.Name)", "Stop process using $VenvDir")) {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
            }
        } catch {
            Write-Warning ("Could not stop PID {0}: {1}" -f $p.Id, $_.Exception.Message)
        }
    }
}

function Remove-PathRobust {
<#
.SYNOPSIS
    Removes a path with bounded retries and lock mitigation.

.EXAMPLE
    Remove-PathRobust -Path '.\.venv' -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string] $Path,
        [int] $MaxRetry = 0,
        [int] $DelayMs = 0
    )

    $constants = Get-SetupConstants
    if ($MaxRetry -le 0) { $MaxRetry = [int]$constants.Retry.MaxRetry }
    if ($DelayMs -le 0) { $DelayMs = [int]$constants.Retry.DelayMs }

    for ($i = 1; $i -le $MaxRetry; $i++) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return $true }
            if (-not $PSCmdlet.ShouldProcess($Path, "Remove recursively (attempt $i/$MaxRetry)")) { return $false }

            try { & "$env:SystemRoot\System32\attrib.exe" -R -H -S /S /D $Path } catch { }
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            Write-Warning ("Delete attempt {0}/{1} failed: {2}" -f $i, $MaxRetry, $_.Exception.Message)
            if ($i -lt $MaxRetry) {
                Start-Sleep -Milliseconds $DelayMs
                Stop-VenvProcesses -VenvDir $Path -Confirm:$false
            }
        }
    }
    $false
}

function Move-PathToQuarantine {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param([Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string] $Path)

    $constants = Get-SetupConstants
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dst = "$Path._stale_$stamp"
    try {
        if (-not $PSCmdlet.ShouldProcess($Path, "Move to quarantine $dst")) { return $null }
        Move-Item -LiteralPath $Path -Destination $dst -ErrorAction Stop

        $pathBytes = [System.Text.Encoding]::Unicode.GetBytes($dst)
        $pathB64 = [Convert]::ToBase64String($pathBytes)
        $delay = [int]$constants.Retry.QuarantineDelayS
        $cmd = "Start-Sleep $delay; Try { `$p = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$pathB64')); Remove-Item -Recurse -Force -LiteralPath `$p } Catch {}"
        $ps = [System.IO.Path]::GetFullPath("$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")
        Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-Command',$cmd) | Out-Null
        $dst
    } catch {
        Write-Warning ("Could not quarantine path: {0}" -f $_.Exception.Message)
        $null
    }
}

function Remove-StaleQuarantines {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string] $ProjectRoot)

    $constants = Get-SetupConstants
    $patterns = @('.venv._stale_*','.venv_backup_*')
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($pattern in $patterns) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $ProjectRoot -Directory -Filter $pattern -ErrorAction SilentlyContinue)) {
            $found.Add($dir.FullName)
        }
    }

    $removed = 0
    foreach ($dir in $found) {
        if (-not $PSCmdlet.ShouldProcess($dir, 'Remove stale virtual-environment directory')) { continue }
        if (Remove-PathRobust -Path $dir -MaxRetry ([int]$constants.Retry.CleanupMaxRetry) -DelayMs ([int]$constants.Retry.CleanupDelayMs) -Confirm:$false) {
            $removed++
        } else {
            Write-Warning ("Could not remove stale directory: {0}" -f $dir)
        }
    }
    $removed
}

function Add-PythonScriptsDirToPath {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string] $PythonExe)

    try {
        $pyCode = "import sysconfig,os; s=sysconfig.get_path('scripts'); u=sysconfig.get_path('scripts','nt_user'); print(os.pathsep.join(d for d in [s,u] if d))"
        $output = (& $PythonExe -c $pyCode 2>$null).Trim()
        $scriptDirs = @($output -split [System.IO.Path]::PathSeparator | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($scriptDirs.Count -gt 0 -and $PSCmdlet.ShouldProcess(($scriptDirs -join ';'), 'Add Python Scripts directories to PATH')) {
            Add-ToolDirsToPath -Directories $scriptDirs -Reason 'Python Scripts CLI' | Out-Null
        }
    } catch { }
}

Export-ModuleMember -Function Initialize-Directory, Stop-VenvProcesses, Remove-PathRobust, Move-PathToQuarantine, Remove-StaleQuarantines, Add-PythonScriptsDirToPath
