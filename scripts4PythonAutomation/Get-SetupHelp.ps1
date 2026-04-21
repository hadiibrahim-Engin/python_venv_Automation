#Requires -Version 5.1
# =============================================================================
# Script  : Get-SetupHelp.ps1

# Author  : Hadi Ibrahim
#
# Run this script to print the full setup reference to your console:
#   .\scripts\Get-SetupHelp.ps1
#
# Or pipe it to more for paged output:
#   .\scripts\Get-SetupHelp.ps1 | more
# =============================================================================

<#
.SYNOPSIS
    Displays the complete command reference for the pyfactory setup automation.

.DESCRIPTION
    Prints all available scripts, parameters, options, common usage recipes,
    the 13-step pipeline overview, and troubleshooting notes for setup-core.ps1.

.EXAMPLE
    .\scripts\Get-SetupHelp.ps1

.EXAMPLE
    .\scripts\Get-SetupHelp.ps1 | more
#>

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function h1 { param([string]$t) Write-Host "`n$t" -ForegroundColor Cyan;  Write-Host ('=' * $t.Length) -ForegroundColor DarkCyan }
function h2 { param([string]$t) Write-Host "`n  $t" -ForegroundColor Yellow; Write-Host ('  ' + ('-' * $t.Length)) -ForegroundColor DarkYellow }
function ln { param([string]$t = '') Write-Host "  $t" }
function kv { param([string]$k, [string]$v) Write-Host ("    {0,-30} {1}" -f $k, $v) -ForegroundColor Gray }
function ex { param([string]$t) Write-Host "    $t" -ForegroundColor DarkGray }
function hl { param([string]$t) Write-Host "    $t" -ForegroundColor White }
function warn { param([string]$t) Write-Host "  [!] $t" -ForegroundColor Yellow }


# ===========================================================================
h1 'pyfactory / pythonAutomation — Setup Reference'
# ===========================================================================
ln
ln 'Automates Python 3.11 virtual-environment creation and dependency installation.'
ln 'Supports two package managers (Poetry, UV — auto-detected from pyproject.toml),'
ln 'optional DigiCert code signing, DryRun mode, rollback on failure, and three Python-selection modes.'


# ---------------------------------------------------------------------------
h1 'AVAILABLE SCRIPTS'
# ---------------------------------------------------------------------------

h2 'setup-core.ps1  (main entry point)'
ln 'Location : .\scripts\setup-core.ps1'
ln 'Purpose  : Runs the full 13-step setup pipeline.'
ln 'Usage    :'
ex '.\scripts\setup-core.ps1  [options...]'
ln
warn 'Must be run from a PowerShell console (pwsh.exe or powershell.exe).'
warn 'If ExecutionPolicy blocks the script, run once with:'
ex 'powershell.exe -ExecutionPolicy Bypass -File .\scripts\setup-core.ps1'

h2 'activate-venv.ps1  (post-setup activation)'
ln 'Location : .\scripts\activate-venv.ps1'
ln 'Purpose  : Activates the project .venv in your current shell session.'
ln 'Usage    :'
ex '. .\scripts\activate-venv.ps1'
ln
warn 'MUST be dot-sourced (note the leading dot).  Running it directly'
warn 'activates only a transient subprocess — your shell stays unaffected.'


# ===========================================================================
h1 'PARAMETERS — setup-core.ps1'
# ===========================================================================
ln 'All parameters are optional.  Running without any argument starts the'
ln 'interactive Python-selection prompt and uses all defaults.'


# ---------------------------------------------------------------------------
h2 '-PackageManager  <auto | poetry | uv>   (default: auto)'
# ---------------------------------------------------------------------------
ln
ln '  Selects which package manager installs project dependencies.'
ln '  When omitted (or set to auto), the script detects the right manager'
ln '  automatically from the project files — no flag needed in most cases.'
ln
hl '  auto  (default)'
ln '    Detection order (first match wins):'
ln '      1. pyproject.toml sections (strongest signal — what the project was written for):'
ln '           [tool.uv] present, no [tool.poetry]  → uv'
ln '           [tool.poetry] present, no [tool.uv]  → poetry'
ln '           (comment lines are stripped before matching to avoid false positives)'
ln '      2. Lock files (tiebreaker for dual-mode projects):'
ln '           uv.lock only → uv;  poetry.lock only → poetry'
ln '           Both present: the more recently modified one wins'
ln '      3. No signal: falls back to poetry'
ln '    Result is printed in the SETUP log line as "(auto-detected)".'
ln '    Persisted to .setup-config.json after a successful run.'
ln
hl '  poetry'
ln '    Uses [tool.poetry] in pyproject.toml and poetry.lock.'
ln '    Installs / updates via  poetry install  /  poetry update.'
ln '    Auto-installs Poetry if not found.'
ln
hl '  uv'
ln '    Uses [project] (PEP 621) in pyproject.toml and uv.lock.'
ln '    Installs / updates via  uv sync  /  uv sync --upgrade.'
ln '    Auto-installs uv if not found.'
ln
ln '  Examples:'
ex '.\scripts\setup-core.ps1                       # auto-detects'
ex '.\scripts\setup-core.ps1 -PackageManager poetry  # override → poetry'
ex '.\scripts\setup-core.ps1 -PackageManager uv      # override → uv'


# ---------------------------------------------------------------------------
h2 '-PythonExePath  <path>'
# ---------------------------------------------------------------------------
ln
ln '  Provides an explicit path to python.exe.  Bypasses the interactive'
ln '  Python-selection prompt entirely.  The interpreter is validated against'
ln '  the requires-python constraint in pyproject.toml (>=3.11, <3.12).'
ln
ln '  Examples:'
ex '.\scripts\setup-core.ps1 -PythonExePath "C:\Python311\python.exe"'
ex '.\scripts\setup-core.ps1 -PythonExePath "C:\Users\you\AppData\Local\Programs\Python\Python311\python.exe"'


# ---------------------------------------------------------------------------
h2 '-UpdateDependencies  [switch]   (default: off)'
# ---------------------------------------------------------------------------
ln
ln '  Re-resolves all dependencies to the latest versions allowed by the'
ln '  constraints in pyproject.toml and rewrites the lock file.'
ln
hl '  Off (default)'
ln '    poetry install  — installs exact versions from poetry.lock (reproducible).'
ln '    uv sync         — installs exact versions from uv.lock     (reproducible).'
ln
hl '  On (-UpdateDependencies)'
ln '    poetry update   — re-resolves; rewrites poetry.lock.'
ln '    uv sync --upgrade — re-resolves; rewrites uv.lock.'
ln
ln '  Examples:'
ex '.\scripts\setup-core.ps1 -UpdateDependencies'
ex '.\scripts\setup-core.ps1 -PackageManager uv -UpdateDependencies'


# ---------------------------------------------------------------------------
h2 '-ExcludeDev  [switch]   (default: off — dev deps included)'
ln
ln '  Installs production dependencies only, excluding dev/test extras.'
ln
hl '  Off (default)'
ln '    UV:     uv sync --all-extras   — includes optional/dev extras.'
ln '    Poetry: poetry install         — includes [dev] group.'
ln
hl '  On (-ExcludeDev)'
ln '    UV:     uv sync                — no --all-extras.'
ln '    Poetry: poetry install --without dev'
ln
ln '  Examples:'
ex '.\scripts\setup-core.ps1 -ExcludeDev'
ex '.\scripts\setup-core.ps1 -PackageManager uv -ExcludeDev'


# ---------------------------------------------------------------------------
h2 '-DryRun  [switch]   (default: off)'
# ---------------------------------------------------------------------------
ln
ln '  Prints every pipeline step header and detail lines but executes no actions.'
ln '  The file system is not modified.  Useful to preview what setup will do,'
ln '  verify parameter resolution, and check which package manager is detected.'
ln
ln '  Examples:'
ex '.\scripts\setup-core.ps1 -DryRun'
ex '.\scripts\setup-core.ps1 -PackageManager uv -DryRun'
ex '.\scripts\setup-core.ps1 -DryRun -UpdateDependencies'


# ---------------------------------------------------------------------------
h2 '-ListMode  [switch]   (default: off)'
# ---------------------------------------------------------------------------
ln
ln '  Shows every Python interpreter discovered on this machine in a numbered'
ln '  table.  Each row displays the version, path, and a compatibility badge:'
ln
ln '      [OK]  — meets the pyproject.toml constraint (>=3.11, <3.12)'
ln '      [--]  — outside the constraint (can be shown, cannot be selected)'
ln
ln '  The user types a number to select an interpreter.  Incompatible picks'
ln '  are rejected and the prompt repeats.'
ln
ln '  Examples:'
ex '.\scripts\setup-core.ps1 -ListMode'
ex '.\scripts\setup-core.ps1 -ListMode -PackageManager uv'


# ===========================================================================
h1 'PARAMETERS — Start-Setup  (programmatic / advanced)'
# ===========================================================================
ln 'These parameters are only available when calling Start-Setup directly from'
ln 'another PowerShell script via  Import-Module .\scripts\Setup-Core.psm1.'
ln 'They are NOT exposed by setup-core.ps1.'

h2 'Venv control'
ln
kv '-ProjectRoot <string>'       "Project root containing pyproject.toml.  Default: current directory."
kv '-ForceRecreateVenv <bool>'   "Remove and recreate .venv on every run.  Default: `$true."
kv '-SkipInstall <bool>'         "Skip dependency installation (Steps 8-9).  Default: `$false."
kv '-NonInteractive <bool>'      "No pause prompts; exceptions propagate instead.  Default: `$false."

h2 'Code signing'
ln
kv '-EnableCodeSigning <bool>'        "Sign executables with DigiCert.  Default: `$true."
kv '                                ' "(Auto-disabled by Prechecks if DigiCert is not found.)"
kv '-DigiCertUtilityExe <string>'     "Path to DigiCertUtil.exe."
kv '                                ' "Default: C:\Program Files\DigiCertUtility\DigiCertUtil.exe"
kv '-KernelDriverSigning <bool>'      "Use kernel-driver signing mode.  Default: `$false."
kv '-SignPoetryOnly <bool>'           "Sign only the PM shim, not all .venv\Scripts exes.  Default: `$false."
kv '-RequirePoetryShimSigning <bool>' "Make PM shim signing a mandatory step.  Default: `$true."

h2 'Programmatic example'
ln
ex 'Import-Module .\scripts\Setup-Core.psm1'
ex 'Start-Setup -ProjectRoot "C:\projects\pyfactory" `'
ex '           -PackageManager uv `'
ex '           -NonInteractive $true `'
ex '           -EnableCodeSigning $false `'
ex '           -UpdateDependencies $false'


# ===========================================================================
h1 'COMMON USAGE RECIPES'
# ===========================================================================

h2 'Fresh setup on a new machine  (default Poetry, interactive Python pick)'
ex '.\scripts\setup-core.ps1'

h2 'Fresh setup with UV as package manager'
ex '.\scripts\setup-core.ps1 -PackageManager uv'

h2 'Upgrade all dependencies to latest allowed versions  (Poetry)'
ex '.\scripts\setup-core.ps1 -UpdateDependencies'

h2 'Upgrade all dependencies to latest allowed versions  (UV)'
ex '.\scripts\setup-core.ps1 -PackageManager uv -UpdateDependencies'

h2 'Pin a specific Python interpreter and run non-interactively'
ex '.\scripts\setup-core.ps1 -PythonExePath "C:\Python311\python.exe"'

h2 'Browse all installed Pythons and pick manually'
ex '.\scripts\setup-core.ps1 -ListMode'

h2 'Production install only (no dev/test dependencies)'
ex '.\scripts\setup-core.ps1 -ExcludeDev'

h2 'Preview the pipeline without touching the file system'
ex '.\scripts\setup-core.ps1 -DryRun'
ex '.\scripts\setup-core.ps1 -PackageManager uv -DryRun'

h2 'CI / headless pipeline  (no prompts, fail fast)'
ex 'Import-Module .\scripts\Setup-Core.psm1'
ex 'Start-Setup -NonInteractive $true -EnableCodeSigning $false'

h2 'Activate the venv after setup  (in the same shell)'
ex '. .\scripts\activate-venv.ps1'

h2 'ExecutionPolicy blocked — run once without changing system policy'
ex 'powershell.exe -ExecutionPolicy Bypass -File .\scripts\setup-core.ps1'
ex 'pwsh.exe       -ExecutionPolicy Bypass -File .\scripts\setup-core.ps1'


# ===========================================================================
h1 'PYTHON SELECTION — INTERACTIVE PROMPT'
# ===========================================================================
ln
ln '  When setup-core.ps1 starts without -PythonExePath, it shows:'
ln
ln '    +----------------------------------------------------------+'
ln '    |  How should Setup select a Python interpreter?           |'
ln '    +----------------------------------------------------------+'
ln '    |  [Enter]   Semi-auto  – script finds best compatible     |'
ln '    |             Python automatically (recommended)           |'
ln '    |  [l]       List       – show ALL Pythons, you pick one   |'
ln '    |  <path>    Explicit   – full path to python.exe          |'
ln '    +----------------------------------------------------------+'
ln
kv '[Enter]  Semi-auto' 'Script scans PATH, registry, and known install locations,'
ln "                               selects the highest compatible Python (>=3.11, <3.12)."
ln "                               Runs without further prompts — recommended for most users."
ln
kv '[l]  List'          'Displays all discovered Python interpreters with compatibility'
ln "                               badges, then waits for a number input."
ln
kv '<path>  Explicit'   'Accepts a full path, e.g. C:\Python311\python.exe'
ln "                               Validated against pyproject.toml constraints."


# ===========================================================================
h1 '13-STEP PIPELINE OVERVIEW'
# ===========================================================================
ln '  Each step is logged with its status (OK / WARN / ERROR) and duration.'
ln
kv ' 0/13  Prechecks'          'Network + DigiCert checks; non-critical failures auto-disabled.'
kv ' 1/13  Parse metadata'     'Read pyproject.toml — project name, requires-python.'
kv ' 2/13  Resolve Python'     'Find or validate the target Python interpreter.'
kv ' 3/13  PM runtime'         'Ensure Poetry / uv is installed; auto-installs if missing.'
kv '3a/13  Sign PM exe'        'Code-sign the PM executable (poetry.exe shim or uv.exe).'
kv ' 4/13  Configure PM'       'Poetry: set virtualenvs.in-project = true.  UV: no-op.'
kv '5a/13  Clean envs'         'Poetry: remove stale env associations.  UV: no-op.'
kv '5b/13  Backup + remove'    'Snapshot .venv → .venv_backup_<ts> for rollback; then remove.'
kv '5c/13  Prepare .venv'      'Create .venv and pin it to the selected Python.'
kv ' 6/13  Validate .venv'     'Verify .venv directory structure is complete.'
kv ' 7/13  Copy DLL'           'Copy pythonXY.dll into .venv for runtime isolation.'
kv ' 8/13  Sync lock file'     'uv lock  /  poetry lock --no-update — align with pyproject.toml.'
kv ' 9/13  Install deps'       'uv sync  /  poetry install  (or upgrade variants).'
kv '10/13  Write .pth'         'Add project root to .venv site-packages via .pth file.'
kv '11/13  VS Code settings'   'Write .vscode/settings.json to point at the new .venv.'
kv '12/13  Copy tcl'           'Copy tcl/tk runtime into .venv if present (optional).'
kv '13/13  Sign executables'   'DigiCert-sign generated .exe files under .venv\Scripts.'
kv 'POST-a  Cleanup'           'Remove stale .venv_backup_* and .venv._stale_* directories.'
kv 'POST-b  Remove backup'     'Delete .venv_backup_<ts> created at 5b after successful install.'
kv 'POST    Activate'          'Dot-source activate-venv.ps1 in the current shell (best-effort).'
ln
ln '  On failure at any mandatory step:'
ln '    → If a .venv backup was created at 5b, it is automatically restored.'


# ===========================================================================
h1 'EXIT CODES'
# ===========================================================================
ln
kv '0' 'Setup completed successfully.'
kv '1' 'Setup failed — check the ERROR block printed above for the failing step.'


# ===========================================================================
h1 'PROJECT FILES AFFECTED BY SETUP'
# ===========================================================================
ln
kv '.venv\'                         'Virtual environment (recreated on every run by default).'
kv '.vscode\settings.json'          'Updated to point python.defaultInterpreterPath at .venv.'
kv 'poetry.lock  /  uv.lock'        'Lock file written or updated by steps 8-9.'
kv '.venv\Lib\site-packages\*.pth'  'Project root path entry written by step 10.'
kv '.setup-config.json'             'Persisted after a successful run: PackageManager, PinnedVersions,'
kv '                            '   'IncludeDev.  Read at startup to skip re-detection next run.'


# ===========================================================================
h1 'PACKAGE MANAGER COMPARISON'
# ===========================================================================
ln
kv 'Feature'              'poetry                    uv'
kv '-------'              '-----------------------   -----------------------'
kv 'Config section'       '[tool.poetry]             [project]  (PEP 621)'
kv 'Lock file'            'poetry.lock               uv.lock'
kv 'Install command'      'poetry install            uv sync'
kv 'Upgrade command'      'poetry update             uv sync --upgrade'
kv 'Lock command'         'poetry lock --no-update   uv lock'
kv 'Venv creation'        'poetry env use <python>   uv venv --python <exe>'
kv 'Git dependencies'     '[tool.poetry.dependencies] (source URL)    [tool.uv.sources]'
kv 'Auto-install'         'Yes (via pip / installer)  Yes (astral.sh installer)'
kv 'Signed on install'    'Yes (poetry.exe shim)      Yes (uv.exe binary)'


# ===========================================================================
h1 'TROUBLESHOOTING'
# ===========================================================================

h2 'ExecutionPolicy error on first run'
ln '  Run once with -ExecutionPolicy Bypass (does not change system policy):'
ex '  powershell.exe -ExecutionPolicy Bypass -File .\scripts\setup-core.ps1'

h2 'Wrong Python version selected'
ln '  Pass the exact path to avoid auto-detection:'
ex '  .\scripts\setup-core.ps1 -PythonExePath "C:\Python311\python.exe"'
ln '  Or use list mode to see all candidates and pick manually:'
ex '  .\scripts\setup-core.ps1 -ListMode'

h2 '"pyproject.toml changed significantly since poetry.lock was last generated"'
ln '  Step 8 (lock sync) prevents this automatically on normal runs.'
ln '  If you see it anyway, force an update pass:'
ex '  .\scripts\setup-core.ps1 -UpdateDependencies'

h2 'DigiCert not found — signing skipped'
ln '  This is a non-critical precheck.  Setup auto-disables signing and'
ln '  continues normally.  To suppress the warning permanently, call:'
ex '  Start-Setup -EnableCodeSigning $false'

h2 'Venv activation has no effect in current shell'
ln '  You likely ran activate-venv.ps1 directly instead of dot-sourcing it:'
ex '  WRONG : .\scripts\activate-venv.ps1'
ex '  RIGHT : . .\scripts\activate-venv.ps1'

h2 'Wrong package manager detected'
ln '  Add the relevant section to pyproject.toml to make detection unambiguous:'
ex '  For UV     →  add [tool.uv] section (e.g. [tool.uv.sources] with at least one entry)'
ex '  For Poetry →  add [tool.poetry] section'
ln '  Or override permanently via the config file:'
ex '  .\scripts\setup-core.ps1 -PackageManager uv   # writes uv to .setup-config.json'

h2 'Delete .setup-config.json to force re-detection'
ln '  The config file persists settings between runs.  To reset to auto-detection:'
ex '  Remove-Item .setup-config.json'

h2 'Setup failed mid-way — .venv is gone'
ln '  If -ForceRecreateVenv is active (the default), a backup is created before deletion.'
ln '  On failure, setup restores the backup automatically.'
ln '  If the backup directory (.venv_backup_<timestamp>) is still present, restore manually:'
ex '  Rename-Item -LiteralPath .venv_backup_20250414_120000 -NewName .venv'

ln
ln '  Run this help file at any time:'
ex '  .\scripts\Get-SetupHelp.ps1'
ln