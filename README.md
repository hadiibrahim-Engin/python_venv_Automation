# python_venv_Automation

Windows-only PowerShell automation for creating, repairing, signing, and activating a Python virtual environment from a project root. The toolkit supports both `uv` and Poetry, can discover or validate a local Python interpreter, requires DigiCert Utility, and is designed to be safe to run repeatedly.

It is packaged as a distributable PowerShell module — **`PythonVenvAutomation`** — that exposes a single, simple global command (default name **`devsetup`**) with automatic self-updating. The original `scripts4PythonAutomation\setup-core.ps1` entry point still works for backward compatibility.

## Recommended usage

From PowerShell **or** CMD, in your project directory:

```cmd
devsetup
```

That runs the full setup pipeline against the current project. See [Command reference](#command-reference) for the rest.

## First-time installation

No administrator rights are required. The command installs into a user-local directory and adds it to your user `PATH`.

**Preferred (enterprise) method — download then run:**

```powershell
Invoke-RestMethod https://REPLACE_WITH_COMPANY_TOOLS_URL/devsetup/install.ps1 -OutFile install-devsetup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-devsetup.ps1
```

**Convenience method (one-liner):**

```powershell
irm https://REPLACE_WITH_COMPANY_TOOLS_URL/devsetup/install.ps1 | iex
```

> The two-step download-and-run method is the **recommended** approach for enterprise environments — you can review `install-devsetup.ps1` before executing it. The `irm | iex` form is documented only as a developer convenience.

**From CMD:**

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-RestMethod https://REPLACE_WITH_COMPANY_TOOLS_URL/devsetup/install.ps1 -OutFile install-devsetup.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File .\install-devsetup.ps1"
```

After installation, open a **new** PowerShell or CMD window and run `devsetup`.

The user-facing install URL (`https://REPLACE_WITH_COMPANY_TOOLS_URL/devsetup/install.ps1`) is intended to be a **stable** address managed by IT. It can point at a GitHub Release asset, an Azure Pipelines artifact, or a static internal URL — and it stays stable even if the backend artifact store changes.

## Command reference

```cmd
devsetup                 Run full setup (same as: devsetup setup)
devsetup update          Refresh existing .venv without reinstalling tools
devsetup upgrade         Refresh existing .venv and upgrade dependencies
devsetup rebuild         Remove and recreate .venv
devsetup dry             Print the planned setup without modifying files
devsetup prod            Install production dependencies only
devsetup list-python     Show/select available Python interpreters
devsetup self-update     Update this automation command and module now
devsetup help            Show help
```

Mapping to the engine:

| Friendly command | Engine call |
| --- | --- |
| `devsetup` / `devsetup setup` | `Invoke-PythonVenvSetup` |
| `devsetup update` | `Invoke-PythonVenvSetup -Mode update-venv` |
| `devsetup upgrade` | `Invoke-PythonVenvSetup -Mode update-venv -UpdateDependencies` |
| `devsetup rebuild` | `Invoke-PythonVenvSetup -ForceRecreateVenv` |
| `devsetup dry` | `Invoke-PythonVenvSetup -DryRun` |
| `devsetup prod` | `Invoke-PythonVenvSetup -ExcludeDev` |
| `devsetup list-python` | `Invoke-PythonVenvSetup -ListMode` |
| `devsetup self-update` | `Update-PythonVenvAutomation` |

## Advanced usage

Everything after `--` is forwarded verbatim to `Invoke-PythonVenvSetup`, so the full parameter surface stays available:

```cmd
devsetup -- -PackageManager uv -NonInteractive
devsetup update -- -UpgradePackage requests
devsetup dry -- -PackageManager poetry
```

Preserved engine options include: `-PackageManager auto|uv|poetry`, `-Mode setup|update-venv|venv-update|refresh-venv`, `-PythonExePath`, `-ListMode`, `-UpdateDependencies`, `-ExcludeDev`, `-DryRun`, `-NonInteractive`, `-ForceRecreateVenv`, `-DigiCertUtilityExe`, `-SkipPythonInstall`, `-AllowPythonInstall`, `-UnblockScripts`, `-ContinueOnPrecheckFailure`, `-UpgradePackage`, and `-PinExact`.

## Automatic updates

Every `devsetup` run first checks whether the installed `PythonVenvAutomation` module is current, **before** importing it:

- If a newer approved version exists, it updates automatically and then re-runs your command once.
- You normally never need to run `devsetup self-update` — it is there for manual repair/update.
- `devsetup --no-self-update` skips the check for a single invocation.
- `devsetup --force-self-update` forces a check before running.
- Offline users continue with their installed version when it is acceptable; the run fails clearly only when no acceptable local version exists.
- Concurrent terminals are protected by an update lock so the module on disk is never corrupted.

```cmd
devsetup
devsetup --no-self-update dry
devsetup --force-self-update
devsetup self-update
```

> `--no-self-update` / `--force-self-update` are **shim-level flags** consumed by the command itself — they are never forwarded to the engine. They are distinct from raw passthrough after `--`, so `devsetup update -- -UpgradePackage requests` still works.

IT/admins control update behavior at install time:

```powershell
.\install.ps1 -AutoUpdatePolicy LatestStable
.\install.ps1 -AutoUpdatePolicy MinimumRequired -RequiredVersion 1.2.0
.\install.ps1 -AutoUpdatePolicy Pinned -RequiredVersion 1.2.0
.\install.ps1 -DisableAutoUpdate
```

Policies: **LatestStable** (default — install/update to the newest stable), **MinimumRequired** (ensure at least `RequiredVersion`), **Pinned** (install/use exactly `RequiredVersion`), **Disabled** (skip auto-checks; manual `self-update` still works).

Runtime configuration is stored under `%LOCALAPPDATA%\Company\PythonVenvAutomation\config.json` and is read by the command on every run.

## Changing the command name

The command name is defined in exactly one place:

```text
PythonVenvAutomation/config/CommandName.ps1
```

```powershell
$Script:DevSetupCommandName = 'envctl'
```

After changing it, regenerate the shims:

```powershell
Install-DevSetupCommand -Force
```

The generated command then becomes `envctl` (`envctl.ps1`, `envctl.cmd`), and the help text, installer output, and runtime config all use the new name automatically. No other code changes are required.

## Backward compatibility

The original entry point still works exactly as before:

```powershell
.\scripts4PythonAutomation\setup-core.ps1
.\scripts4PythonAutomation\setup-core.ps1 -DryRun
.\scripts4PythonAutomation\setup-core.ps1 -Mode update-venv
.\scripts4PythonAutomation\setup-core.ps1 -ForceRecreateVenv
```

It is now a thin wrapper that imports `PythonVenvAutomation` (falling back to the local repository copy if the module is not installed) and forwards to `Invoke-PythonVenvSetup`. `devsetup` is the recommended interface going forward.

## Module layout

```text
PythonVenvAutomation/
├─ PythonVenvAutomation.psd1      # manifest (ModuleVersion kept in sync with VERSION)
├─ PythonVenvAutomation.psm1      # loader: config -> Private -> Public -> engine
├─ Public/                        # 4 exported commands
├─ Private/                       # helpers (command name, shim, config, version/update)
├─ config/CommandName.ps1         # single source of truth for the command name
├─ templates/                     # shim .ps1/.cmd templates + DevSetup.Bootstrap.ps1
├─ bin/  docs/  engine/           # engine/ is bundled at build time
VERSION                           # single source of truth for the module version
install.ps1                       # standalone installer
build/                            # Test.ps1 / Build.ps1 / Publish.ps1 / Update-Version.ps1
azure-pipelines.yml               # Validate / Build / Publish (Azure DevOps)
.github/workflows/publish.yml     # validate / build / publish (GitHub)
```

## Public commands (programmatic use)

```powershell
Import-Module PythonVenvAutomation

Invoke-PythonVenvSetup [-Mode ...] [-DryRun] [-ForceRecreateVenv] ...   # wraps Start-Setup
Install-DevSetupCommand [-Force] [-AutoUpdatePolicy ...] [-DisableAutoUpdate]
Update-PythonVenvAutomation                                              # manual self-update
Get-PythonVenvSetupInfo                                                  # diagnostics
```

## Requirements

- Windows
- PowerShell 5.1 or newer, or `pwsh` (the command prefers `pwsh`, falls back to `powershell.exe`)
- Python `>=3.11` and `<3.13`
- DigiCert Utility for a real setup run
- A project root that contains `pyproject.toml`

The script aborts immediately when run outside Windows. DigiCert is treated as required infrastructure: if DigiCert Utility is missing on Windows, prechecks abort before setup mutates the environment.

## Updating an existing venv only

Use update mode when `.venv` already exists and you only want to refresh dependencies:

```cmd
devsetup update
```

or, via the legacy entry point:

```powershell
.\scripts4PythonAutomation\setup-core.ps1 -Mode update-venv
```

This validates the existing `.venv`, detects the dependency system, and runs the appropriate refresh command without reinstalling Python, Poetry, uv, recreating `.venv`, writing editor settings, copying DLLs, or code-signing executables.

- uv projects run `uv sync` by default.
- Poetry projects run `poetry install` by default.
- `requirements.txt` projects run `.venv\Scripts\python.exe -m pip install -r requirements.txt`.
- `devsetup upgrade` (or `-Mode update-venv -UpdateDependencies`) intentionally upgrades all dependencies.
- `devsetup update -- -UpgradePackage "name"` refreshes selected uv/Poetry packages only.

If the required dependency CLI is missing, update mode stops with a clear message instead of bootstrapping tools. Run the full setup once to install missing tooling.

## Activation

After setup completes, activate the environment in the current shell by dot-sourcing the activation script:

```powershell
. .\scripts4PythonAutomation\activate-venv.ps1
```

Do not run that script directly — it is meant to modify the current shell session, which only works when it is dot-sourced.

## How the pipeline works

The setup flow is a fixed pipeline inside `Start-Setup` (unchanged by this distribution layer):

1. Require a Windows host.
2. Detect the package manager from CLI overrides, cached config, `pyproject.toml`, or lock files.
3. Run prechecks (including the required DigiCert check).
4. Parse project metadata from `pyproject.toml`.
5. Resolve a compatible Python interpreter.
6. Ensure the package-manager runtime exists.
7. Configure package-manager defaults and persist installed tool directories on PATH.
8. Create or refresh `.venv`; validate and copy runtime assets. An existing `.venv` that fails the Python-compatibility check (missing/broken interpreter, or no longer satisfying `requires-python`) is backed up and recreated automatically here — `-ForceRecreateVenv` / `devsetup rebuild` is only needed to force a rebuild of an otherwise-healthy `.venv`.
9. Sync the lock file or re-resolve dependencies, then install.
10. Write project wiring (`.pth`, VS Code settings), copy Tcl runtime, and code-sign executables.

The flowchart in [scripts4PythonAutomation/Flow.md](scripts4PythonAutomation/Flow.md) contains a detailed Mermaid version. For a full command-by-command reference, run [scripts4PythonAutomation/Get-SetupHelp.ps1](scripts4PythonAutomation/Get-SetupHelp.ps1).

## pyproject templates

```powershell
Copy-Item .\templates\pyproject.uv.toml .\pyproject.toml
Copy-Item .\templates\pyproject.poetry.toml .\pyproject.toml
Remove-Item .setup-config.json -ErrorAction SilentlyContinue
devsetup dry -- -PackageManager auto
```

The uv template uses `[project]` plus `[tool.uv]` and no Poetry sections; the Poetry template uses `[tool.poetry]` plus `poetry.core.masonry.api` and no uv sections. That keeps auto-detection deterministic.

## Versioning and releases

- The module version lives in one place: the repo-root `VERSION` file. `build\Update-Version.ps1` keeps the manifest in sync, and `build\Build.ps1` fails the build if they ever differ.
- Releases are cut from semantic version tags: `v1.0.0`, `v1.0.1`, `v1.1.0`, `v2.0.0`.
- Pull requests and normal branches run validation only; version tags (`v*`) run validate + build + publish.

Build scripts:

```powershell
.\build\Test.ps1            # syntax + manifest + import + command-name + Pester (mocked; no real pipeline)
.\build\Build.ps1           # clean, stage, bundle engine, validate, package into artifacts/
.\build\Publish.ps1 -RepositoryName <name> -RepositoryUri <uri> [-ApiKey <key>] [-Prerelease]
.\build\Update-Version.ps1 -Version 1.2.0 [-ValidateGitTag v1.2.0]
```

## Azure DevOps publishing

`azure-pipelines.yml` defines three stages — **Validate**, **Build**, **Publish**:

- Pull requests and branch pushes run **Validate** (and **Build**).
- Version tags `v*` additionally run **Publish** to an Azure Artifacts NuGet feed.

Adapt by editing only the variables at the top:

```yaml
variables:
  PSRepositoryName: 'CompanyPS'
  PSRepositoryUri: 'https://pkgs.dev.azure.com/REPLACE_ORG/REPLACE_PROJECT/_packaging/REPLACE_FEED/nuget/v3/index.json'
```

The feed API key must be provided as a **secure pipeline variable** named `NUGET_API_KEY` (or a variable group / library). It is mapped into the publish step's environment and is never printed.

## GitHub publishing

`.github/workflows/publish.yml` defines **validate**, **build**, and **publish** jobs:

- Pull requests run **validate**; pushes to `main` run **validate + build**.
- Version tags `v*` additionally **publish** the module to GitHub Packages and attach `install.ps1` to the GitHub Release.

Adapt by editing only the environment block at the top:

```yaml
env:
  PS_REPOSITORY_NAME: GitHubPackages
  PS_REPOSITORY_URI: https://nuget.pkg.github.com/REPLACE_OWNER/index.json
```

Publishing authenticates with `GITHUB_TOKEN` (swap for a PAT secret if your org requires one). Tokens are passed through environment secrets and are never printed.

## Artifact feed configuration

The package backend is decoupled from the user-facing install URL and from the core module code. It can be:

- an Azure Artifacts NuGet feed,
- a GitHub Packages NuGet registry,
- any internal NuGet-compatible feed, or
- an internal file-based PowerShell repository.

Switching backends is done by changing configuration values (`RepositoryName` / `RepositoryUri` in `install.ps1`, runtime config, and the pipeline variables) — **not** by editing module code.

## Security

- No credentials or tokens are committed; pipelines use Azure secure variables / GitHub Actions secrets.
- Publishing fails closed when authentication is unavailable, and never echoes the API key.
- Installs use `CurrentUser` scope and never require admin rights.
- The two-step download-and-run installer is the recommended enterprise method; `irm | iex` is documented only as convenience.

## Troubleshooting

- `devsetup help` prints the full command list. `Get-PythonVenvSetupInfo` reports installed version, shim paths, and the effective runtime config.
- If the legacy script is launched from the VS Code integrated terminal, it detaches into a plain PowerShell subprocess to avoid opening every module file in the editor.
- If setup says it is Windows-only, run it from Windows PowerShell or `pwsh` on Windows.
- If activation does not affect the current shell, use the dot-sourced form: `. .\scripts4PythonAutomation\activate-venv.ps1`.
- If DigiCert is missing, install DigiCert Utility or pass `-DigiCertUtilityExe`. Setup aborts before making changes.
- If PowerShell reports blocked scripts, run with `-UnblockScripts` once, then rerun normally.
- If the environment is corrupted, use `devsetup rebuild` to recreate it cleanly.
