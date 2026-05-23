# python_venv_Automation

Windows-only PowerShell automation for creating, repairing, signing, and activating a Python virtual environment from a project root. The toolkit supports both `uv` and Poetry, can discover or validate a local Python interpreter, requires DigiCert Utility, and is designed to be safe to run repeatedly.

## What this project does

This repository provides an end-to-end setup pipeline for Python projects that need a pinned `.venv`, consistent dependency installation, and optional editor integration.

At a high level it can:

- detect the package manager from project metadata or lock files
- find or validate a compatible Python interpreter
- create or rebuild `.venv`
- install dependencies from the lock file or re-resolve them
- write local project wiring such as `.pth` and VS Code settings
- copy Tcl runtime files when present and sign generated executables
- activate the environment in the current shell after setup

## Main files

- [scripts4PythonAutomation/setup-core.ps1](scripts4PythonAutomation/setup-core.ps1) is the main entry point.
- [scripts4PythonAutomation/Setup-Core.psm1](scripts4PythonAutomation/Setup-Core.psm1) loads the modular pipeline and exposes `Start-Setup`.
- [scripts4PythonAutomation/activate-venv.ps1](scripts4PythonAutomation/activate-venv.ps1) activates the created virtual environment and must be dot-sourced.
- [scripts4PythonAutomation/Get-SetupHelp.ps1](scripts4PythonAutomation/Get-SetupHelp.ps1) prints the full command reference.
- [scripts4PythonAutomation/Flow.md](scripts4PythonAutomation/Flow.md) shows the setup flow with Mermaid diagrams.
- [pyproject.toml](pyproject.toml) contains the project metadata and dependency constraints used by the setup logic.
- [templates/pyproject.uv.toml](templates/pyproject.uv.toml) is a copy-ready uv/PEP 621 template.
- [templates/pyproject.poetry.toml](templates/pyproject.poetry.toml) is a copy-ready Poetry template.

## Requirements

- Windows
- PowerShell 5.1 or newer, or `pwsh`
- Python `>=3.11` and `<3.13`
- DigiCert Utility for a real setup run
- A project root that contains `pyproject.toml`

The project currently signals `uv` as the preferred package manager through `pyproject.toml`, but the tooling can also work with Poetry when that is the right choice for the repository.

The script aborts immediately when run outside Windows. DigiCert is treated as required infrastructure, not a best-effort enhancement. If DigiCert Utility is missing on Windows, prechecks abort before setup mutates the environment.

## Quick Start

Run the setup script from the repository root:

```powershell
.\scripts4PythonAutomation\setup-core.ps1
```

Common variations:

```powershell
.\scripts4PythonAutomation\setup-core.ps1 -DryRun
.\scripts4PythonAutomation\setup-core.ps1 -ExcludeDev
.\scripts4PythonAutomation\setup-core.ps1 -UpdateDependencies
.\scripts4PythonAutomation\setup-core.ps1 -ListMode
.\scripts4PythonAutomation\setup-core.ps1 -PackageManager uv
.\scripts4PythonAutomation\setup-core.ps1 -PythonExePath "C:\Python311\python.exe"
.\scripts4PythonAutomation\setup-core.ps1 -ForceRecreateVenv
.\scripts4PythonAutomation\setup-core.ps1 -NonInteractive
```

If PowerShell blocks downloaded files because of Zone.Identifier metadata, unblock the toolkit explicitly:

```powershell
.\scripts4PythonAutomation\setup-core.ps1 -UnblockScripts -DryRun
```

## Activation

After setup completes, activate the environment in the current shell by dot-sourcing the activation script:

```powershell
. .\scripts4PythonAutomation\activate-venv.ps1
```

Do not run that script directly. It is meant to modify the current shell session, which only works when it is dot-sourced.

## Supported options

`setup-core.ps1` supports the following commonly used switches and parameters:

- `-PackageManager auto|uv|poetry` selects the dependency tool. `auto` is the default.
- `-PythonExePath` points at a specific `python.exe` and bypasses interactive interpreter selection.
- `-ListMode` shows all discovered Python interpreters and lets you choose one interactively.
- `-UpdateDependencies` re-resolves dependency versions instead of installing from the existing lock file.
- `-ExcludeDev` installs production dependencies only.
- `-DryRun` prints the pipeline without changing files.
- `-NonInteractive` disables prompts and lets errors fail fast.
- `-ForceRecreateVenv` removes and rebuilds `.venv`.
- `-DigiCertUtilityExe` points at `DigiCertUtil.exe` when it is not installed at the default path.
- Python auto-install is enabled by default when no compatible interpreter exists.
- `-SkipPythonInstall` disables the python.org installer fallback.
- `-AllowPythonInstall` is retained for older command lines and explicitly keeps the fallback enabled.
- `-UnblockScripts` explicitly removes PowerShell download-block metadata from this toolkit.
- `-ContinueOnPrecheckFailure` allows setup to continue past non-critical precheck issues.

## pyproject templates

Use the templates when starting a new project or switching package managers:

```powershell
Copy-Item .\templates\pyproject.uv.toml .\pyproject.toml
Copy-Item .\templates\pyproject.poetry.toml .\pyproject.toml
Remove-Item .setup-config.json -ErrorAction SilentlyContinue
.\scripts4PythonAutomation\setup-core.ps1 -PackageManager auto -DryRun
```

The uv template uses `[project]` plus `[tool.uv]` and no Poetry sections. The Poetry template uses `[tool.poetry]` plus `poetry.core.masonry.api` and no uv sections. That keeps auto-detection deterministic.

## How the pipeline works

The setup flow is organized as a fixed pipeline inside `Start-Setup`.

1. Require a Windows host.
2. Detect the package manager from CLI overrides, cached config, `pyproject.toml`, or lock files.
3. Run prechecks.
4. Parse project metadata from `pyproject.toml`.
5. Resolve a compatible Python interpreter.
6. Ensure the package manager runtime exists.
7. Configure package manager defaults.
8. Create or refresh `.venv`.
9. Validate the virtual environment and copy runtime assets as needed.
10. Sync the lock file or re-resolve dependencies.
11. Install dependencies.
12. Write project wiring such as `.pth` and VS Code settings.
13. Copy Tcl runtime files when present.
14. Code-sign executables and clean up backups.

The flowchart document in [scripts4PythonAutomation/Flow.md](scripts4PythonAutomation/Flow.md) contains a more detailed Mermaid version of the same process.

## Typical workflow

For a normal setup:

1. Run `.\scripts4PythonAutomation\setup-core.ps1`.
2. If prompted, choose the default install mode or upgrade mode.
3. After the script completes, dot-source `activate-venv.ps1` if the environment was not already activated in your shell.
4. Use the generated `.venv` for the rest of your work.

If you want a clean rebuild, use `-ForceRecreateVenv`. If you want to see what would happen without modifying anything, use `-DryRun`; dry-run still requires Windows, then reports required precheck failures while continuing to print the remaining plan.

## Project metadata

The repository is configured as a Python project named `pythonAutomation` in [pyproject.toml](pyproject.toml). It currently depends on:

- `requests`
- `rich`

Development dependencies include:

- `pytest`
- `pytest-cov`
- `ruff`

## Troubleshooting

- If the setup script is launched from the VS Code integrated terminal, it detaches into a plain PowerShell subprocess to avoid opening every module file in the editor.
- If setup says it is Windows-only, run it from Windows PowerShell or `pwsh` on Windows.
- If activation does not affect the current shell, make sure you used the dot-sourced form: `. .\scripts4PythonAutomation\activate-venv.ps1`.
- If DigiCert is missing, install DigiCert Utility or pass `-DigiCertUtilityExe` with the correct path. Setup aborts before making changes.
- If PowerShell reports blocked scripts, run `.\scripts4PythonAutomation\setup-core.ps1 -UnblockScripts -DryRun`, then rerun setup normally.
- If the environment is corrupted, use `-ForceRecreateVenv` to rebuild it cleanly.

## Reference

For a full command-by-command reference, run:

```powershell
.\scripts4PythonAutomation\Get-SetupHelp.ps1
```

Or read the full pipeline diagrams in [scripts4PythonAutomation/Flow.md](scripts4PythonAutomation/Flow.md).
