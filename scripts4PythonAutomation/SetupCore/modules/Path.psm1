#Requires -Version 5.1
# =============================================================================
# Module  : Path.psm1
# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Idempotent PATH management for installed CLI tools.

.DESCRIPTION
    Updates the current PowerShell process and persists PATH changes for future
    terminal sessions. On Windows this writes the current user's environment
    PATH. On zsh/bash hosts it also writes guarded entries to the detected shell
    startup file so new terminal sessions can resolve installed CLI tools.
#>

function Get-SetupPathSeparator {
    if ($env:OS -eq 'Windows_NT') { return ';' }
    return ':'
}

function Split-SetupPathList {
    param([AllowNull()][string] $PathValue)
    if (-not $PathValue) { return @() }

    $separator = Get-SetupPathSeparator
    @($PathValue -split [regex]::Escape($separator) |
        ForEach-Object { $_.Trim().Trim('"').Trim("'") } |
        Where-Object { $_ })
}

function Test-SetupPathContains {
    param(
        [string[]] $Entries,
        [Parameter(Mandatory=$true)][string] $Directory
    )

    $comparison = if ($env:OS -eq 'Windows_NT') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }

    $target = $Directory.Trim().Trim('"').Trim("'")
    foreach ($entry in @($Entries)) {
        if ($entry.Trim().Trim('"').Trim("'").Equals($target, $comparison)) {
            return $true
        }
    }
    return $false
}

function Get-ValidPathDirectories {
    param([Parameter(Mandatory=$true)][string[]] $Directories)

    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in @($Directories)) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($dir.Trim().Trim('"').Trim("'"))
        } catch {
            continue
        }
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        if (-not (Test-SetupPathContains -Entries $result -Directory $full)) {
            $result.Add($full)
        }
    }
    return @($result)
}

function Add-DirectoriesToProcessPath {
    param([Parameter(Mandatory=$true)][string[]] $Directories)

    $separator = Get-SetupPathSeparator
    $entries = Split-SetupPathList -PathValue $env:PATH
    $changed = $false

    foreach ($dir in @($Directories)) {
        if (Test-SetupPathContains -Entries $entries -Directory $dir) { continue }
        $entries = @($dir) + @($entries)
        $changed = $true
    }

    if ($changed) {
        $env:PATH = ($entries -join $separator)
    }
    return $changed
}

function Add-DirectoriesToWindowsUserPath {
    param([Parameter(Mandatory=$true)][string[]] $Directories)

    if ($env:OS -ne 'Windows_NT') { return $false }

    try {
        $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
        $entries = Split-SetupPathList -PathValue $userPath
        $changed = $false

        foreach ($dir in @($Directories)) {
            if (Test-SetupPathContains -Entries $entries -Directory $dir) { continue }
            $entries = @($dir) + @($entries)
            $changed = $true
        }

        if ($changed) {
            [System.Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
        }
        return $changed
    } catch {
        Write-Host ("  [WARN] Could not update user PATH: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
        return $false
    }
}

function Get-SetupShellName {
    if ($env:SHELL) {
        try { return ([System.IO.Path]::GetFileName($env:SHELL)).ToLowerInvariant() } catch { }
    }
    if ($env:ZSH_NAME) { return 'zsh' }
    if ($env:BASH) { return 'bash' }
    return $null
}

function Get-SetupShellProfilePath {
    $homeDir = [System.Environment]::GetFolderPath('UserProfile')
    if (-not $homeDir) { return $null }

    switch (Get-SetupShellName) {
        'zsh'  { return (Join-Path $homeDir '.zshrc') }
        'bash' { return (Join-Path $homeDir '.bashrc') }
        default { return $null }
    }
}

function ConvertTo-ShellSingleQuotedString {
    param([Parameter(Mandatory=$true)][string] $Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Add-DirectoriesToShellProfilePath {
    param([Parameter(Mandatory=$true)][string[]] $Directories)

    $profilePath = Get-SetupShellProfilePath
    if (-not $profilePath) { return $false }

    $content = ''
    if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
        $content = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
    } else {
        $parent = Split-Path $profilePath -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -LiteralPath $parent | Out-Null
        }
        New-Item -ItemType File -LiteralPath $profilePath -Force | Out-Null
    }

    $linesToAdd = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in @($Directories)) {
        if ($content -and $content.IndexOf($dir, [System.StringComparison]::Ordinal) -ge 0) { continue }
        $quoted = ConvertTo-ShellSingleQuotedString -Value $dir
        $linesToAdd.Add(('if [ -d {0} ]; then case ":$PATH:" in *":{1}:"*) ;; *) export PATH={1}:"$PATH" ;; esac; fi' -f $quoted, $quoted))
    }

    if ($linesToAdd.Count -eq 0) { return $false }

    $blockLines = @('', '# Added by python_venv_Automation setup: installed CLI tools') + $linesToAdd.ToArray()
    $block = $blockLines -join [Environment]::NewLine

    Add-Content -LiteralPath $profilePath -Value $block -Encoding UTF8
    Write-Host ("  Updated shell startup file for future sessions: {0}" -f $profilePath) -ForegroundColor DarkGray
    return $true
}

function Add-ToolDirsToPath {
<#
.SYNOPSIS
    Adds installed CLI directories to PATH now and for future shell sessions.
#>
    param(
        [Parameter(Mandatory=$true)][string[]] $Directories,
        [string] $Reason = 'installed CLI tool'
    )

    $validDirs = @(Get-ValidPathDirectories -Directories $Directories)
    if ($validDirs.Count -eq 0) { return @() }

    $processChanged = Add-DirectoriesToProcessPath -Directories $validDirs
    $userChanged = Add-DirectoriesToWindowsUserPath -Directories $validDirs
    $shellChanged = Add-DirectoriesToShellProfilePath -Directories $validDirs

    foreach ($dir in $validDirs) {
        Write-Host ("  PATH entry ready ({0}): {1}" -f $Reason, $dir) -ForegroundColor DarkGray
    }
    if ($processChanged) {
        Write-Host '  Updated PATH for this setup process.' -ForegroundColor DarkGray
    }
    if ($userChanged) {
        Write-Host '  Updated current user PATH for future Windows sessions.' -ForegroundColor DarkGray
    }
    if (-not $userChanged -and -not $shellChanged -and $env:OS -ne 'Windows_NT') {
        Write-Host '  [WARN] Could not detect zsh/bash startup file for persistent PATH update.' -ForegroundColor DarkYellow
    }

    return $validDirs
}

Export-ModuleMember -Function Add-ToolDirsToPath, Get-ValidPathDirectories, Test-SetupPathContains
