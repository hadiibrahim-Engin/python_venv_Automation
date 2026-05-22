# python_venv_Automation

PowerShell automation for creating, repairing, and activating a Python virtual environment from a project root. The toolkit supports both `uv` and Poetry, can discover or validate a local Python interpreter, optionally signs executables with DigiCert, and is designed to be safe to run repeatedly.

## What this project does

This repository provides an end-to-end setup pipeline for Python projects that need a pinned `.venv`, consistent dependency installation, and optional editor integration.

At a high level it can:

- detect the package manager from project metadata or lock files
- find or validate a compatible Python interpreter
- create or rebuild `.venv`
- install dependencies from the lock file or re-resolve them
- write local project wiring such as `.pth` and VS Code settings
- optionally copy Tcl runtime files and sign binaries
- activate the environment in the current shell after setup

## Main files

- [scripts4PythonAutomation/setup-core.ps1](scripts4PythonAutomation/setup-core.ps1) is the main entry point.
- [scripts4PythonAutomation/Setup-Core.psm1](scripts4PythonAutomation/Setup-Core.psm1) loads the modular pipeline and exposes `Start-Setup`.
- [scripts4PythonAutomation/activate-venv.ps1](scripts4PythonAutomation/activate-venv.ps1) activates the created virtual environment and must be dot-sourced.
- [scripts4PythonAutomation/Get-SetupHelp.ps1](scripts4PythonAutomation/Get-SetupHelp.ps1) prints the full command reference.
- [AUTOMATION_FLOWCHARTS.md](AUTOMATION_FLOWCHARTS.md) shows the setup flow with Mermaid diagrams.
- [pyproject.toml](pyproject.toml) contains the project metadata and dependency constraints used by the setup logic.

## Requirements

- PowerShell 5.1 or newer, or `pwsh`
- Python `>=3.11` and `<3.13`
- A project root that contains `pyproject.toml`

The project currently signals `uv` as the preferred package manager through `pyproject.toml`, but the tooling can also work with Poetry when that is the right choice for the repository.

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
```

If PowerShell blocks execution the first time, run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts4PythonAutomation\setup-core.ps1
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
- `-ContinueOnPrecheckFailure` allows setup to continue past non-critical precheck issues.

## How the pipeline works

The setup flow is organized as a fixed pipeline inside `Start-Setup`.

1. Detect the package manager from CLI overrides, cached config, `pyproject.toml`, or lock files.
2. Run prechecks.
3. Parse project metadata from `pyproject.toml`.
4. Resolve a compatible Python interpreter.
5. Ensure the package manager runtime exists.
6. Configure package manager defaults.
7. Create or refresh `.venv`.
8. Validate the virtual environment and copy runtime assets as needed.
9. Sync the lock file or re-resolve dependencies.
10. Install dependencies.
11. Write project wiring such as `.pth` and VS Code settings.
12. Copy Tcl runtime files when enabled.
13. Optionally code-sign executables and clean up backups.

The flowchart document in [AUTOMATION_FLOWCHARTS.md](AUTOMATION_FLOWCHARTS.md) contains a more detailed Mermaid version of the same process.

## Typical workflow

For a normal setup:

1. Run `.\scripts4PythonAutomation\setup-core.ps1`.
2. If prompted, choose the default install mode or upgrade mode.
3. After the script completes, dot-source `activate-venv.ps1` if the environment was not already activated in your shell.
4. Use the generated `.venv` for the rest of your work.

If you want a clean rebuild, use `-ForceRecreateVenv`. If you want to see what would happen without modifying anything, use `-DryRun`.

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
- If activation does not affect the current shell, make sure you used the dot-sourced form: `. .\scripts4PythonAutomation\activate-venv.ps1`.
- If PowerShell reports blocked scripts, rerun the setup command with `-ExecutionPolicy Bypass` once.
- If the environment is corrupted, use `-ForceRecreateVenv` to rebuild it cleanly.

## Reference

For a full command-by-command reference, run:

```powershell
.\scripts4PythonAutomation\Get-SetupHelp.ps1
```

Or read the full pipeline diagrams in [AUTOMATION_FLOWCHARTS.md](AUTOMATION_FLOWCHARTS.md).