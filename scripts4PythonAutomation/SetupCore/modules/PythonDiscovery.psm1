#Requires -Version 5.1
# =============================================================================
# Module  : PythonDiscovery.psm1

# Author  : Hadi Ibrahim
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Python discovery, selection, and installation helpers.

.DESCRIPTION
    Finds locally installed Python interpreters, filters by pyproject
    constraints, chooses the best candidate, and can install a missing
    required Python version through python.org installer download.
#>

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'UI.psm1')            -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Versioning.psm1')    -Force -DisableNameChecking -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'NativeCommand.psm1') -Force -DisableNameChecking -ErrorAction Stop

# Compiled once at module load; reused by every version-extraction call.
# [Compiled] tells .NET to JIT the pattern on first use — measurably faster
# when called 20+ times during Python discovery across many candidates.
$script:_versionRegex = [System.Text.RegularExpressions.Regex]::new(
    '\d+\.\d+\.\d+',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

<#
.SYNOPSIS
    Enumerates all Python interpreters visible to the current user without
    applying any version constraint filter.

.DESCRIPTION
    Queries WHERE python, the Windows py.exe launcher (-0p), and common
    installation directories.  Each candidate is probed with --version via an
    argument list (no quoting problems); only runnable executables with a
    parseable version string are returned, sorted by descending version.

    Paths are stored as plain strings without surrounding quotes.
    [System.IO.Path]::GetFullPath normalises backslashes and preserves spaces.
#>
function Find-AllPythonInterpreters {
    [CmdletBinding()]
    param()

    $seen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[pscustomobject]]::new()

    $tryAdd = {
        param([string] $RawPath)
        # Strip surrounding whitespace and quotes; store path as a plain string
        $p = $RawPath.Trim().Trim('"').Trim("'")
        if ([string]::IsNullOrWhiteSpace($p)) { return }

        # Normalise - GetFullPath keeps backslashes and spaces intact
        try { $p = [System.IO.Path]::GetFullPath($p) } catch { return }

        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return }
        if (-not $seen.Add($p)) { return }

        try {
            # Probe via argument list - -NoLog suppresses [CMD] line, -Quiet suppresses output
            $r = Invoke-NativeCommand -Executable $p -Arguments @('--version') -Quiet -NoLog
            if (-not $r.Succeeded) { return }
            $vStr = $script:_versionRegex.Match("$($r.StdOut) $($r.StdErr)").Value
            if (-not $vStr) { return }
            $result.Add([pscustomobject]@{ Version = [Version]$vStr; Exe = $p })
        } catch { }
    }

    # 1. where.exe python - all python.exe entries on PATH
    try {
        $whereOut = & 'where.exe' 'python' 2>$null
        foreach ($line in ($whereOut -split "`r?`n")) { & $tryAdd $line }
    } catch { }

    # 2. py -0p - Windows Launcher lists all registered versions with full paths
    $pyExe = $null
    $pyCmd = Get-Command 'py' -ErrorAction SilentlyContinue
    if ($pyCmd) {
        $pyExe = $pyCmd.Source
    } elseif (Test-Path (Join-Path $env:SystemRoot 'py.exe') -PathType Leaf) {
        $pyExe = Join-Path $env:SystemRoot 'py.exe'
    }

    if ($pyExe) {
        try {
            # Argument list call - avoids quoting edge cases for paths with spaces
            $py0p = Invoke-NativeCommand -Executable $pyExe -Arguments @('-0p') -Quiet
            foreach ($line in (($py0p.StdOut + "`n" + $py0p.StdErr) -split "`r?`n")) {
                # Format varies: "  -V:3.12   C:\...\python.exe"
                # Take the last whitespace-separated token that looks like python.exe
                $parts = $line.Trim() -split '\s+'
                $last  = $parts[-1]
                if ($last -like '*python*.exe') { & $tryAdd $last }
            }
        } catch { }
    }

    # 3. Standard python.org installer locations (brief scan, not exhaustive)
    $candidateRoots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
        $env:ProgramFiles,
        "${env:ProgramFiles(x86)}"
    )
    foreach ($root in $candidateRoots) {
        if (-not $root -or -not (Test-Path $root -PathType Container)) { continue }
        foreach ($dir in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -match '^[Pp]ython\d' })) {
            & $tryAdd (Join-Path $dir.FullName 'python.exe')
        }
    }

    $result | Sort-Object Version -Descending
}

<#
.SYNOPSIS
    Interactively prompts the user to select a compatible Python interpreter.

.DESCRIPTION
    Discovers all local Python interpreters once (Find-AllPythonInterpreters),
    then loops until a valid, constraint-satisfying interpreter is chosen.

    Each loop iteration:
      - Displays the numbered interpreter list
      - Reads the user's choice (number or full path string)
      - Normalises the path with GetFullPath (no pre-quoting)
      - Tests existence (Test-Path -LiteralPath -PathType Leaf)
      - Tests executability (--version via argument list, no CMD log)
      - Checks version against pyproject.toml requires-python

    On version mismatch the error is shown and the loop restarts - the user
    can pick again or enter a different path.  Only an empty input aborts.

.PARAMETER Constraints
    Parsed version constraints from ConvertTo-VersionConstraints.

.PARAMETER RequiresPythonRaw
    The raw requires-python string, used verbatim in error messages.

.OUTPUTS
    PSCustomObject with Version, Directory, Exe, DllName.
    Caller is responsible for adding the Source property.
#>
function Select-PythonInteractively {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[hashtable]] $Constraints,
        [Parameter(Mandatory=$true)][string] $RequiresPythonRaw,
        [switch] $AllowInstall
    )

    Write-Host ''
    Write-Host '  Searching for available Python interpreters ...' -ForegroundColor Yellow
    $allInterpreters = @(Find-AllPythonInterpreters)

    # Only show interpreters that satisfy the pyproject.toml constraint.
    $compatible = @($allInterpreters | Where-Object { Test-VersionConstraints -Version $_.Version -Constraints $Constraints })

    while ($true) {
        # Show the filtered list at the start of every iteration so the user
        # always has context after a failed attempt.
        Write-Host ''
        if ($compatible.Count -gt 0) {
            Write-Host ("  Compatible Python interpreters for '{0}':" -f $RequiresPythonRaw) -ForegroundColor Cyan
            for ($i = 0; $i -lt $compatible.Count; $i++) {
                $interp = $compatible[$i]
                Write-Host ("    [{0,2}]  Python {1,-12}  {2}" -f ($i + 1), $interp.Version, $interp.Exe) -ForegroundColor DarkGray
            }
        } else {
            Write-Host ("  No compatible Python version found locally for '{0}'." -f $RequiresPythonRaw) -ForegroundColor Yellow
        }

        Write-Host ''
        Write-Host ("  Required: Python {0}  (from pyproject.toml)" -f $RequiresPythonRaw) -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  Input:' -ForegroundColor DarkGray
        if ($compatible.Count -gt 0) {
            $nums = (1..$compatible.Count | ForEach-Object { "[$_]" }) -join ', '
            Write-Host ("    {0,-18}  Use an interpreter from the list" -f $nums) -ForegroundColor DarkGray
            Write-Host "    <Path>              Enter the full path to python.exe" -ForegroundColor DarkGray
        } elseif ($AllowInstall) {
            Write-Host "    [i]                 Auto-install Python $RequiresPythonRaw from python.org" -ForegroundColor DarkGray
            Write-Host "    <Path>              Enter the full path to a compatible python.exe" -ForegroundColor DarkGray
        } else {
            Write-Host "    <Path>              Enter the full path to a compatible python.exe" -ForegroundColor DarkGray
        }
        Write-Host "    (empty) + Enter     Abort setup" -ForegroundColor DarkGray
        Write-Host ''

        $raw = Read-Host '  Your choice'
        # Strip surrounding whitespace and quotes; never pre-quote stored paths
        $raw = $raw.Trim().Trim('"').Trim("'")

        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw 'No Python interpreter selected. Setup aborted.'
        }

        # Auto-install option
        if ($AllowInstall -and $raw -ieq 'i') {
            Write-Host ''
            Write-Host '  Starting automatic Python installation ...' -ForegroundColor Yellow
            try {
                $installedExe = Install-RequiredPython -Constraints $Constraints
            } catch {
                Write-Host ''
                Write-Host ("[ERROR] Automatic installation failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
                Write-Host '         Please install Python manually and then enter the path.' -ForegroundColor Yellow
                continue
            }

            # Re-discover compatible interpreters after install.
            Write-Host '  Searching again for compatible Python interpreters ...' -ForegroundColor Yellow
            $allInterpreters = @(Find-AllPythonInterpreters)
            $compatible = @($allInterpreters | Where-Object { Test-VersionConstraints -Version $_.Version -Constraints $Constraints })

            # Installer-race guard: if re-discovery still misses the exe, validate it directly.
            if ($compatible.Count -eq 0 -and $installedExe -and (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
                $vProbe = Invoke-NativeCommand -Executable $installedExe -Arguments @('--version') -Quiet -NoLog
                if ($vProbe.Succeeded) {
                    $vStr = $script:_versionRegex.Match("$($vProbe.StdOut) $($vProbe.StdErr)").Value
                    if ($vStr) {
                        $foundVer = [Version]$vStr
                        if (Test-VersionConstraints -Version $foundVer -Constraints $Constraints) {
                            Write-Host ("  Python {0} accepted: {1}" -f $foundVer, $installedExe) -ForegroundColor Green
                            return [pscustomobject]@{
                                Version   = $foundVer
                                Directory = Split-Path $installedExe
                                Exe       = $installedExe
                                DllName   = ("python{0}{1}.dll" -f $foundVer.Major, $foundVer.Minor)
                            }
                        }
                    }
                }
            }

            continue
        }

        # Resolve: list number (from compatible list) or raw path string
        $resolvedExe = $null
        $asInt = 0
        if ([int]::TryParse($raw, [ref]$asInt) -and $asInt -ge 1 -and $asInt -le $compatible.Count) {
            $resolvedExe = $compatible[$asInt - 1].Exe
        } else {
            # Normalise path - plain string, no surrounding quotes
            try {
                $resolvedExe = [System.IO.Path]::GetFullPath($raw)
            } catch {
                Write-Host ("  Ungaeltiger Pfad: {0}" -f $raw) -ForegroundColor Red
                continue
            }
        }

        # Existence check
        if (-not (Test-Path -LiteralPath $resolvedExe -PathType Leaf)) {
            Write-Host ("  Path '{0}' was not found." -f $resolvedExe) -ForegroundColor Red
            continue
        }

        # Executability check - -NoLog suppresses [CMD] line, -Quiet suppresses output
        $vResult = Invoke-NativeCommand -Executable $resolvedExe -Arguments @('--version') -Quiet -NoLog
        if (-not $vResult.Succeeded) {
            Write-Host ("  Could not start interpreter (exit {0}): {1}" -f $vResult.ExitCode, $resolvedExe) -ForegroundColor Red
            continue
        }

        # Version extraction
        $vText  = "{0} {1}" -f $vResult.StdOut, $vResult.StdErr
        $vMatch = $script:_versionRegex.Match($vText)
        if (-not $vMatch.Success) {
            Write-Host '  Could not determine Python version.' -ForegroundColor Red
            continue
        }
        $foundVer = [Version]$vMatch.Value

        # Version mismatch - show error and loop back; user can pick again
        if (-not (Test-VersionConstraints -Version $foundVer -Constraints $Constraints)) {
            Write-Host ''
            Write-Host ("[ERROR] Python {0} does not satisfy the pyproject.toml constraint '{1}'." -f $foundVer, $RequiresPythonRaw) -ForegroundColor Red
            Write-Host ("        Interpreter: {0}" -f $resolvedExe) -ForegroundColor Red
            Write-Host ''
            Write-Host '        Please enter an interpreter that meets the TOML constraint.' -ForegroundColor Yellow
            Write-Host "         Alternativ: 'requires-python' in pyproject.toml anpassen und Setup neu starten." -ForegroundColor Yellow
            continue
        }

        Write-Host ("  Python {0} accepted: {1}" -f $foundVer, $resolvedExe) -ForegroundColor Green
        return [pscustomobject]@{
            Version   = $foundVer
            Directory = Split-Path $resolvedExe
            Exe       = $resolvedExe
            DllName   = ("python{0}{1}.dll" -f $foundVer.Major, $foundVer.Minor)
        }
    }
}

<#
.SYNOPSIS
    Shows EVERY Python interpreter found on this PC and lets the user pick one.

.DESCRIPTION
    Unlike Select-PythonInteractively (which shows only constraint-compatible
    versions), this function lists ALL installed Pythons - marking each one as
    compatible or incompatible with the pyproject.toml constraint - and lets the
    user make the final call.

    Workflow:
      1. Calls Find-AllPythonInterpreters to discover every Python on the machine.
      2. Renders a numbered table with a [OK] / [--] compatibility badge per row.
      3. The user picks a number from the list.
      4. If the chosen version is incompatible the user is warned and the loop
         restarts - the constraint is always enforced so the rest of setup is safe.

.PARAMETER Constraints
    Parsed version constraints from ConvertTo-VersionConstraints.

.PARAMETER RequiresPythonRaw
    The raw requires-python string shown verbatim in messages.

.OUTPUTS
    PSCustomObject with Version, Directory, Exe, DllName.
    Caller is responsible for adding the Source property.
#>
function Select-AllPythonInteractively {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[hashtable]] $Constraints,
        [Parameter(Mandatory=$true)][string] $RequiresPythonRaw
    )

    Write-Host ''
    Write-Host '  Scanning for ALL Python installations on this machine ...' -ForegroundColor Yellow
    $allInterpreters = @(Find-AllPythonInterpreters)

    if ($allInterpreters.Count -eq 0) {
        throw 'No Python installations found on this machine. Install Python first and re-run setup.'
    }

    while ($true) {
        Write-Host ''
        Write-Host ('  {0,-6}  {1,-5}  {2,-14}  {3}' -f 'Choice', 'State', 'Version', 'Path') -ForegroundColor Cyan
        Write-Host ('  {0}' -f ('-' * 80)) -ForegroundColor DarkGray

        for ($i = 0; $i -lt $allInterpreters.Count; $i++) {
            $interp      = $allInterpreters[$i]
            $isCompatible = Test-VersionConstraints -Version $interp.Version -Constraints $Constraints
            $badge       = if ($isCompatible) { '[OK] ' } else { '[--] ' }
            $color       = if ($isCompatible) { 'Green' } else { 'DarkGray' }
            Write-Host ('  [{0,2}]    {1}  Python {2,-8}  {3}' -f ($i + 1), $badge, $interp.Version, $interp.Exe) -ForegroundColor $color
        }

        Write-Host ''
        Write-Host ("  Required by pyproject.toml : python {0}" -f $RequiresPythonRaw) -ForegroundColor Cyan
        Write-Host '  [OK] = satisfies constraint    [--] = incompatible' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  Enter a number from the list above, or press Enter to abort.' -ForegroundColor DarkGray
        Write-Host ''

        $raw = (Read-Host '  Your choice').Trim().Trim('"').Trim("'")

        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw 'No selection made. Setup aborted.'
        }

        # Resolve number to exe path
        $asInt = 0
        if (-not ([int]::TryParse($raw, [ref]$asInt)) -or $asInt -lt 1 -or $asInt -gt $allInterpreters.Count) {
            Write-Host ("  '{0}' is not a valid number from the list above." -f $raw) -ForegroundColor Red
            continue
        }

        $resolvedExe = $allInterpreters[$asInt - 1].Exe

        # Existence check (defensive - Find-AllPythonInterpreters already verified this)
        if (-not (Test-Path -LiteralPath $resolvedExe -PathType Leaf)) {
            Write-Host ("  Executable no longer found at: {0}" -f $resolvedExe) -ForegroundColor Red
            Write-Host '  Re-scanning ...' -ForegroundColor DarkGray
            $allInterpreters = @(Find-AllPythonInterpreters)
            continue
        }

        # Get exact version via --version
        $vResult = Invoke-NativeCommand -Executable $resolvedExe -Arguments @('--version') -Quiet -NoLog
        if (-not $vResult.Succeeded) {
            Write-Host ("  Could not start interpreter (exit {0}): {1}" -f $vResult.ExitCode, $resolvedExe) -ForegroundColor Red
            continue
        }

        $vText  = '{0} {1}' -f $vResult.StdOut, $vResult.StdErr
        $vMatch = $script:_versionRegex.Match($vText)
        if (-not $vMatch.Success) {
            Write-Host '  Could not determine Python version from this executable.' -ForegroundColor Red
            continue
        }
        $foundVer = [Version]$vMatch.Value

        # Constraint check - enforce; user must pick a compatible interpreter
        if (-not (Test-VersionConstraints -Version $foundVer -Constraints $Constraints)) {
            Write-Host ''
            Write-Host ('[INCOMPATIBLE] Python {0} does not satisfy the pyproject.toml constraint: python {1}' -f $foundVer, $RequiresPythonRaw) -ForegroundColor Red
            Write-Host '               Please pick a version marked [OK] in the list.' -ForegroundColor Yellow
            Write-Host "               To allow a different Python version, update 'python' in pyproject.toml and re-run setup." -ForegroundColor DarkGray
            continue
        }

        Write-Host ("  Selected: Python {0}  ->  {1}" -f $foundVer, $resolvedExe) -ForegroundColor Green
        return [pscustomobject]@{
            Version   = $foundVer
            Directory = Split-Path $resolvedExe
            Exe       = $resolvedExe
            DllName   = ('python{0}{1}.dll' -f $foundVer.Major, $foundVer.Minor)
        }
    }
}

<#
.SYNOPSIS
    Discovers Python installations matching version constraints.

.DESCRIPTION
    Probes PATH, registry, common install locations, conda layouts, and
    py.exe launcher mappings, then returns matching candidates sorted by
    descending version.
#>
function Find-PythonInstallations {
    param([Parameter(Mandatory=$true)][System.Collections.Generic.List[hashtable]] $Constraints)

    $seen       = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $candidates = [System.Collections.Generic.List[pscustomobject]]::new()

    $addExe = {
        param([string] $Exe)
        if (-not (Test-Path $Exe -PathType Leaf)) { return }

        # Canonicalize launchers/shims to the real interpreter path.
        $candidateExe = $Exe
        try {
            $probeScript = "import sys; print(getattr(sys, '_base_executable', '') or sys.executable)"
            $resolvedExe = (& "$Exe" -c $probeScript 2>$null | Select-Object -First 1)
            if ($resolvedExe) {
                $resolvedExe = $resolvedExe.Trim()
                if ($resolvedExe -and (Test-Path $resolvedExe -PathType Leaf)) {
                    $candidateExe = $resolvedExe
                }
            }
        } catch { }

        if (-not $seen.Add($candidateExe)) { return }
        try {
            $raw  = & "$candidateExe" --version 2>&1
            $vStr = $script:_versionRegex.Match("$raw").Value
            if (-not $vStr) { return }
            $ver  = [Version]$vStr
            if (Test-VersionConstraints -Version $ver -Constraints $Constraints) {
                $candidates.Add([pscustomobject]@{
                    Version   = $ver
                    Directory = Split-Path $candidateExe
                    Exe       = $candidateExe
                })
            }
        } catch { }
    }

    # Detect platform once - used to enable/skip OS-specific sections below.
    $onWindows = $env:OS -eq 'Windows_NT'

    # 1. PATH - works on all platforms.
    #    Windows: accept .exe files, skip py.exe launcher.
    #    macOS/Linux: accept any Application command named python* (no extension).
    foreach ($cmd in (Get-Command 'python*' -ErrorAction SilentlyContinue)) {
        if ($cmd.CommandType -ne 'Application') { continue }
        if ($cmd.Name -eq 'py.exe') { continue }
        if ($onWindows -and $cmd.Source -notlike '*.exe') { continue }
        & $addExe $cmd.Source
    }

    # 1b. macOS / Linux well-known paths.
    #     These are skipped on Windows (exe does not exist → addExe no-ops).
    if (-not $onWindows) {
        $homeDir = $env:HOME
        foreach ($exe in @(
            '/usr/bin/python3',
            '/usr/bin/python',
            '/usr/local/bin/python3',
            '/usr/local/bin/python',
            '/opt/homebrew/bin/python3',     # Apple Silicon Homebrew
            '/usr/local/opt/python3/bin/python3', # Intel Homebrew
            '/opt/local/bin/python3'          # MacPorts
        )) {
            & $addExe $exe
        }
        # Homebrew versioned pythons: /opt/homebrew/opt/python@3.X/bin/python3.X
        foreach ($brewDir in @('/opt/homebrew/opt', '/usr/local/opt')) {
            if (-not (Test-Path $brewDir -PathType Container)) { continue }
            foreach ($d in (Get-ChildItem $brewDir -Directory -Filter 'python@3*' -ErrorAction SilentlyContinue)) {
                & $addExe (Join-Path $d.FullName 'bin/python3')
                foreach ($f in (Get-ChildItem (Join-Path $d.FullName 'bin') -Filter 'python3.*' -ErrorAction SilentlyContinue)) {
                    & $addExe $f.FullName
                }
            }
        }
        # pyenv shims: ~/.pyenv/versions/3.X.Y/bin/python3
        if ($homeDir) {
            $pyenvVersions = Join-Path $homeDir '.pyenv/versions'
            if (Test-Path $pyenvVersions -PathType Container) {
                foreach ($v in (Get-ChildItem $pyenvVersions -Directory -ErrorAction SilentlyContinue)) {
                    & $addExe (Join-Path $v.FullName 'bin/python3')
                    & $addExe (Join-Path $v.FullName 'bin/python')
                }
            }
        }
        # Conda on macOS: ~/opt/anaconda3, ~/miniconda3, ~/miniforge3
        if ($homeDir) {
            foreach ($base in @(
                (Join-Path $homeDir 'opt/anaconda3'),
                (Join-Path $homeDir 'anaconda3'),
                (Join-Path $homeDir 'miniconda3'),
                (Join-Path $homeDir 'miniforge3'),
                '/opt/anaconda3',
                '/opt/miniconda3'
            )) {
                & $addExe (Join-Path $base 'bin/python3')
                $envsDir = Join-Path $base 'envs'
                if (Test-Path $envsDir -PathType Container) {
                    foreach ($e in (Get-ChildItem $envsDir -Directory -ErrorAction SilentlyContinue)) {
                        & $addExe (Join-Path $e.FullName 'bin/python3')
                    }
                }
            }
        }
    }

    # 2. Windows Registry
    foreach ($base in @(
        'HKLM:\SOFTWARE\Python\PythonCore',
        'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore',
        'HKCU:\SOFTWARE\Python\PythonCore'
    )) {
        if (-not (Test-Path $base)) { continue }
        foreach ($vKey in (Get-ChildItem $base -ErrorAction SilentlyContinue)) {
            $ipKey = "$($vKey.PSPath)\InstallPath"
            if (-not (Test-Path $ipKey)) { continue }
            $props = Get-ItemProperty $ipKey -ErrorAction SilentlyContinue
            $dir   = $null
            if ($props -and ($props.PSObject.Properties.Name -contains '(default)')) {
                $dir = $props.'(default)'
            }
            if (-not $dir) {
                try {
                    $regItem = Get-Item -Path $ipKey -ErrorAction Stop
                    $dir = $regItem.GetValue('')
                } catch { }
            }
            if (-not $dir -and $props -and ($props.PSObject.Properties.Name -contains 'ExecutablePath') -and $props.ExecutablePath) {
                $dir = Split-Path $props.ExecutablePath
            }
            if ($dir) { & $addExe (Join-Path $dir 'python.exe') }
        }
    }

    # 3. Common Windows install directories (silently skipped on macOS/Linux).
    foreach ($base in @(
        "$env:LOCALAPPDATA\Programs\Python",
        "$env:APPDATA\Python",
        "$env:ProgramFiles\Python",
        "$env:ProgramFiles\Python3",
        'C:\Python'
    ) | Where-Object { $_ }) {
        if (-not (Test-Path $base -PathType Container)) { continue }
        foreach ($sub in (Get-ChildItem $base -Directory -ErrorAction SilentlyContinue)) {
            & $addExe (Join-Path $sub.FullName 'python.exe')
        }
        & $addExe (Join-Path $base 'python.exe')
    }

    # 3b. Scan all Python3* directories directly under Program Files / LocalAppData
    #     Covers default installer paths like C:\Program Files\Python311\
    #     Filter nulls first - env vars are absent on macOS/Linux.
    foreach ($root in @($env:ProgramFiles, "${env:ProgramFiles(x86)}", "$env:LOCALAPPDATA\Programs") | Where-Object { $_ }) {
        if (-not (Test-Path $root -PathType Container)) { continue }
        foreach ($dir in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -match '^[Pp]ython\d' })) {
            & $addExe (Join-Path $dir.FullName 'python.exe')
        }
    }

    # 4. Anaconda / Miniconda
    foreach ($base in @(
        "$env:LOCALAPPDATA\Continuum\anaconda3",
        "$env:USERPROFILE\anaconda3",
        "$env:USERPROFILE\miniconda3",
        'C:\ProgramData\Anaconda3',
        'C:\ProgramData\Miniconda3'
    )) {
        & $addExe (Join-Path $base 'python.exe')
        $envsDir = Join-Path $base 'envs'
        if (Test-Path $envsDir) {
            foreach ($e in (Get-ChildItem $envsDir -Directory -ErrorAction SilentlyContinue)) {
                & $addExe (Join-Path $e.FullName 'python.exe')
            }
        }
    }

    # 5. Custom layouts under C:\LocalData
    foreach ($dir in (Get-ChildItem 'C:\LocalData' -Directory -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match 'anaconda|miniconda|python' })) {
        & $addExe (Join-Path $dir.FullName 'python.exe')
    }

    # 6. py.exe Windows Launcher - reads registry directly, finds versions not on PATH.
    #    This is the most reliable source right after a fresh install (registry is updated
    #    before PATH propagates to the current process).  Windows-only.
    $pyLauncher = Get-Command 'py' -ErrorAction SilentlyContinue
    if (-not $pyLauncher -and $env:SystemRoot) {
        # py.exe ships with Python 3.3+ and lives in System32 on most installs.
        $systemPy = Join-Path $env:SystemRoot 'py.exe'
        if (Test-Path $systemPy -PathType Leaf) { $pyLauncher = $systemPy }
    }
    if ($pyLauncher) {
        $pyExe = if ($pyLauncher -is [string]) { $pyLauncher } else { $pyLauncher.Source }
        # Query the launcher for each plausible major.minor version.
        foreach ($ver in @('3.14','3.13','3.12','3.11','3.10','3.9','3.8')) {
            try {
                $found = & "$pyExe" "-$ver" -c 'import sys; print(sys.executable)' 2>$null
                if ($LASTEXITCODE -eq 0 -and $found) {
                    & $addExe ($found | Select-Object -First 1).Trim()
                }
            } catch { }
        }
    }

    $candidates | Sort-Object Version -Descending
}

<#
.SYNOPSIS
    Chooses the lowest satisfying Python candidate from a list of already-installed
    interpreters. Prefers what is already on the machine over a newer version.

.DESCRIPTION
    Candidates are sorted descending before being passed in (from Find-PythonInstallations).
    This function picks the LAST entry - the lowest version that still satisfies the
    constraint - so an existing Python 3.11 is preferred over 3.12 when both are
    installed and both satisfy the project's requires-python range.

.OUTPUTS
    PSCustomObject with Version, Directory, Exe, and DllName.
#>
function Select-BestPython {
    param([Parameter(Mandatory=$true)][object[]] $Candidates)
    if (-not $Candidates -or $Candidates.Count -eq 0) { return $null }
    # Candidates arrive sorted descending; pick the last (lowest) satisfying version.
    $best = $Candidates[$Candidates.Count - 1]
    [pscustomobject]@{
        Version   = $best.Version
        Directory = $best.Directory
        Exe       = $best.Exe
        DllName   = ("python{0}{1}.dll" -f $best.Version.Major, $best.Version.Minor)
    }
}

<#
.SYNOPSIS
    Extracts patch versions for a target major.minor from index HTML.

.DESCRIPTION
    Parses python.org FTP index markup and returns matching Version objects
    for entries like `3.11.9/`.
#>
function Get-PythonPatchVersionsFromIndexHtml {
    param(
        [Parameter(Mandatory=$true)][string] $Html,
        [Parameter(Mandatory=$true)][int] $Major,
        [Parameter(Mandatory=$true)][int] $Minor
    )

    $baseVersion = "{0}.{1}" -f $Major, $Minor
    $pattern = 'href\s*=\s*["'']({0}\.\d+)\/["'']' -f [regex]::Escape($baseVersion)
    $matchCollection = [System.Text.RegularExpressions.Regex]::Matches($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    $versions = New-Object System.Collections.Generic.List[Version]
    foreach ($m in $matchCollection) {
        $candidate = $m.Groups[1].Value
        try {
            $versions.Add([Version]$candidate)
        } catch { }
    }

    return $versions
}

<#
.SYNOPSIS
    Resolves the latest patch version for a major.minor line from python.org.

.DESCRIPTION
    Queries the python.org FTP index and returns the highest published
    `major.minor.patch` version string. Falls back to `<major>.<minor>.0`
    if resolution fails.
#>
function Resolve-LatestPythonPatchVersion {
    param(
        [Parameter(Mandatory=$true)][int] $Major,
        [Parameter(Mandatory=$true)][int] $Minor
    )

    $baseVersion = "{0}.{1}" -f $Major, $Minor
    $indexUrl = 'https://www.python.org/ftp/python/'

    try {
        $response = Invoke-WebRequest -Uri $indexUrl -UseBasicParsing -ErrorAction Stop
        $html = [string]$response.Content
        $versions = Get-PythonPatchVersionsFromIndexHtml -Html $html -Major $Major -Minor $Minor

        if ($versions.Count -gt 0) {
            $latest = ($versions | Sort-Object -Descending | Select-Object -First 1).ToString()
            return $latest
        }
    } catch {
        Write-Host ("  Could not resolve latest patch for {0} from python.org index: {1}" -f $baseVersion, $_.Exception.Message) -ForegroundColor DarkYellow
    }

    return ("{0}.0" -f $baseVersion)
}

<#
.SYNOPSIS
    Checks whether a remote file URL is available.

.DESCRIPTION
    Uses an HTTP HEAD request to quickly verify whether a URL exists.
    Returns $true only for successful responses.
#>
function Test-RemoteFileExists {
    param([Parameter(Mandatory=$true)][string] $Url)

    try {
        Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    Resolves a downloadable Python installer URL for major.minor.

.DESCRIPTION
    Starts from the latest patch versions discovered on python.org and picks
    the first version where `python-<ver>-amd64.exe` is actually available.
#>
function Resolve-PythonInstallerDownload {
    param(
        [Parameter(Mandatory=$true)][int] $Major,
        [Parameter(Mandatory=$true)][int] $Minor
    )

    $latest = Resolve-LatestPythonPatchVersion -Major $Major -Minor $Minor
    $indexUrl = 'https://www.python.org/ftp/python/'

    $candidateVersions = [System.Collections.Generic.List[string]]::new()
    if ($latest) {
        [void]$candidateVersions.Add($latest)
    }

    try {
        $response = Invoke-WebRequest -Uri $indexUrl -UseBasicParsing -ErrorAction Stop
        $html = [string]$response.Content
        $versions = Get-PythonPatchVersionsFromIndexHtml -Html $html -Major $Major -Minor $Minor |
            Sort-Object -Descending |
            Select-Object -First 20

        foreach ($ver in $versions) {
            $versionStr = $ver.ToString()
            if (-not $candidateVersions.Contains($versionStr)) {
                [void]$candidateVersions.Add($versionStr)
            }
        }
    } catch {
        Write-Host ("  Could not refresh installer candidates from python.org index: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }

    if ($candidateVersions.Count -eq 0) {
        # No candidates found; try recent patch versions in reverse order.
        # Most Python releases maintain 5+ patch versions in a major.minor line.
        foreach ($patch in 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0) {
            [void]$candidateVersions.Add(("{0}.{1}.{2}" -f $Major, $Minor, $patch))
        }
    }

    foreach ($version in $candidateVersions) {
        $installerName = "python-{0}-amd64.exe" -f $version
        $downloadUrl = "https://www.python.org/ftp/python/{0}/{1}" -f $version, $installerName

        if (Test-RemoteFileExists -Url $downloadUrl) {
            return [pscustomobject]@{
                Version = $version
                InstallerName = $installerName
                DownloadUrl = $downloadUrl
            }
        }
    }

    $attemptedList = ($candidateVersions | ForEach-Object { "  - {0}" -f $_ }) -join "`n"
    $errorMsg = @(
        "Python $Major.$Minor is not available or not downloadable from python.org.",
        "",
        "Attempted versions:",
        $attemptedList,
        "",
        "Common available versions: 3.13.x, 3.12.x, 3.11.x, 3.10.x, 3.9.x, 3.8.x",
        "Future versions (3.14+) may not yet be released.",
        "",
        "Solutions:",
        "  1. Check pyproject.toml requires-python setting",
        "  2. Visit https://www.python.org/downloads/ for available versions",
        "  3. Install required version manually or update pyproject.toml"
    ) -join "`n"
    throw $errorMsg
}

<#
.SYNOPSIS
    Installs Python from python.org using built-in PowerShell primitives.

.DESCRIPTION
    Downloads the latest available patch installer for major.minor and runs it in
    silent per-user mode with PATH integration.
#>
function Install-PythonViaPythonOrg {
    param(
        [Parameter(Mandatory=$true)][int] $Major,
        [Parameter(Mandatory=$true)][int] $Minor
    )

    $resolvedInstaller = Resolve-PythonInstallerDownload -Major $Major -Minor $Minor
    $version = $resolvedInstaller.Version
    $installerName = $resolvedInstaller.InstallerName
    $downloadUrl = $resolvedInstaller.DownloadUrl
    $installerPath = Join-Path $env:TEMP $installerName

    Write-Banner "No compatible Python found. Installing Python $Major.$Minor via python.org installer ..." 'WARN'
    Write-Host ("  Version      : {0}" -f $version) -ForegroundColor DarkGray
    Write-Host ("  Installer    : {0}" -f $installerName) -ForegroundColor DarkGray
    Write-Host ("  Download URL: {0}" -f $downloadUrl) -ForegroundColor DarkGray
    Write-Host ("  Download to  : {0}" -f $installerPath) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Downloading installer ...' -ForegroundColor Yellow

    # Force TLS 1.2 for python.org and retry transient transfer failures.
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    $maxAttempts = 3
    $downloaded = $false
    $lastDownloadError = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Write-Host ("  Download attempt {0}/{1} ..." -f $attempt, $maxAttempts) -ForegroundColor DarkGray
            Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing -ErrorAction Stop
            $downloaded = $true
            Write-Host '  Download completed.' -ForegroundColor Green
            break
        } catch {
            $lastDownloadError = $_.Exception.Message
            Write-Host ("  Download attempt {0} failed: {1}" -f $attempt, $lastDownloadError) -ForegroundColor DarkYellow
            if (Test-Path $installerPath -PathType Leaf) {
                Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
            }
            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    }

    if (-not $downloaded) {
        $errorMsg = @(
            "Failed to download Python $Major.$Minor installer after $maxAttempts attempts from:",
            "  $downloadUrl",
            "",
            "Last network error: $lastDownloadError",
            "",
            "This may indicate:",
            "  1. Python $Major.$Minor is not available on python.org",
            "  2. Network connectivity problem",
            "  3. python.org is temporarily unavailable",
            "",
            "Suggested actions:",
            "  1. Verify internet connectivity",
            "  2. Check https://www.python.org/downloads/",
            "  3. Try running setup again (transient errors are retried)",
            "  4. Install Python manually and re-run setup"
        ) -join "`n"
        throw $errorMsg
    }

    try {
        Write-Host ''
        Write-Host '  Running silent installer ...' -ForegroundColor Yellow
        Write-Host '    /quiet InstallAllUsers=0 PrependPath=1 Include_test=0' -ForegroundColor DarkGray

        $result = Invoke-NativeCommand -Executable $installerPath -Arguments @(
            '/quiet',
            'InstallAllUsers=0',
            'PrependPath=1',
            'Include_test=0'
        ) -Quiet

        if (-not $result.Succeeded) {
            $details = if ($result.StdErr) { $result.StdErr.Trim() } else { $result.StdOut.Trim() }
            $suffix = if ($details) { "`nInstaller output:`n$details" } else { '' }
            throw ("Python installer failed (exit $($result.ExitCode)).$suffix")
        }
        Write-Host ("  Installer completed with exit code {0}." -f $result.ExitCode) -ForegroundColor Green
    } finally {
        if (Test-Path $installerPath -PathType Leaf) {
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
            Write-Host '  Temporary installer removed.' -ForegroundColor DarkGray
        }
    }
}

function Install-RequiredPython {
<#
.SYNOPSIS
    Installs the minimum Python version that satisfies the given constraints.
.DESCRIPTION
    Derives the required major.minor from the constraints (>=, >, == operators),
    then installs Python using python.org installer download and silent install
    with built-in PowerShell commands.
    After install, refreshes $env:Path so re-discovery in the same session works.

.PARAMETER Constraints
    Parsed comparison constraints from pyproject requires-python.
#>
    param(
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[hashtable]] $Constraints
    )

    # Derive the best major.minor to install.
    #
    # 1. Prefer the highest explicit lower bound (>=, >, ==) - that is the minimum
    #    the project requires, so installing exactly that version is always safe.
    #
    # 2. When no lower bound exists (e.g. constraint is "<=3.10" or "<3.11"),
    #    infer the highest allowed minor from the upper-bound operators so we do not
    #    install a version that is guaranteed to fail the constraint check.
    #      <=X.Y  → install X.Y   (3.11.x satisfies <=3.11)
    #      <X.Y   → install X.(Y-1)  (<3.11 → install 3.10.x)
    #      <X.0   → install (X-1).0  (<3.0  → install 2.x - unusual but handled)
    #
    # 3. Fall back to 3.11 only when there are no constraints at all.

    $minVer = $null
    foreach ($c in $Constraints) {
        if ($c.Op -in @('>=', '>', '==')) {
            if (-not $minVer -or $c.Version -gt $minVer) { $minVer = $c.Version }
        }
    }

    if (-not $minVer) {
        # No lower bound - derive the highest permissible major.minor from upper bounds.
        $ceiling = $null
        foreach ($c in $Constraints) {
            $effective = $null
            if ($c.Op -eq '<=') {
                $effective = $c.Version
            } elseif ($c.Op -eq '<') {
                if ($c.Version.Minor -gt 0) {
                    $effective = [Version]("{0}.{1}" -f $c.Version.Major, ($c.Version.Minor - 1))
                } elseif ($c.Version.Major -gt 0) {
                    $effective = [Version]("{0}.0" -f ($c.Version.Major - 1))
                }
            }
            if ($effective -and (-not $ceiling -or $effective -lt $ceiling)) {
                $ceiling = $effective
            }
        }
        if ($ceiling) { $minVer = $ceiling }
    }

    if (-not $minVer) { $minVer = [Version]'3.11' }   # no constraints at all

    $major = $minVer.Major
    $minor = $minVer.Minor
    $requestedVersion = "{0}.{1}" -f $major, $minor
    
    Write-Banner "No compatible Python found locally. Attempting download of Python $requestedVersion ..." 'WARN'
    
    try {
        Install-PythonViaPythonOrg -Major $major -Minor $minor
    } catch {
        # Re-throw with clear error header and actionable suggestion
        $baseError = $_.Exception.Message
        $errorMsg = @(
            "",
            "[ERROR] Failed to download/install Python $requestedVersion",
            "",
            $baseError,
            "",
            "═══════════════════════════════════════════════════════════════",
            "ALTERNATIVE: Provide your own Python installation",
            "═══════════════════════════════════════════════════════════════",
            "",
            "If you have Python $requestedVersion installed elsewhere,",
            "you can provide the path directly to skip the download:",
            "",
            "  .\scripts\setup-core.ps1 -PythonExePath 'C:\Path\To\python.exe'",
            "",
            "Or re-run this script and enter the path when prompted.",
            ""
        ) -join "`n"
        throw $errorMsg
    }

    # Poll for python.exe to appear in well-known install locations.
    # The installer may still be writing files after process return.
    $knownPaths = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python$major$minor\python.exe"),
        (Join-Path $env:ProgramFiles  "Python$major$minor\python.exe"),
        "${env:ProgramFiles(x86)}\Python$major$minor\python.exe"
    )

    # Poll until a known-path python.exe is present AND actually runnable.
    # The silent installer can return exit 0 before all DLLs/stdlib are fully in place,
    # so a bare Test-Path check causes a race: re-discovery runs python.exe
    # before it is functional and silently drops it as a candidate.
    $foundExe = $null
    $deadline = (Get-Date).AddSeconds(60)
    Write-Host "  Waiting for Python to become ready ..." -ForegroundColor DarkGray
    while ((Get-Date) -lt $deadline) {
        foreach ($p in $knownPaths) {
            if (-not (Test-Path $p -PathType Leaf)) { continue }
            try {
                $check = Invoke-NativeCommand -Executable $p -Arguments @('--version') -Quiet
                if ($check.Succeeded) { $foundExe = $p; break }
            } catch { }
        }
        if ($foundExe) { break }
        Start-Sleep -Seconds 2
    }

    if ($foundExe) {
        $resolvedDir = Split-Path $foundExe
        Write-Host ("  Located at: {0}" -f $foundExe) -ForegroundColor DarkGray
        if ($env:Path -notlike "*$resolvedDir*") {
            $env:Path = "$resolvedDir;$env:Path"
        }
    } else {
        # Fallback: refresh PATH from registry + try py.exe launcher
        $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path    = ($machinePath, $userPath | Where-Object { $_ }) -join ';'

        $pyExe = $null
        foreach ($candidate in @(
            (Get-Command 'py' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
            (Join-Path $env:SystemRoot 'py.exe')
        )) {
            if ($candidate -and (Test-Path $candidate -PathType Leaf)) { $pyExe = $candidate; break }
        }
        if ($pyExe) {
            try {
                $resolved = & "$pyExe" "-$major.$minor" -c 'import sys; print(sys.executable)' 2>$null
                if ($LASTEXITCODE -eq 0 -and $resolved) {
                    $resolvedPath = $resolved.Trim()
                    $resolvedDir  = Split-Path $resolvedPath
                    if ($resolvedDir -and ($env:Path -notlike "*$resolvedDir*")) {
                        $env:Path = "$resolvedDir;$env:Path"
                        Write-Host ("  Located via py.exe: {0}" -f $resolvedPath) -ForegroundColor DarkGray
                    }
                    $foundExe = $resolvedPath
                }
            } catch { }
        }
    }

    Write-Banner "Python $major.$minor installed. Re-scanning ..." 'SUCCESS'

    # Return the verified exe path so the caller can build a candidate directly
    # if re-discovery still misses it (e.g. due to registry propagation delay).
    return $foundExe
}

<#
.SYNOPSIS
    Resolves the Python interpreter to use for the project.

.DESCRIPTION
    Consolidates every branch of Python selection that used to live inline in
    Start-Setup: explicit user-provided path validation, discovery with
    constraint filtering, filtering out interpreters that live inside the
    project's own .venv, optional fallback installation via python.org, and
    the installer-race fallback that builds a candidate directly from an
    installer-verified exe.

.PARAMETER Constraints
    Parsed constraints list from ConvertTo-VersionConstraints.

.PARAMETER RequiresPythonRaw
    The raw requires-python string from pyproject.toml (used only for error
    messages so the user sees the original constraint).

.PARAMETER VenvDir
    Absolute path of the project's .venv directory. Used to exclude venv
    interpreters from discovery results.

.PARAMETER ExplicitPythonExePath
    Optional caller-provided interpreter path. When set, takes precedence
    over discovery and must satisfy the constraints.

.PARAMETER AllowInstall
    When set, allows Install-RequiredPython to download and silently install
    a Python interpreter from python.org if no local candidate satisfies the
    constraints. Default is off so tests do not silently mutate the dev
    machine.

.PARAMETER NonInteractive
    Suppresses all interactive prompts.  When set, any condition that would
    normally trigger Select-PythonInteractively (path not found, install
    failure) causes an immediate terminating error instead.

.OUTPUTS
    PSCustomObject with Version, Directory, Exe, DllName, and Source.
    Source is one of: 'explicit', 'discovered', 'installed', 'user-selected'.
#>
function Resolve-SelectedPython {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[hashtable]] $Constraints,
        [Parameter(Mandatory=$true)][string] $RequiresPythonRaw,
        [Parameter(Mandatory=$true)][string] $VenvDir,
        [Parameter()][string] $ExplicitPythonExePath,
        [Parameter()][switch] $AllowInstall,
        [Parameter()][switch] $NonInteractive,
        [Parameter()][switch] $ListMode
    )

    # Branch 0: user asked to pick from a full list of every Python on this machine.
    # Select-AllPythonInteractively shows ALL versions (not just compatible ones),
    # marks each [OK]/[--], and enforces the constraint before returning.
    if ($ListMode) {
        Write-Host 'List mode: showing all Python installations for manual selection ...' -ForegroundColor Yellow
        $listResult = Select-AllPythonInteractively -Constraints $Constraints -RequiresPythonRaw $RequiresPythonRaw
        return [pscustomobject]@{
            Version   = $listResult.Version
            Directory = $listResult.Directory
            Exe       = $listResult.Exe
            DllName   = $listResult.DllName
            Source    = 'user-selected-list'
        }
    }

    # Branch 1: explicit user-provided path
    if ($ExplicitPythonExePath) {
        Write-Host 'Using user-provided Python executable ...' -ForegroundColor Yellow

        # Normalise path - stored as a plain string without surrounding quotes;
        # GetFullPath preserves backslashes and spaces.
        $normalizedExplicit = $ExplicitPythonExePath
        try { $normalizedExplicit = [System.IO.Path]::GetFullPath($ExplicitPythonExePath) } catch { $normalizedExplicit = $ExplicitPythonExePath }

        if (-not (Test-Path -LiteralPath $normalizedExplicit -PathType Leaf)) {
            Write-Host ("  Path '{0}' was not found." -f $normalizedExplicit) -ForegroundColor Red

            if ($NonInteractive) {
                throw ("Path '{0}' was not found." -f $normalizedExplicit)
            }

            Write-Host '  Looking up alternative Python interpreters ...' -ForegroundColor Yellow
            $interResult = Select-PythonInteractively -Constraints $Constraints -RequiresPythonRaw $RequiresPythonRaw -AllowInstall:$AllowInstall
            $selected = [pscustomobject]@{
                Version   = $interResult.Version
                Directory = $interResult.Directory
                Exe       = $interResult.Exe
                DllName   = $interResult.DllName
                Source    = 'user-selected'
            }
            Write-Banner ("Using Python {0} at: {1}" -f $selected.Version, $selected.Exe) 'SUCCESS'
            return $selected
        }

        # Path exists - test executability via argument list; -NoLog suppresses [CMD] line
        $requestedExe  = $normalizedExplicit
        $versionResult = Invoke-NativeCommand -Executable $requestedExe -Arguments @('--version') -Quiet -NoLog
        if (-not $versionResult.Succeeded) {
            $details = if ($versionResult.StdErr) { $versionResult.StdErr.Trim() } else { $versionResult.StdOut.Trim() }
            $suffix  = if ($details) { "`n$details" } else { '' }
            throw ("Provided Python executable could not be started (exit {0}): {1}{2}" -f $versionResult.ExitCode, $requestedExe, $suffix)
        }

        $versionText  = "{0} {1}" -f $versionResult.StdOut, $versionResult.StdErr
        $versionMatch = $script:_versionRegex.Match($versionText)
        if (-not $versionMatch.Success) {
            throw ("Could not determine Python version from executable: {0}`nOutput: {1}" -f $requestedExe, $versionText.Trim())
        }

        $requestedVersion = [Version]$versionMatch.Value

        # Version mismatch - show error, then offer interactive selection to pick again
        if (-not (Test-VersionConstraints -Version $requestedVersion -Constraints $Constraints)) {
            Write-Host ''
            Write-Host ("[ERROR] Python {0} does not satisfy the pyproject.toml constraint '{1}'." -f $requestedVersion, $RequiresPythonRaw) -ForegroundColor Red
            Write-Host ("        Interpreter: {0}" -f $requestedExe) -ForegroundColor Red

            if ($NonInteractive) {
                throw ("Python {0} does not satisfy constraint '{1}'. Update pyproject.toml and re-run setup." -f $requestedVersion, $RequiresPythonRaw)
            }

            Write-Host ''
            Write-Host '        Please select a compatible interpreter:' -ForegroundColor Yellow
            $interResult = Select-PythonInteractively -Constraints $Constraints -RequiresPythonRaw $RequiresPythonRaw -AllowInstall:$AllowInstall
            $selected = [pscustomobject]@{
                Version   = $interResult.Version
                Directory = $interResult.Directory
                Exe       = $interResult.Exe
                DllName   = $interResult.DllName
                Source    = 'user-selected'
            }
            Write-Banner ("Using Python {0} at: {1}" -f $selected.Version, $selected.Exe) 'SUCCESS'
            return $selected
        }

        $selected = [pscustomobject]@{
            Version   = $requestedVersion
            Directory = Split-Path $requestedExe
            Exe       = $requestedExe
            DllName   = ("python{0}{1}.dll" -f $requestedVersion.Major, $requestedVersion.Minor)
            Source    = 'explicit'
        }
        Write-Banner ("Using user-provided Python {0} at: {1}" -f $selected.Version, $selected.Exe) 'SUCCESS'
        return $selected
    }

    # Branch 2: discovery
    Write-Host 'Searching for compatible Python installations ...' -ForegroundColor Yellow

    $venvFilter = {
        param($c)
        $venvDirNorm = ($VenvDir -replace '\\','/').ToLowerInvariant()
        $exeNorm     = ($c.Exe -replace '\\','/').ToLowerInvariant()
        (-not $exeNorm.StartsWith("$venvDirNorm/")) -and ($exeNorm -notmatch '/\.venv/scripts/')
    }

    $pythons = @(Find-PythonInstallations -Constraints $Constraints)
    $pythons = @($pythons | Where-Object { & $venvFilter $_ })

    $source = 'discovered'

    if ($pythons.Count -eq 0) {
        if (-not $AllowInstall) {
            throw ("No compatible Python interpreter found for constraint '{0}' and -AllowInstall is not set." -f $RequiresPythonRaw)
        }

        $installedExe = $null
        try {
            $installedExe = Install-RequiredPython -Constraints $Constraints
            $source = 'installed'
        } catch {
            $installErrMsg = $_.Exception.Message
            Write-Host ''
            Write-Banner 'Automatic Python installation failed.' 'WARN'
            Write-Host ("  Error: {0}" -f $installErrMsg) -ForegroundColor DarkYellow
            Write-Host ''
            Write-Host '  The required Python version could not be installed automatically.' -ForegroundColor Yellow
            Write-Host '  Please enter the path to an existing Python interpreter.' -ForegroundColor Yellow

            if ($NonInteractive) {
                throw (
                    "The required Python version could not be installed automatically.`n" +
                    "Error: $installErrMsg`n`n" +
                    "Please install Python $RequiresPythonRaw manually: https://www.python.org/downloads/`n" +
                    "Then re-run setup."
                )
            }

            $interResult = Select-PythonInteractively -Constraints $Constraints -RequiresPythonRaw $RequiresPythonRaw -AllowInstall:$AllowInstall
            $selected = [pscustomobject]@{
                Version   = $interResult.Version
                Directory = $interResult.Directory
                Exe       = $interResult.Exe
                DllName   = $interResult.DllName
                Source    = 'user-selected'
            }
            Write-Banner ("Using Python {0} at: {1}" -f $selected.Version, $selected.Exe) 'SUCCESS'
            return $selected
        }

        Write-Host 'Re-scanning for Python installations after install ...' -ForegroundColor Yellow
        $pythons = @(Find-PythonInstallations -Constraints $Constraints)
        $pythons = @($pythons | Where-Object { & $venvFilter $_ })

        # Installer-race fallback: re-discovery can return zero results during
        # the DLL-propagation window right after install. If the installer
        # verified a runnable exe, build a candidate from it directly.
        if ($pythons.Count -eq 0 -and $installedExe -and (Test-Path $installedExe -PathType Leaf)) {
            Write-Host ("  Re-scan found no candidates; using installer-verified exe: {0}" -f $installedExe) -ForegroundColor DarkYellow
            $verResult = Invoke-NativeCommand -Executable $installedExe -Arguments @('--version') -Quiet
            if ($verResult.Succeeded) {
                $verStr = $script:_versionRegex.Match("$($verResult.StdOut) $($verResult.StdErr)").Value
                if ($verStr) {
                    $pythons = @([pscustomobject]@{
                        Version   = [Version]$verStr
                        Directory = Split-Path $installedExe
                        Exe       = $installedExe
                    })
                }
            }
        }

        if ($pythons.Count -eq 0) {
            throw ("Python was installed but could not be located.`n" +
                   "Provide a direct interpreter path and re-run setup, for example:`n" +
                   ".\setup-core.ps1 -PythonExePath 'C:\Users\<you>\AppData\Local\Programs\Python\Python311\python.exe'")
        }
    }

    $best = Select-BestPython -Candidates $pythons
    if (-not $best -or -not (Test-Path $best.Exe -PathType Leaf)) {
        throw ("Selected Python executable does not exist: {0}" -f $best.Exe)
    }

    if ($pythons.Count -gt 1) {
        Write-Host ("  Found {0} compatible version(s):" -f $pythons.Count) -ForegroundColor Cyan
        $pythons | ForEach-Object { Write-Host ("    - {0}  ->  {1}" -f $_.Version, $_.Exe) }
        Write-Host ''
    }

    $selected = [pscustomobject]@{
        Version   = $best.Version
        Directory = $best.Directory
        Exe       = $best.Exe
        DllName   = $best.DllName
        Source    = $source
    }
    Write-Banner ("Using Python {0} at: {1}" -f $selected.Version, $selected.Exe) 'SUCCESS'
    return $selected
}