#Requires -Version 5.1
# =============================================================================
# Module  : Diagnostics.psm1
# Purpose : devsetup doctor / repair / about / support (Parts R-U).
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$import = 'Microsoft.PowerShell.Core\Import-Module'
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Errors.psm1')          -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Constants.psm1')       -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Redaction.psm1')       -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'SupportCodes.psm1')    -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'PyProjectHealth.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop
& $import -FullyQualifiedName (Join-Path $PSScriptRoot 'Compat.psm1')          -Force -DisableNameChecking -Global -ErrorAction Stop

<#
    `doctor` is READ-ONLY by construction: it only ever calls Get-*/Test-*
    functions and never takes a ShouldProcess action. `repair` is the only
    entry point here that writes, and it applies exactly the SafeAutoFix
    findings that `doctor` reported.
#>

function New-DoctorCheck {
    <#
    .SYNOPSIS
        One diagnostic line: Name, Status (OK/WARN/FAIL/SKIP), Detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][ValidateSet('OK', 'WARN', 'FAIL', 'SKIP')][string] $Status,
        [Parameter()][AllowEmptyString()][string] $Detail = '',
        [Parameter()][AllowEmptyString()][string] $Category = 'general'
    )
    [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Category = $Category }
}

function Invoke-SafeProbe {
    <#
    .SYNOPSIS
        Runs a probe and converts any failure into a FAIL check.

    .DESCRIPTION
        A diagnostic must never crash: a broken sub-check should show up as a
        red line, not abort the whole report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][scriptblock] $Probe,
        [Parameter()][string] $Category = 'general'
    )
    try { return (& $Probe) }
    catch {
        return (New-DoctorCheck -Name $Name -Status 'FAIL' -Category $Category `
            -Detail (Protect-SecretText -Text $_.Exception.Message))
    }
}

function Get-DevSetupDoctorReport {
<#
.SYNOPSIS
    Read-only diagnosis of DevSetup and the current project (Part S).

.DESCRIPTION
    Performs no writes of any kind. Every check is a Get-/Test- call, so
    running doctor twice produces the same result and changes nothing.

.PARAMETER ProjectRoot
    Project to inspect. Defaults to the current directory.

.OUTPUTS
    PSCustomObject with Checks, Findings, HasFailures, HasWarnings and Counts.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][string] $ProjectRoot = (Get-Location).Path,
        [Parameter()][AllowNull()][object] $DevSetupInfo
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $checks = New-Object System.Collections.Generic.List[object]
    $findings = @()

    # --- DevSetup itself ---------------------------------------------------
    if ($DevSetupInfo) {
        $checks.Add((New-DoctorCheck -Name 'DevSetup' -Status 'OK' -Category 'devsetup' `
            -Detail ("Version {0}" -f $(if ($DevSetupInfo.InstalledVersion) { $DevSetupInfo.InstalledVersion } else { 'aus dem Quellverzeichnis' }))))
        $checks.Add((New-DoctorCheck -Name 'Installationspfad' -Status 'OK' -Category 'devsetup' -Detail ([string]$DevSetupInfo.ModuleRoot)))
    } else {
        $checks.Add((New-DoctorCheck -Name 'DevSetup' -Status 'SKIP' -Category 'devsetup' -Detail 'Keine Installationsinformationen verfuegbar.'))
    }

    # --- Git ---------------------------------------------------------------
    $checks.Add((Invoke-SafeProbe -Name 'Git' -Category 'git' -Probe {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if (-not $git) { return (New-DoctorCheck -Name 'Git' -Status 'FAIL' -Category 'git' -Detail 'Git wurde nicht gefunden.') }
        $version = (& git --version 2>&1 | Select-Object -First 1)
        New-DoctorCheck -Name 'Git' -Status 'OK' -Category 'git' -Detail ([string]$version).Trim()
    }))

    $checks.Add((Invoke-SafeProbe -Name 'Repository' -Category 'git' -Probe {
        $top = & git -C $resolvedRoot rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $top) {
            return (New-DoctorCheck -Name 'Repository' -Status 'SKIP' -Category 'git' -Detail 'Das Projekt liegt nicht in einem Git-Repository.')
        }
        $status = & git -C $resolvedRoot status --porcelain 2>$null
        if ($status) {
            return (New-DoctorCheck -Name 'Repository' -Status 'WARN' -Category 'git' `
                -Detail ("{0} lokale Aenderung(en)." -f @($status).Count))
        }
        New-DoctorCheck -Name 'Repository' -Status 'OK' -Category 'git' -Detail 'Keine lokalen Aenderungen.'
    }))

    # --- Project configuration --------------------------------------------
    $healthReport = $null
    $checks.Add((Invoke-SafeProbe -Name 'Projektkonfiguration' -Category 'pyproject' -Probe {
        $script:doctorHealth = Get-PyProjectHealthReport -ProjectRoot $resolvedRoot -NoCache
        $r = $script:doctorHealth
        if ($r.Counts.FATAL -gt 0) {
            return (New-DoctorCheck -Name 'Projektkonfiguration' -Status 'FAIL' -Category 'pyproject' `
                -Detail (($r.Findings | Where-Object Severity -eq 'FATAL' | ForEach-Object Message) -join ' '))
        }
        if ($r.Counts.ERROR -gt 0) {
            return (New-DoctorCheck -Name 'Projektkonfiguration' -Status 'FAIL' -Category 'pyproject' `
                -Detail (($r.Findings | Where-Object Severity -eq 'ERROR' | ForEach-Object Message) -join ' '))
        }
        if ($r.Counts.WARN -gt 0) {
            return (New-DoctorCheck -Name 'Projektkonfiguration' -Status 'WARN' -Category 'pyproject' `
                -Detail (($r.Findings | Where-Object Severity -eq 'WARN' | ForEach-Object Message) -join ' '))
        }
        New-DoctorCheck -Name 'Projektkonfiguration' -Status 'OK' -Category 'pyproject' -Detail 'pyproject.toml ist in Ordnung.'
    }))
    if (Get-Variable -Name doctorHealth -Scope Script -ErrorAction SilentlyContinue) {
        $healthReport = $script:doctorHealth
        if ($healthReport) { $findings = $healthReport.Findings }
    }

    # --- Package manager ---------------------------------------------------
    $checks.Add((Invoke-SafeProbe -Name 'Paketmanager' -Category 'packagemanager' -Probe {
        if (-not $healthReport) { return (New-DoctorCheck -Name 'Paketmanager' -Status 'SKIP' -Category 'packagemanager' -Detail 'Nicht ermittelbar.') }
        if (-not $healthReport.PackageManager) {
            return (New-DoctorCheck -Name 'Paketmanager' -Status 'FAIL' -Category 'packagemanager' `
                -Detail 'Nicht eindeutig - uv oder Poetry muss festgelegt werden.')
        }
        New-DoctorCheck -Name 'Paketmanager' -Status 'OK' -Category 'packagemanager' -Detail $healthReport.PackageManager
    }))

    $checks.Add((Invoke-SafeProbe -Name 'Paketmanager-Programm' -Category 'packagemanager' -Probe {
        if (-not $healthReport -or -not $healthReport.PackageManager) {
            return (New-DoctorCheck -Name 'Paketmanager-Programm' -Status 'SKIP' -Category 'packagemanager' -Detail 'Kein Paketmanager festgelegt.')
        }
        $exe = Get-Command $healthReport.PackageManager -ErrorAction SilentlyContinue
        if (-not $exe) {
            return (New-DoctorCheck -Name 'Paketmanager-Programm' -Status 'WARN' -Category 'packagemanager' `
                -Detail ("{0} ist nicht installiert; DevSetup richtet es bei Bedarf ein." -f $healthReport.PackageManager))
        }
        New-DoctorCheck -Name 'Paketmanager-Programm' -Status 'OK' -Category 'packagemanager' -Detail $exe.Source
    }))

    # --- Python ------------------------------------------------------------
    $checks.Add((Invoke-SafeProbe -Name 'Python-Anforderung' -Category 'python' -Probe {
        if (-not $healthReport -or -not $healthReport.Metadata.RequiresPython) {
            return (New-DoctorCheck -Name 'Python-Anforderung' -Status 'WARN' -Category 'python' -Detail 'Keine Python-Anforderung deklariert.')
        }
        New-DoctorCheck -Name 'Python-Anforderung' -Status 'OK' -Category 'python' -Detail $healthReport.Metadata.RequiresPython
    }))

    # --- Virtual environment ----------------------------------------------
    $checks.Add((Invoke-SafeProbe -Name 'Umgebung (.venv)' -Category 'venv' -Probe {
        $venv = Join-Path $resolvedRoot '.venv'
        if (-not (Test-Path -LiteralPath $venv -PathType Container)) {
            return (New-DoctorCheck -Name 'Umgebung (.venv)' -Status 'WARN' -Category 'venv' -Detail 'Noch nicht vorhanden.')
        }
        $py = Get-VenvPythonExe -VenvDir $venv
        if (-not (Test-Path -LiteralPath $py -PathType Leaf)) {
            return (New-DoctorCheck -Name 'Umgebung (.venv)' -Status 'FAIL' -Category 'venv' -Detail 'Vorhanden, aber unvollstaendig.')
        }
        New-DoctorCheck -Name 'Umgebung (.venv)' -Status 'OK' -Category 'venv' -Detail $venv
    }))

    # --- Lock file ---------------------------------------------------------
    $checks.Add((Invoke-SafeProbe -Name 'Abhaengigkeiten' -Category 'lock' -Probe {
        if (-not $healthReport) { return (New-DoctorCheck -Name 'Abhaengigkeiten' -Status 'SKIP' -Category 'lock' -Detail 'Nicht pruefbar.') }
        $lockFindings = @($healthReport.Findings | Where-Object Category -eq 'lock')
        if ($lockFindings.Count -eq 0) {
            return (New-DoctorCheck -Name 'Abhaengigkeiten' -Status 'OK' -Category 'lock' -Detail 'Lock-Datei passt zum Projekt.')
        }
        $worst = if (@($lockFindings | Where-Object Severity -in @('ERROR', 'FATAL')).Count -gt 0) { 'FAIL' } else { 'WARN' }
        New-DoctorCheck -Name 'Abhaengigkeiten' -Status $worst -Category 'lock' -Detail (($lockFindings | ForEach-Object Message) -join ' ')
    }))

    # --- Signing (Windows only) -------------------------------------------
    $checks.Add((Invoke-SafeProbe -Name 'Signaturen' -Category 'signing' -Probe {
        if (-not (Get-IsWindows)) {
            return (New-DoctorCheck -Name 'Signaturen' -Status 'SKIP' -Category 'signing' -Detail 'Nur unter Windows verfuegbar.')
        }
        $constants = Get-SetupConstants
        $exe = if ($env:DIGICERT_UTILITY_EXE) { $env:DIGICERT_UTILITY_EXE } else { [string]$constants.CodeSigning.DefaultDigiCertUtilityExe }
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            return (New-DoctorCheck -Name 'Signaturen' -Status 'WARN' -Category 'signing' -Detail 'Signaturwerkzeug nicht gefunden.')
        }
        New-DoctorCheck -Name 'Signaturen' -Status 'OK' -Category 'signing' -Detail $exe
    }))

    # --- VS Code -----------------------------------------------------------
    $checks.Add((Invoke-SafeProbe -Name 'VS Code' -Category 'vscode' -Probe {
        $settings = Join-Path $resolvedRoot '.vscode/settings.json'
        if (-not (Test-Path -LiteralPath $settings -PathType Leaf)) {
            return (New-DoctorCheck -Name 'VS Code' -Status 'SKIP' -Category 'vscode' -Detail 'Keine Projekteinstellungen vorhanden.')
        }
        New-DoctorCheck -Name 'VS Code' -Status 'OK' -Category 'vscode' -Detail $settings
    }))

    $all = $checks.ToArray()
    [pscustomobject]@{
        ProjectRoot  = $resolvedRoot
        GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Checks       = $all
        Findings     = $findings
        HasFailures  = [bool](@($all | Where-Object Status -eq 'FAIL').Count)
        HasWarnings  = [bool](@($all | Where-Object Status -eq 'WARN').Count)
        Counts       = [pscustomobject]@{
            OK   = @($all | Where-Object Status -eq 'OK').Count
            WARN = @($all | Where-Object Status -eq 'WARN').Count
            FAIL = @($all | Where-Object Status -eq 'FAIL').Count
            SKIP = @($all | Where-Object Status -eq 'SKIP').Count
        }
    }
}

function Format-DevSetupDoctorReport {
<#
.SYNOPSIS
    Renders a doctor report as the short output an end user sees (Part AG).
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject] $Report,
        [Parameter()][switch] $Detailed
    )

    $glyphs = @{ OK = [char]0x2713; WARN = '!'; FAIL = [char]0x2717; SKIP = '-' }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('')
    $lines.Add('DevSetup Diagnose')
    $lines.Add('')

    foreach ($check in $Report.Checks) {
        if (-not $Detailed -and $check.Status -eq 'SKIP') { continue }
        $glyph = $glyphs[$check.Status]
        if ($Detailed -or $check.Status -ne 'OK') {
            $lines.Add(('{0} {1} - {2}' -f $glyph, $check.Name, $check.Detail))
        } else {
            $lines.Add(('{0} {1}' -f $glyph, $check.Name))
        }
    }

    $lines.Add('')
    if ($Report.HasFailures) {
        $lines.Add('Es wurden Probleme gefunden, die eine Entscheidung benoetigen.')
        $autoFixable = @($Report.Findings | Where-Object AutoFixable)
        if ($autoFixable.Count -gt 0) {
            $lines.Add(('{0} davon kann DevSetup selbst beheben: devsetup repair' -f $autoFixable.Count))
        }
    } elseif ($Report.HasWarnings) {
        $lines.Add('Hinweise gefunden, das Projekt ist aber arbeitsbereit.')
    } else {
        $lines.Add('Keine Probleme gefunden.')
    }
    $lines.Add('')
    return ($lines -join [Environment]::NewLine)
}

function Invoke-DevSetupRepair {
<#
.SYNOPSIS
    Applies only the SafeAutoFix findings a doctor run reported (Part T).

.DESCRIPTION
    NeedsDecision findings are never fixed automatically. In an unattended run
    they cause a non-zero result so CI fails loudly; interactively they are
    listed for the operator.

.PARAMETER NonInteractive
    Treat outstanding NeedsDecision findings as a failure.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][string] $ProjectRoot = (Get-Location).Path,
        [Parameter()][switch] $NonInteractive
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
    Clear-PyProjectHealthCache
    $before = Get-PyProjectHealthReport -ProjectRoot $resolvedRoot -NoCache

    # $WhatIfPreference does NOT propagate across module boundaries: without
    # forwarding it explicitly, `devsetup repair -WhatIf` would really edit
    # pyproject.toml. Same for a user-supplied -Confirm.
    $healParams = @{ ProjectRoot = $resolvedRoot; WhatIf = [bool]$WhatIfPreference }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $healParams.Confirm = [bool]$PSBoundParameters['Confirm'] }
    $healResult = Invoke-PyProjectHealing @healParams

    Clear-PyProjectHealthCache
    $after = Get-PyProjectHealthReport -ProjectRoot $resolvedRoot -NoCache
    $needsDecision = @($after.Findings | Where-Object FixClass -eq 'NeedsDecision')

    [pscustomobject]@{
        ProjectRoot   = $resolvedRoot
        Applied       = $healResult.Applied
        Changed       = $healResult.Changed
        BackupPath    = $healResult.BackupPath
        Diff          = $healResult.Diff
        NeedsDecision = $needsDecision
        Succeeded     = (-not ($NonInteractive -and $needsDecision.Count -gt 0))
        BeforeCount   = $before.Findings.Count
        AfterCount    = $after.Findings.Count
    }
}

function New-DevSetupSupportBundle {
<#
.SYNOPSIS
    Builds a redacted support bundle (Part U).

.DESCRIPTION
    Everything written into the bundle passes through Protect-SecretObject or
    Protect-SecretText first, so tokens, passwords and credential URLs never
    leave the machine.

.OUTPUTS
    PSCustomObject with ZipPath and the list of files included.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][string] $ProjectRoot = (Get-Location).Path,
        [Parameter()][string] $OutputDirectory = (Get-Location).Path,
        [Parameter()][AllowNull()][object] $DevSetupInfo,
        [Parameter()][AllowNull()][string] $LogPath
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

    # GetFullPath, not Resolve-Path: under -WhatIf the output directory is
    # deliberately not created, and Resolve-Path would then fail on it.
    $fullOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $zipPath = Join-Path $fullOutput ("DevSetup-Support-{0}.zip" -f $stamp)

    if (-not $PSCmdlet.ShouldProcess($zipPath, 'Create support bundle')) {
        return [pscustomobject]@{ ZipPath = $zipPath; Files = @(); Created = $false }
    }

    if (-not (Test-Path -LiteralPath $fullOutput -PathType Container)) {
        New-Item -ItemType Directory -Path $fullOutput -Force -Confirm:$false | Out-Null
    }

    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("devsetup-support-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $written = New-Object System.Collections.Generic.List[string]

    function Write-BundleJson {
        param([string] $Name, [object] $Data)
        $safe = Protect-SecretObject -InputObject $Data
        $path = Join-Path $staging $Name
        Set-Content -LiteralPath $path -Value ($safe | ConvertTo-Json -Depth 12) -Encoding UTF8
        $written.Add($Name)
    }

    try {
        # system.json - environment, with the whole env block redacted by key.
        Write-BundleJson -Name 'system.json' -Data ([ordered]@{
            GeneratedUtc   = (Get-Date).ToUniversalTime().ToString('o')
            OS             = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim()
            Architecture   = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
            PowerShell     = $PSVersionTable.PSVersion.ToString()
            PSEdition      = $PSVersionTable.PSEdition
            IsWindows      = (Get-IsWindows)
            CurrentDir     = $resolvedRoot
            Environment    = (Get-ChildItem env: | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } })
        })

        Write-BundleJson -Name 'devsetup-version.json' -Data ([ordered]@{
            Info = if ($DevSetupInfo) { $DevSetupInfo } else { 'not available' }
        })

        $doctor = Get-DevSetupDoctorReport -ProjectRoot $resolvedRoot -DevSetupInfo $DevSetupInfo
        Write-BundleJson -Name 'health-report.json' -Data $doctor

        Clear-PyProjectHealthCache
        Write-BundleJson -Name 'pyproject-health.json' -Data (Get-PyProjectHealthReport -ProjectRoot $resolvedRoot -NoCache)

        Write-BundleJson -Name 'python-report.json' -Data ([ordered]@{
            PythonOnPath = @(@('python3', 'python', 'py') | ForEach-Object {
                $c = Get-Command $_ -ErrorAction SilentlyContinue
                if ($c) { @{ Name = $_; Source = $c.Source } }
            } | Where-Object { $_ })
            VenvPresent  = (Test-Path -LiteralPath (Join-Path $resolvedRoot '.venv') -PathType Container)
        })

        # git-status.txt - remote URLs can embed credentials, so redact.
        $gitText = & {
            $top = & git -C $resolvedRoot rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $top) { return 'not a git repository' }
            $out = @()
            $out += '# git status --porcelain=v1 -b'
            $out += (& git -C $resolvedRoot status --porcelain=v1 -b 2>&1)
            $out += ''
            $out += '# git remote -v'
            $out += (& git -C $resolvedRoot remote -v 2>&1)
            return ($out -join [Environment]::NewLine)
        }
        Set-Content -LiteralPath (Join-Path $staging 'git-status.txt') -Value (Protect-SecretText -Text ([string]$gitText)) -Encoding UTF8
        $written.Add('git-status.txt')

        if ($LogPath -and (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
            if (Protect-SecretFile -SourcePath $LogPath -DestinationPath (Join-Path $staging 'setup-log.ndjson') -Confirm:$false) {
                $written.Add('setup-log.ndjson')
            }
        }

        $configPath = Join-Path $resolvedRoot '.setup-config.json'
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            if (Protect-SecretFile -SourcePath $configPath -DestinationPath (Join-Path $staging 'setup-config.json') -Confirm:$false) {
                $written.Add('setup-config.json')
            }
        }

        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -Force

        return [pscustomobject]@{ ZipPath = $zipPath; Files = $written.ToArray(); Created = $true }
    }
    finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function `
    Get-DevSetupDoctorReport, `
    Format-DevSetupDoctorReport, `
    Invoke-DevSetupRepair, `
    New-DevSetupSupportBundle, `
    New-DoctorCheck
