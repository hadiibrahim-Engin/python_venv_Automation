#Requires -Version 5.1
# =============================================================================
# Module  : Filesystem.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    File and process utility helpers for setup cleanup operations.
#>

<#
.SYNOPSIS
    Ensures a directory exists and returns its path.
#>
function Initialize-Directory {
    param([Parameter(Mandatory=$true)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -LiteralPath $Path | Out-Null
    }
    $Path
}

<#
.SYNOPSIS
    Stops processes executing from the target venv path.

.DESCRIPTION
    Identifies python/pip/poetry executables running from .venv\Scripts and
    force-stops them to release file locks for deletion.
#>
function Stop-VenvProcesses {
    param([Parameter(Mandatory=$true)][string] $VenvDir)

    try {
        $venvFull = (Resolve-Path -LiteralPath $VenvDir -ErrorAction Stop).Path
    } catch {
        $venvFull = $VenvDir
    }
    $venvFullLower = $venvFull.ToLowerInvariant()
    $scriptDir = Join-Path $venvFull 'Scripts'
    $targets = @(
        (Join-Path $scriptDir 'python.exe'),
        (Join-Path $scriptDir 'pythonw.exe'),
        (Join-Path $scriptDir 'pip.exe'),
        (Join-Path $scriptDir 'poetry.exe')
    ) | ForEach-Object { $_.ToLowerInvariant() }

    Write-Host "Checking for running processes in venv: $VenvDir" -ForegroundColor Yellow
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try {
            if (-not $_.Path) { return $false }
            $p = $_.Path.ToLowerInvariant()
            return $p.StartsWith($venvFullLower) -or ($targets -contains $p)
        } catch { $false }
    }

    foreach ($p in $procs) {
        try {
            Write-Host "Stopping process $($p.Name) (PID $($p.Id)) -> $($p.Path)" -ForegroundColor Yellow
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
        } catch {
            Write-Host "Could not stop PID $($p.Id): $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
}

<#
.SYNOPSIS
    Removes a path with retries and lock-mitigation steps.
#>
function Remove-PathRobust {
    param(
        [Parameter(Mandatory=$true)][string] $Path,
        [int] $MaxRetry = 8,
        [int] $DelayMs = 700
    )

    for ($i = 1; $i -le $MaxRetry; $i++) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return $true }

            # Clear read-only / hidden / system attributes — native bulk
            # operations are orders of magnitude faster than a PowerShell
            # Get-ChildItem -Recurse loop for large venvs (thousands of files).
            if ($env:OS -eq 'Windows_NT') {
                # attrib /S applies to all files in subdirs; /D includes dirs too.
                try { & "$env:SystemRoot\System32\attrib.exe" -R -H -S /S /D $Path } catch { }
            } else {
                try { chmod -R u+w $Path } catch { }
            }

            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            Write-Host "Delete attempt $i/$MaxRetry failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
            Start-Sleep -Milliseconds $DelayMs
            Stop-VenvProcesses -VenvDir $Path
        }
    }
    $false
}

<#
.SYNOPSIS
    Moves a locked path aside for deferred cleanup.

.DESCRIPTION
    Renames the path to a timestamped stale suffix and starts a background
    best-effort removal process.
#>
function Move-PathToQuarantine {
    param([Parameter(Mandatory=$true)][string] $Path)

    $stamp = (Get-Date -Format 'yyyyMMdd_HHmmss')
    $dst = "$Path._stale_$stamp"
    try {
        Move-Item -LiteralPath $Path -Destination $dst -ErrorAction Stop
        Write-Host "Quarantined locked venv to: $dst" -ForegroundColor Yellow

        # Background best-effort delete.
        # The path is encoded as UTF-16LE base64 so it can be decoded safely inside
        # the -Command string without any quoting - base64 characters never break
        # single-quoted string literals.
        $pathBytes = [System.Text.Encoding]::Unicode.GetBytes($dst)
        $pathB64   = [Convert]::ToBase64String($pathBytes)
        $cmd = "Start-Sleep 5; Try { `$p = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$pathB64')); Remove-Item -Recurse -Force -LiteralPath `$p } Catch {}"
        if ($env:OS -eq 'Windows_NT') {
            $ps = [System.IO.Path]::GetFullPath("$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")
            Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-Command', $cmd) | Out-Null
        } else {
            $pwshCmd = Get-Command 'pwsh' -ErrorAction SilentlyContinue
            if ($pwshCmd) {
                Start-Process -FilePath $pwshCmd.Source -ArgumentList @('-NoProfile', '-Command', $cmd) | Out-Null
            }
        }

        return $dst
    } catch {
        Write-Host "Could not quarantine venv: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $null
    }
}

<#
.SYNOPSIS
    Removes all quarantined / backup venv directories left in the project root.

.DESCRIPTION
    Cleans up two kinds of leftover directories created by failed setup runs:
      .venv._stale_<timestamp>   - quarantined by Move-PathToQuarantine (locked files)
      .venv_backup_<timestamp>   - snapshot created before venv recreation

.PARAMETER ProjectRoot
    Project directory to scan.

.OUTPUTS
    Number of directories removed.
#>
function Remove-StaleQuarantines {
    param([Parameter(Mandatory=$true)][string] $ProjectRoot)

    $patterns = @('.venv._stale_*', '.venv_backup_*')
    $found    = [System.Collections.Generic.List[string]]::new()

    foreach ($p in $patterns) {
        $items = Get-ChildItem -LiteralPath $ProjectRoot -Directory -Filter $p -ErrorAction SilentlyContinue
        foreach ($d in $items) { $found.Add($d.FullName) }
    }

    if ($found.Count -eq 0) { return 0 }

    Write-Host ("  Found {0} stale venv director{1} to clean up." -f $found.Count, $(if ($found.Count -eq 1) {'y'} else {'ies'})) -ForegroundColor DarkGray
    $removed = 0
    foreach ($dir in $found) {
        if (Remove-PathRobust -Path $dir -MaxRetry 3 -DelayMs 400) {
            Write-Host ("  Removed: {0}" -f (Split-Path $dir -Leaf)) -ForegroundColor DarkGray
            $removed++
        } else {
            Write-Host ("  Could not remove (still locked): {0}" -f (Split-Path $dir -Leaf)) -ForegroundColor Yellow
        }
    }
    return $removed
}

<#
.SYNOPSIS
    Adds the pip scripts directory for a given Python interpreter to PATH.
    Call this after a pip install to make the installed console-script visible.
#>
function Add-PythonScriptsDirToPath {
    param([Parameter(Mandatory=$true)][string] $PythonExe)
    try {
        # Probe both system and user scripts dirs — pip may install to either.
        # On Windows the user scheme is 'nt_user'; on Linux/macOS it is 'posix_user'.
        $pyCode = "import sysconfig,os; s=sysconfig.get_path('scripts'); u=sysconfig.get_path('scripts',os.name+'_user'); print(os.pathsep.join(d for d in [s,u] if d))"
        $output = (& $PythonExe -c $pyCode 2>$null).Trim()
        foreach ($scriptsDir in ($output -split [System.IO.Path]::PathSeparator)) {
            $scriptsDir = $scriptsDir.Trim()
            if ($scriptsDir -and (Test-Path $scriptsDir -PathType Container) -and ($env:PATH -notlike "*$scriptsDir*")) {
                $env:PATH = "$scriptsDir$([System.IO.Path]::PathSeparator)$env:PATH"
            }
        }
    } catch { }
}

Export-ModuleMember -Function Initialize-Directory, Stop-VenvProcesses, Remove-PathRobust, Move-PathToQuarantine, Remove-StaleQuarantines, Add-PythonScriptsDirToPath