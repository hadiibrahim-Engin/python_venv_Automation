#Requires -Version 5.1

<#
.SYNOPSIS
    Root orchestration module for project setup.

.DESCRIPTION
    Loads all SetupCore helper modules and exposes Start-Setup, which performs
    Python discovery/installation, Poetry runtime preparation, virtual
    environment provisioning, project path wiring, and optional code signing.
#>

$ErrorActionPreference = 'Stop'

# Prevent direct module import from the VS Code-integrated PowerShell host.
# Importing this module there causes the extension to open every child .psm1 file.
if (($env:TERM_PROGRAM -eq 'vscode' -or $env:VSCODE_PID) -and -not $env:SETUP_SUBPROCESS) {
    $msg = @(
        'Direct Import-Module of Setup-Core.psm1 from the VS Code terminal is blocked.',
        'Run .\\setup-core.ps1 instead; it detaches to a plain PowerShell subprocess first.',
        'This prevents SetupCore .psm1 modules from opening in the editor.'
    ) -join ' '
    Write-Host $msg -ForegroundColor Yellow
    throw $msg
}

# Resolve to your actual modules folder
$modulesDir = Join-Path (Join-Path $PSScriptRoot 'SetupCore') 'modules'
if (-not (Test-Path (Join-Path $modulesDir 'Compat.psm1'))) {
    Write-Host "Modules directory missing Compat.psm1: $modulesDir" -ForegroundColor Red
    throw "Cannot continue without modules directory."
}
Write-Host ("Using modules directory: {0}" -f $modulesDir) -ForegroundColor DarkGray

# Always call the real Import-Module cmdlet, import by full path.
# Order matters: leaves first (UI, Versioning, NativeCommand), then modules
# that depend on them. Per-child `Import-Module` calls in each module stay
# in place so tests can import modules individually.
$import = 'Microsoft.PowerShell.Core\Import-Module'
$moduleLoadOrder = @(
    'Compat',           # platform shims - must be first
    'UI',               # logging helpers - no dependencies
    'Versioning',       # version constraint parsing
    'Toml',             # pyproject.toml parsing
    'NativeCommand',    # process execution primitives
    'Config',           # .setup-config.json read/write
    'Detection',        # PM detection (CLI → config → TOML → default)
    'Filesystem',       # directory/process cleanup helpers
    'PythonDiscovery',  # Python interpreter discovery and installation
    'Venv',             # venv lifecycle
    'VSCode',           # .vscode/settings.json writer
    'Tcl',              # tcl runtime copy helper
    'Poetry',           # Poetry CLI wrapper
    'UV',               # uv CLI wrapper
    'PackageManager',   # execution facade (install/sync/venv) - after Poetry + UV
    'Prechecks',        # pre-flight checks
    'CodeSigning'       # DigiCert signing
)
foreach ($m in $moduleLoadOrder) {
    & $import -FullyQualifiedName (Join-Path $modulesDir "$m.psm1") -Force -DisableNameChecking -ErrorAction Stop
}


# ---------------------------------------------------------------------------
# Internal helper - executes a labeled pipeline step, handles timing + errors.
# Uses $script:setupCurrentStep / $script:setupCurrentModule (set by Start-Setup)
# and $script:setupDryRun to support dry-run mode.
# ---------------------------------------------------------------------------
function Invoke-SetupStep {
    param(
        [Parameter(Mandatory=$true)][string]      $Step,
        [Parameter(Mandatory=$true)][string]      $Module,
        [Parameter(Mandatory=$true)][string]      $Message,
        [Parameter(Mandatory=$true)][scriptblock] $Action,
        [bool] $Mandatory = $true,
        # Read-only steps (e.g. detection/reporting) run even in dry-run mode
        # because they do not mutate the file system.
        [bool] $ReadOnly  = $false
    )

    $script:setupCurrentStep   = $Step
    $script:setupCurrentModule = $Module

    Write-LogStepStart -Step $Step -Module $Module -Message $Message

    if ($script:setupDryRun -and -not $ReadOnly) {
        Write-Host ("|   [DRY-RUN] Step {0} skipped - no changes made." -f $Step) -ForegroundColor DarkYellow
        Write-Host ('+' + ('-' * 94) + '+') -ForegroundColor DarkCyan
        return
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        $sw.Stop()
        Write-LogStepResult -Step $Step -Module $Module -Status 'OK' -Message $Message -DurationSec $sw.Elapsed.TotalSeconds
    } catch {
        $sw.Stop()
        $d = Get-SetupErrorDetails -ErrorRecord $_
        $status = if ($Mandatory) { 'ERROR' } else { 'WARN' }
        Write-LogStepResult -Step $Step -Module $Module -Status $status -Message $d.Message -DurationSec $sw.Elapsed.TotalSeconds
        Write-LogDetail -Key 'location'  -Value $d.Location
        Write-LogDetail -Key 'error_id'  -Value $d.ErrorId
        Write-LogDetail -Key 'command'   -Value $d.Command
        if ($d.Stack) {
            Write-Host '    - stack:' -ForegroundColor DarkGray
            $d.Stack -split "`n" | ForEach-Object { Write-Host ("      {0}" -f $_.Trim()) -ForegroundColor DarkGray }
        }
        if ($Mandatory) { throw }
    }
}


function Start-Setup {
<#
.SYNOPSIS
    Entry point for the modularized Setup Core flow.

.DESCRIPTION
    Executes the setup pipeline in a fixed order:
    parse pyproject metadata, resolve a compatible Python, ensure Poetry,
    recreate and validate .venv, install dependencies, write editor settings,
    and optionally sign binaries.

.PARAMETER ProjectRoot
    Project root directory containing pyproject.toml.

.PARAMETER ForceRecreateVenv
    Removes and recreates .venv when true.

.PARAMETER SkipPoetryInstall
    Skips `poetry install` when true.

.PARAMETER PythonExePath
    Optional explicit path to python.exe. When provided, setup validates this
    interpreter against pyproject constraints and uses it directly.

.PARAMETER NonInteractive
    Disables pause prompts and uses exception flow for failures.

.PARAMETER EnableCodeSigning
    Enables optional DigiCert signing of executables in the venv.

.PARAMETER DigiCertUtilityExe
    Full path to DigiCertUtil.exe.

.PARAMETER KernelDriverSigning
    Uses kernel driver signing mode for DigiCert when enabled.

.PARAMETER SignPoetryOnly
    Signs only poetry.exe under the venv Scripts directory when enabled.

.PARAMETER UpdateDependencies
    When true, runs 'poetry update' instead of 'poetry install'.
    'poetry update' re-resolves all dependencies to the latest versions allowed
    by pyproject.toml constraints and rewrites poetry.lock. This is the
    Poetry-documented way to intentionally upgrade - equivalent to deleting
    poetry.lock and reinstalling, but without manual file manipulation.
    Default is false, which uses 'poetry install' with the existing lock file
    for reproducible installs.

.PARAMETER ListMode
    When true, shows every Python interpreter found on this machine in a
    numbered table and lets the user pick one before setup continues.
    Compatible versions are marked [OK]; incompatible ones are marked [--].
    The constraint from pyproject.toml is still enforced - incompatible picks
    are rejected and the user is prompted again.

.PARAMETER PackageManager
    Which package manager to use for dependency installation.
    'auto'   (default) - inferred from the project: checks pyproject.toml sections
                         first, then lock files as a tiebreaker for dual-mode projects.
                         Falls back to 'poetry' when no signal is found.
    'poetry'           - uses [tool.poetry] section and poetry.lock.
    'uv'               - uses [project] (PEP 621) section and uv.lock.
    Pass -PackageManager uv or -PackageManager poetry to override detection.

.PARAMETER IncludeDev
    When true (default), installs development dependencies.
    When false, installs production dependencies only.
    UV: omits --all-extras; Poetry: adds --without dev.

.PARAMETER DryRun
    When set, prints each setup step but executes no actions.
    Useful to preview the pipeline without modifying the file system.

.PARAMETER PinnedPoetryVersion
    When set, installs exactly this Poetry version (e.g. '1.8.3') instead of
    the latest release.  Has no effect when PackageManager is 'uv'.

.PARAMETER PinnedUvVersion
    When set, installs exactly this uv version (e.g. '0.6.14') instead of the
    latest release.  Has no effect when PackageManager is 'poetry'.

.OUTPUTS
    PSCustomObject summarizing selected Python, Poetry runtime, and output paths.
#>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $ProjectRoot = (Get-Location).Path,

        [Parameter()]
        [bool] $ForceRecreateVenv = $true,

        [Parameter()]
        [bool] $SkipPoetryInstall = $false,

        [Parameter()]
        [string] $PythonExePath,

        [Parameter()]
        [bool] $NonInteractive = $false,

        [Parameter()]
        [bool] $EnableCodeSigning = $true,

        [Parameter()]
        [string] $DigiCertUtilityExe = $(if ($env:DIGICERT_UTILITY_EXE) { $env:DIGICERT_UTILITY_EXE } else { 'C:\Program Files\DigiCertUtility\DigiCertUtil.exe' }),

        [Parameter()]
        [bool] $KernelDriverSigning = $false,

        [Parameter()]
        [bool] $SignPoetryOnly = $false,

        [Parameter()]
        [bool] $RequirePmShimSigning = $true,

        [Parameter()]
        [bool] $UpdateDependencies = $false,

        [Parameter()]
        [bool] $ListMode = $false,

        [Parameter()]
        [ValidateSet('uv','poetry','auto')]
        [string] $PackageManager = 'auto',

        [Parameter()]
        [bool] $IncludeDev = $true,

        [Parameter()]
        [switch] $DryRun,

        [Parameter()]
        [string] $PinnedPoetryVersion = '',

        [Parameter()]
        [string] $PinnedUvVersion = '',

        [Parameter()]
        # When $true (default), setup stops if any precheck fails (even auto-fixed non-critical ones).
        # Pass $false (-ContinueOnPrecheckFailure) to allow setup to proceed despite failures.
        [bool] $StopOnPrecheckFailure = $true
    )

    try {
        Set-StrictMode -Version Latest

        # Initialise script-scope state used by Invoke-SetupStep (defined at module scope).
        # setupCurrentStep / setupCurrentModule track which step is executing so the
        # outer catch can report the failing stage.
        $script:setupCurrentStep   = 'INIT'
        $script:setupCurrentModule = 'Core'
        $script:setupDryRun        = [bool]$DryRun

        # Detach any active virtual environment
        $env:VIRTUAL_ENV   = $null
        $env:POETRY_ACTIVE = $null
        $env:CONDA_PREFIX  = $null

        # Context (hashtable avoids the strict-mode pscustomobject
        # property-add-after-construction smell)
        if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
            throw "Project root does not exist: $ProjectRoot"
        }
        $resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

        # Build the context.  PackageManager holds the raw CLI arg here (may be 'auto').
        # The DETECT step below is responsible for resolving the final PM value.
        $ctx = @{
            ProjectRoot          = $resolvedRoot
            ProjectName          = $null
            RequiresPython       = $null
            ParsedConstraints    = $null
            SelectedPython       = $null
            # PM runtime info — set by Invoke-PmEnsureRuntime (Step 3)
            UvInfo               = $null
            PoetryInfo           = $null
            PoetryPythonPath     = $null   # poetry-specific shortcut
            PmPythonPath         = $null   # generic alias; works for both uv and poetry
            VenvDir              = Join-Path $resolvedRoot '.venv'
            SitePackagesDir      = $null
            SignResult           = $null
            VscodeSettingsFile   = Join-Path (Join-Path $resolvedRoot '.vscode') 'settings.json'
            NonInteractive       = $NonInteractive
            ForceRecreateVenv    = $ForceRecreateVenv
            SkipPoetryInstall    = $SkipPoetryInstall
            PythonExePath        = $PythonExePath
            UpdateDependencies   = $UpdateDependencies
            ListMode             = $ListMode
            PackageManager       = $PackageManager      # raw CLI arg ('auto'|'uv'|'poetry'); DETECT resolves
            PmSource             = $null                # 'cli' | 'config-file' | 'detected' | 'default'
            PmDetectionReport    = $null                # raw signals; populated when PmSource='detected'
            EnableCodeSigning    = $EnableCodeSigning   # mutable — Prechecks may disable it
            NetworkAvailable     = $true                # mutable — Prechecks may set to $false
            IncludeDev           = $IncludeDev
            PinnedPoetryVersion  = $PinnedPoetryVersion
            PinnedUvVersion      = $PinnedUvVersion
            VenvBackupPath       = $null                # set by New-VenvBackup before step 5b
        }

        Write-LogStepStart -Step 'SETUP' -Module 'Core' -Message 'Initialize setup context'
        Write-LogDetail -Key 'project'      -Value (Split-Path $ctx.ProjectRoot -Leaf)
        Write-LogDetail -Key 'project_root' -Value $ctx.ProjectRoot
        Write-LogDetail -Key 'include_dev'  -Value $ctx.IncludeDev
        Write-LogDetail -Key 'code_signing' -Value $ctx.EnableCodeSigning
        if ($script:setupDryRun) {
            Write-LogDetail -Key 'dry_run' -Value 'true  - NO CHANGES will be made to the file system'
        }
        Write-LogStepResult -Step 'SETUP' -Module 'Core' -Status 'OK' -Message 'Context initialized'

        # DETECT step
        # All detection logic lives in Detection.psm1 (Invoke-PmDetection).
        # Runs even in dry-run mode (ReadOnly) — only reads files, no mutations.
        Invoke-SetupStep -Step 'DETECT' -Module 'Detection' -Message 'Detect package manager from project files' -Mandatory $true -ReadOnly $true -Action {
            Invoke-PmDetection -Ctx $ctx
        } | Out-Null

        # Step 0: Pre-setup checks
        # Runs before anything is modified on disk.  Non-critical failures
        # (e.g. DigiCert missing) auto-disable the affected feature via AutoFix.
        # Critical failures ask the user (semi-auto) or throw (autonomous).
        Invoke-SetupStep -Step '0/13' -Module 'Prechecks' -Message 'Run pre-setup checks' -Mandatory $true -Action {
            $prechecks = Invoke-Prechecks `
                -EnableCodeSigning $ctx.EnableCodeSigning `
                -DigiCertExe       $DigiCertUtilityExe `
                -NonInteractive    ([bool]$ctx.NonInteractive) `
                -Ctx               $ctx `
                -StopOnNonCritical $StopOnPrecheckFailure
            if (-not $prechecks.ContinueSetup) {
                throw 'Setup aborted: prechecks failed and user chose not to continue.'
            }
            Write-LogDetail -Key 'prechecks_passed' -Value $prechecks.AllPassed
            Write-LogDetail -Key 'code_signing_effective' -Value $ctx.EnableCodeSigning
        } | Out-Null

        # Python interpreter mode prompt (runs after prechecks, before discovery)
        # Only shown when no explicit path/mode was provided via CLI.
        if (-not $ctx.NonInteractive -and -not $ctx.PythonExePath -and -not $ctx.ListMode) {
            Write-Host ''
            Write-Host '+------------------------------------------------------------+' -ForegroundColor Cyan
            Write-Host '|  How should Setup select a Python interpreter?             |' -ForegroundColor Cyan
            Write-Host '+------------------------------------------------------------+' -ForegroundColor Cyan
            Write-Host '|  [Enter]   Semi-auto  =>> script finds best compatible     |' -ForegroundColor DarkGray
            Write-Host '|             Python automatically (recommended)             |' -ForegroundColor DarkGray
            Write-Host '|  [l]       List       =>> show ALL Pythons, you pick one   |' -ForegroundColor DarkGray
            Write-Host '|  <path>    Explicit   =>> full path to python.exe          |' -ForegroundColor DarkGray
            Write-Host '+------------------------------------------------------------+' -ForegroundColor Cyan
            Write-Host ''
            $userPythonInput = Read-Host 'Choice (Enter = semi-auto)'
            $userPythonInput = if ($userPythonInput) { $userPythonInput.Trim() } else { '' }

            if ($userPythonInput -ieq 'l' -or $userPythonInput -ieq 'list') {
                $ctx.ListMode = $true
                Write-Host 'List mode selected. All Python installations will be shown.' -ForegroundColor DarkGray
            } elseif (-not [string]::IsNullOrWhiteSpace($userPythonInput)) {
                $candidate = $userPythonInput.Trim('"').Trim("'")
                try { $candidate = [System.IO.Path]::GetFullPath($candidate) } catch { }
                $ctx.PythonExePath = $candidate
                Write-Host ("Explicit path accepted: {0}" -f $ctx.PythonExePath) -ForegroundColor DarkGray
            } else {
                Write-Host 'Semi-autonomous mode. Setup will find the best compatible Python.' -ForegroundColor DarkGray
            }
        }

        # Step 1: Parse pyproject.toml
        Invoke-SetupStep -Step '1/13' -Module 'PyProject' -Message 'Parse project metadata' -Mandatory $true -Action {
            $meta = Get-ProjectMetadata -ProjectRoot $ctx.ProjectRoot
            $ctx.ProjectName    = $meta.ProjectName
            $ctx.RequiresPython = $meta.RequiresPython
            Write-LogDetail -Key 'project_name'     -Value $ctx.ProjectName
            Write-LogDetail -Key 'python_constraint' -Value $ctx.RequiresPython
            $ctx.ParsedConstraints = ConvertTo-VersionConstraints -ConstraintStr $ctx.RequiresPython
        } | Out-Null

        # Step 2: Resolve Python interpreter
        Invoke-SetupStep -Step '2/13' -Module 'Python' -Message 'Resolve Python interpreter' -Mandatory $true -Action {
            $ctx.SelectedPython = Resolve-SelectedPython `
                -Constraints           $ctx.ParsedConstraints `
                -RequiresPythonRaw     $ctx.RequiresPython `
                -VenvDir               $ctx.VenvDir `
                -ExplicitPythonExePath $ctx.PythonExePath `
                -AllowInstall `
                -NonInteractive:([bool]$ctx.NonInteractive) `
                -ListMode:([bool]$ctx.ListMode)
            Write-LogDetail -Key 'python_version' -Value $ctx.SelectedPython.Version
            Write-LogDetail -Key 'python_exe'     -Value $ctx.SelectedPython.Exe
            Write-LogDetail -Key 'python_source'  -Value $ctx.SelectedPython.Source
        } | Out-Null

        # Configure code-signing defaults after Python is known and after
        # prechecks may have disabled signing.
        # Skipped in DryRun (no side effects needed) and on non-Windows (DigiCert is Windows-only).
        $isWindowsHost = Get-IsWindows
        if ($ctx.EnableCodeSigning -and $isWindowsHost -and -not $script:setupDryRun) {
            Set-CodeSignerDefaults -DigiCertUtilityExe $DigiCertUtilityExe -KernelDriverSigning $KernelDriverSigning
        } elseif ($ctx.EnableCodeSigning -and -not $isWindowsHost) {
            $ctx.EnableCodeSigning = $false
            Write-LogDetail -Key 'code_signing' -Value 'disabled (DigiCert is Windows-only)'
        }

        # Steps 3-9: Package-manager pipeline (PackageManager.psm1 facade)
        # The orchestrator contains zero PM-specific knowledge from here on.
        # To add a third package manager: create its .psm1, import it inside
        # PackageManager.psm1, and add switch branches there.
        # This block never needs to change.

        # 3. Ensure PM runtime (installs if missing)
        Invoke-SetupStep -Step '3/13' -Module 'PM' -Message ("Ensure {0} runtime" -f $ctx.PackageManager) -Mandatory $true -Action {
            Invoke-PmEnsureRuntime -Ctx $ctx
        } | Out-Null

        # 3a. Sign PM executable/shim when code signing is active.
        #     UV:     signs uv.exe itself (native binary, no separate shim).
        #     Poetry: signs the poetry.exe shim installed by pipx/installer.
        $pmShimPath = Get-PmShimPath -Ctx $ctx
        if ($ctx.EnableCodeSigning -and $pmShimPath) {
            Invoke-SetupStep -Step '3a/13' -Module 'CodeSigning' -Message ("Sign {0} CLI executable" -f $ctx.PackageManager) -Mandatory ([bool]$RequirePmShimSigning) -Action {
                Write-LogDetail -Key 'exe_path' -Value $pmShimPath
                $shimSign = Sign-PoetryShim -ShimPath $pmShimPath
                if ((@($shimSign.Failed).Count -gt 0) -or ($shimSign.Signed -lt 1)) {
                    throw ("{0} executable signing failed or signed 0 files." -f $ctx.PackageManager)
                }
            } | Out-Null
        }

        # 4. Configure PM (Poetry: virtualenvs.in-project = true; UV: no-op)
        Invoke-SetupStep -Step '4/13' -Module 'PM' -Message ("Configure {0} defaults" -f $ctx.PackageManager) -Mandatory $true -Action {
            Invoke-PmConfigure -Ctx $ctx
        } | Out-Null

        # 5a. Clean stale env associations (Poetry: Remove-PoetryEnvs; UV: no-op)
        Invoke-SetupStep -Step '5a/13' -Module 'PM' -Message 'Clean stale environment associations' -Mandatory $false -Action {
            Invoke-PmCleanEnvs -Ctx $ctx
        } | Out-Null

        # 5b. Backup + remove old .venv when ForceRecreate is set.
        #     Create a timestamped backup first so step 9 failures can roll back.
        if ($ctx.ForceRecreateVenv) {
            Invoke-SetupStep -Step '5b/13' -Module 'Venv' -Message 'Recreate .venv (backup + remove old environment)' -Mandatory $true -Action {
                $ctx.VenvBackupPath = New-VenvBackup -VenvDir $ctx.VenvDir
                if ($ctx.VenvBackupPath) {
                    Write-LogDetail -Key 'venv_backup' -Value $ctx.VenvBackupPath
                }
                Remove-VenvIfExists -VenvDir $ctx.VenvDir -NonInteractive ([bool]$ctx.NonInteractive)
            } | Out-Null
        }

        # 5c. Create .venv and pin it to the selected Python interpreter
        Invoke-SetupStep -Step '5c/13' -Module 'PM' -Message ("Prepare .venv with {0} (Python {1})" -f $ctx.PackageManager, $ctx.SelectedPython.Version) -Mandatory $true -Action {
            Write-LogDetail -Key 'python_exe' -Value $ctx.SelectedPython.Exe
            Write-LogDetail -Key 'venv_dir'   -Value $ctx.VenvDir
            Invoke-PmPrepareVenv -Ctx $ctx
        } | Out-Null

        # 6. Validate .venv
        Invoke-SetupStep -Step '6/13' -Module 'Venv' -Message 'Validate .venv structure' -Mandatory $true -Action {
            Confirm-VenvExists -VenvDir $ctx.VenvDir
            Write-LogDetail -Key 'venv_dir' -Value $ctx.VenvDir
        } | Out-Null

        # 7. Copy Python DLL into .venv
        Invoke-SetupStep -Step '7/13' -Module 'Venv' -Message 'Copy python runtime DLL into .venv' -Mandatory $true -Action {
            Write-LogDetail -Key 'dll_name' -Value $ctx.SelectedPython.DllName
            Copy-PythonDllToVenv -DllSourceDir $ctx.SelectedPython.Directory -VenvDir $ctx.VenvDir -DllName $ctx.SelectedPython.DllName
        } | Out-Null

        # 8. Sync lock file with pyproject.toml without upgrading pinned versions.
        #    UV:     'uv lock'                 - adds/removes per pyproject.toml changes.
        #    Poetry: 'poetry lock --no-update' - same intent; Poetry's documented flag.
        #    Skipped when UpdateDependencies=true (the update step regenerates the lock).
        if (-not $ctx.UpdateDependencies) {
            Invoke-SetupStep -Step '8/13' -Module 'PM' -Message ("Sync lock file with pyproject.toml ({0} lock)" -f $ctx.PackageManager) -Mandatory $true -Action {
                $lockFile = Join-Path $ctx.ProjectRoot (Get-PmLockFileName -Ctx $ctx)
                Write-LogDetail -Key 'lock_file'    -Value $lockFile
                Write-LogDetail -Key 'project_root' -Value $ctx.ProjectRoot
                Invoke-PmLockDeps -Ctx $ctx
            } | Out-Null
        } else {
            $lockFile = Join-Path $ctx.ProjectRoot (Get-PmLockFileName -Ctx $ctx)
            Write-LogDetail -Key '8/13 lock' -Value ("present={0}; will be replaced by {1} update" -f (Test-Path $lockFile -PathType Leaf), $ctx.PackageManager)
        }

        # 9. Install exact versions from lock file (default) or re-resolve (UpdateDependencies)
        if (-not $ctx.SkipPoetryInstall) {
            if ($ctx.UpdateDependencies) {
                Invoke-SetupStep -Step '9/13' -Module 'PM' -Message ("Re-resolve all dependencies ({0} update)" -f $ctx.PackageManager) -Mandatory $true -Action {
                    Write-LogDetail -Key 'project_root' -Value $ctx.ProjectRoot
                    Write-LogDetail -Key 'include_dev'  -Value $ctx.IncludeDev
                    Invoke-PmUpdateDeps -Ctx $ctx -IncludeDev $ctx.IncludeDev
                } | Out-Null
            } else {
                Invoke-SetupStep -Step '9/13' -Module 'PM' -Message ("Install from lock file ({0} install)" -f $ctx.PackageManager) -Mandatory $true -Action {
                    Write-LogDetail -Key 'project_root' -Value $ctx.ProjectRoot
                    Write-LogDetail -Key 'include_dev'  -Value $ctx.IncludeDev
                    Invoke-PmInstallDeps -Ctx $ctx -IncludeDev $ctx.IncludeDev
                } | Out-Null
            }
        }

        # 10. Write .pth file - resolve site-packages path dynamically via the venv python
        $venvPythonExe = Get-VenvPythonExe -VenvDir $ctx.VenvDir
        try {
            $spResult = & $venvPythonExe -c "import site; print(site.getsitepackages()[0])" 2>$null
            $ctx.SitePackagesDir = $spResult.Trim()
        } catch {
            # Fallback to platform-guessed path if python call fails
            $ctx.SitePackagesDir = if ($env:OS -eq 'Windows_NT') {
                Join-Path $ctx.VenvDir 'Lib\site-packages'
            } else {
                Join-Path $ctx.VenvDir 'lib' | Join-Path -ChildPath "python$($ctx.SelectedPython.Version.Split('.')[0..1] -join '.')" | Join-Path -ChildPath 'site-packages'
            }
        }
        Invoke-SetupStep -Step '10/13' -Module 'Venv' -Message 'Write project .pth into site-packages' -Mandatory $true -Action {
            Write-LogDetail -Key 'site_packages' -Value $ctx.SitePackagesDir
            Write-ProjectPth -ProjectRoot $ctx.ProjectRoot -SitePackagesDir $ctx.SitePackagesDir
        } | Out-Null

        # 11. VS Code settings
        Invoke-SetupStep -Step '11/13' -Module 'VSCode' -Message 'Pin venv interpreter in .vscode/settings.json' -Mandatory $true -Action {
            Write-LogDetail -Key 'settings_file' -Value $ctx.VscodeSettingsFile
            Write-VSCodeInterpreterSetting -VenvDir $ctx.VenvDir -SettingsFile $ctx.VscodeSettingsFile
        } | Out-Null

        # 12. Copy tcl folder into .venv (optional)
        Invoke-SetupStep -Step '12/13' -Module 'Tcl' -Message 'Copy tcl runtime into .venv' -Mandatory $false -Action {
            Copy-TclToVenv -PythonDir $ctx.SelectedPython.Directory -VenvDir $ctx.VenvDir
        } | Out-Null

        # 13. Code signing of venv executables
        # Uses $ctx.EnableCodeSigning - may have been auto-disabled by Prechecks
        # if DigiCert was not found on this machine.
        if ($ctx.EnableCodeSigning) {
            Invoke-SetupStep -Step '13/13' -Module 'CodeSigning' -Message 'Sign generated/downloaded .exe files in .venv\Scripts' -Mandatory $false -Action {
                # Store in $ctx so the result is visible outside this scriptblock scope.
                $ctx.SignResult = Sign-VenvScripts -VenvDir $ctx.VenvDir -PoetryOnly:$SignPoetryOnly
                Write-LogDetail -Key 'signed_files' -Value $ctx.SignResult.Signed
                Write-LogDetail -Key 'failed_files' -Value @($ctx.SignResult.Failed).Count
            } | Out-Null
        }

        # POST-a. Clean any stale quarantine or backup directories left by prior runs
        Invoke-SetupStep -Step 'POST-a' -Module 'Filesystem' -Message 'Clean stale .venv quarantine and backup directories' -Mandatory $false -Action {
            $removed = Remove-StaleQuarantines -ProjectRoot $ctx.ProjectRoot
            Write-LogDetail -Key 'removed_stale_dirs' -Value $removed
        } | Out-Null

        # POST-b. Remove the .venv backup from step 5b now that install succeeded
        if ($ctx.VenvBackupPath) {
            Invoke-SetupStep -Step 'POST-b' -Module 'Venv' -Message 'Remove successful .venv backup' -Mandatory $false -Action {
                Remove-VenvBackup -BackupPath $ctx.VenvBackupPath
                $ctx.VenvBackupPath = $null
            } | Out-Null
        }

        # Persist the resolved settings so the next run can skip detection.
        if (-not $script:setupDryRun) {
            try {
                # Never persist an auto-detected PM choice.
                # If we did, the next run would read 'poetry' (or 'uv') from the
                # config file and skip TOML detection entirely, even if the user
                # has since swapped their pyproject.toml.
                # Only persist when the user explicitly passed -PackageManager on the CLI.
                $configValues = @{
                    PinnedPoetryVersion = $ctx.PinnedPoetryVersion
                    PinnedUvVersion     = $ctx.PinnedUvVersion
                    IncludeDev          = $ctx.IncludeDev
                }
                if ($ctx.PmSource -eq 'cli') {
                    $configValues.PackageManager = $ctx.PackageManager
                }
                Write-SetupConfig -ProjectRoot $ctx.ProjectRoot -Values $configValues
            } catch {
                Write-Host ("  [WARN] Could not write .setup-config.json: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
            }
        }

        # Done
        Write-LogStepResult -Step 'DONE' -Module 'Core' -Status 'OK' -Message 'Setup completed successfully'

        Invoke-SetupStep -Step 'POST' -Module 'Venv' -Message 'Best-effort activate project venv in current shell' -Mandatory $false -Action {
            Invoke-VenvActivation -ProjectRoot $ctx.ProjectRoot
        } | Out-Null

        if (-not $ctx.NonInteractive) {
            Read-Host 'Press Enter to exit'
        }

        [pscustomobject]@{
            ProjectRoot        = $ctx.ProjectRoot
            ProjectName        = $ctx.ProjectName
            RequiresPython     = $ctx.RequiresPython
            PythonVersion      = $ctx.SelectedPython.Version
            PythonExe          = $ctx.SelectedPython.Exe
            PythonSource       = $ctx.SelectedPython.Source
            PackageManager     = $ctx.PackageManager
            PmSource           = $ctx.PmSource
            # Generic PM runtime fields - valid for both uv and poetry
            PmPythonPath       = $ctx.PmPythonPath
            PmShimPath         = if ($ctx.UvInfo)     { $ctx.UvInfo.Exe }          `
                                 elseif ($ctx.PoetryInfo) { $ctx.PoetryInfo.ShimPath } `
                                 else { $null }
            # Poetry-specific fields (null when PackageManager='uv')
            PoetryPython       = $ctx.PoetryPythonPath
            PoetryShimPath     = if ($ctx.PoetryInfo) { $ctx.PoetryInfo.ShimPath } else { $null }
            PoetrySource       = if ($ctx.PoetryInfo) { $ctx.PoetryInfo.Source   } else { $null }
            VenvDir            = $ctx.VenvDir
            SitePackages       = $ctx.SitePackagesDir
            VscodeSettingsFile = $ctx.VscodeSettingsFile
            SkipInstall        = $ctx.SkipPoetryInstall
            ForceRecreateVenv  = $ctx.ForceRecreateVenv
            Signing            = if ($ctx.SignResult) {
                                    [pscustomobject]@{
                                        Attempted = $true
                                        Total     = $ctx.SignResult.Total
                                        Signed    = $ctx.SignResult.Signed
                                        Failed    = @($ctx.SignResult.Failed).Count
                                    }
                                 } else { $null }
        }

    } catch {
        $details = Get-SetupErrorDetails -ErrorRecord $_

        # If the error was thrown by a mandatory Invoke-SetupStep, that step
        # already printed a full ERROR block.  We only add the outer summary
        # (with the step label) so the user can see at a glance which stage
        # caused the fatal failure - without duplicating the detail lines.
        $failStep   = if ($script:setupCurrentStep)   { $script:setupCurrentStep }   else { 'FAIL' }
        $failModule = if ($script:setupCurrentModule) { $script:setupCurrentModule } else { $details.Command }

        Write-Host ''
        Write-Host ('+' + ('-' * 94) + '+') -ForegroundColor Red
        Write-Host ("| [FATAL] Pipeline stopped at step {0} (module: {1})" -f $failStep, $failModule) -ForegroundColor Red
        Write-Host ("|   - message  : {0}" -f $details.Message)   -ForegroundColor Red
        Write-Host ("|   - location : {0}" -f $details.Location)  -ForegroundColor DarkGray
        Write-Host ("|   - error_id : {0}" -f $details.ErrorId)   -ForegroundColor DarkGray
        Write-Host ('+' + ('-' * 94) + '+') -ForegroundColor Red

        # Attempt to restore the .venv backup from step 5b so the project
        # is not left without a working environment after a failed recreate.
        if ($null -ne $ctx -and $ctx.ContainsKey('VenvBackupPath') -and $ctx.VenvBackupPath) {
            Write-Host ''
            Write-Host '  [ROLLBACK] Attempting to restore .venv from backup ...' -ForegroundColor Yellow
            try {
                Restore-VenvBackup -BackupPath $ctx.VenvBackupPath -VenvDir $ctx.VenvDir
            } catch {
                Write-Host ("  [ROLLBACK] Restore failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
            }
        }

        if (-not $NonInteractive) {
            Read-Host "`nPress Enter to exit"
        }
        throw
    }
}

Export-ModuleMember -Function Start-Setup