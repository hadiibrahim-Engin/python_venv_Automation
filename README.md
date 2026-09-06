# python_venv_Automation

Windows-focused PowerShell automation for creating, updating, validating, signing, and activating Python virtual environments. The toolkit supports **uv** and **Poetry**, discovers compatible Python interpreters, integrates DigiCert Authenticode signing, and is designed to be safe and repeatable for developer workstations and CI/CD.

The distributable module is `PythonVenvAutomation`; the recommended global command is `devsetup`. The legacy entry point `scripts4PythonAutomation\setup-core.ps1` remains available for backward compatibility.

## Quick start

```powershell
devsetup
devsetup update
devsetup upgrade
devsetup rebuild
devsetup dry
```

Advanced parameters are forwarded after `--`:

```powershell
devsetup -- -PackageManager uv -NonInteractive
devsetup update -- -UpgradePackage requests
devsetup -- -SkipGitPull
devsetup -- -LogLevel DEBUG
```

## Requirements

- Windows
- Windows PowerShell 5.1+ or `pwsh`
- a supported Python declared by the project (the templates currently target Python 3.11/3.12)
- DigiCert Utility for real setup/signing runs
- `pyproject.toml` or another supported dependency declaration

DigiCert is resolved in this order:

1. `-DigiCertUtilityExe`
2. `DIGICERT_UTILITY_EXE`
3. the centrally defined default installation path

If the resolved executable does not exist, setup fails before mutating project state with:

```text
DigiCert Utility not found. Please install or set environment variable.
```

## Safe Git synchronization

Before environment setup, `Invoke-PythonVenvSetup` can safely synchronize the project repository.

Default project configuration:

```json
{
  "AutoGitPull": true,
  "GitPullStrategy": "SkipIfDirty"
}
```

The safety model is intentionally conservative:

- remote state is refreshed with bounded `git fetch --prune`;
- clean branches that are only behind use `git pull --ff-only`;
- dirty repositories are skipped by default;
- diverged branches are never auto-merged or auto-rebased;
- `git clean` is never run automatically;
- destructive reset is possible only with explicit `-ForceGitPull`;
- Git mutation supports PowerShell `-WhatIf` / `-Confirm`.

Detailed design: [Safe Git Synchronization](PythonVenvAutomation/docs/SAFE_GIT_SYNC.md).

## Intelligent DigiCert signing

Signing is **idempotent**. Every candidate executable/DLL is inspected with `Get-AuthenticodeSignature` before DigiCert is invoked.

```text
Valid signature              -> skip
NotSigned                    -> sign
HashMismatch / changed file  -> sign again
Invalid signature            -> sign again
```

A normal update therefore does **not** re-sign every file in an existing `.venv`. Only new, changed, unsigned, or invalid binaries are sent to DigiCert. Existing valid vendor signatures are preserved.

`devsetup update` also performs this intelligent signing scan after dependencies are refreshed, so newly installed command-line executables are signed without touching already valid files.

Detailed design: [Intelligent DigiCert Signing](PythonVenvAutomation/docs/SMART_CODE_SIGNING.md).

## Refactored setup architecture

`Start-Setup` is no longer a single large orchestration function. The active architecture consists of:

```text
Start-Setup
   |
   +-- build setup context
   +-- build named pipeline steps
   |
   v
SetupPipeline.psm1
   |
   +-- PRECHECK
   +-- METADATA
   +-- PYTHON
   +-- PM-RUNTIME
   +-- PM-SIGN
   +-- PM-CONFIG
   +-- VENV-PREPARE
   +-- VENV-VALIDATE
   +-- LOCK
   +-- DEPENDENCIES
   +-- PROJECT-PTH / VSCODE / TCL
   +-- SMART-SIGNING
   +-- CLEANUP
```

Named actions live in `SetupSteps.psm1`. Pipeline timing, dry-run behavior, optional/mandatory failures, and conversion to structured errors are handled centrally by `SetupPipeline.psm1`.

Architecture details: [Phase 2 Architecture](PythonVenvAutomation/docs/PHASE2_ARCHITECTURE.md).

## Structured errors

Pipeline failures are normalized to `SetupException`, which contains:

```text
Message
ErrorCode
Step
Context
```

This makes console errors and CI failures attributable to a concrete setup stage instead of relying on generic `throw` text alone.

Representative error codes include:

```text
DIGICERT_NOT_FOUND
PRECHECK_FAILED
PM_DETECTION_FAILED
PYTHON_RESOLUTION_FAILED
PM_RUNTIME_FAILED
VENV_PREPARE_FAILED
DEPENDENCY_INSTALL_FAILED
VENV_SIGNING_FAILED
VENV_UPDATE_FAILED
```

## Structured logging

Every run receives a GUID correlation ID. Structured events are written as newline-delimited JSON to:

```text
%TEMP%\python-setup-log.json
```

Stable fields:

```text
Timestamp
Level
Step
Message
CorrelationId
Module      (when available)
Context     (when available)
```

Supported levels are `DEBUG`, `INFO`, `WARN`, and `ERROR`.

Example project config:

```json
{
  "LogLevel": "INFO"
}
```

CLI override:

```powershell
devsetup -- -LogLevel DEBUG
```

## Configuration reference

Project-local defaults live in `.setup-config.json`. A complete example is committed as [.setup-config.example.json](.setup-config.example.json).

Supported project keys:

| Key | Type | Default | Purpose |
| --- | --- | --- | --- |
| `AutoGitPull` | boolean | `true` | Run safe Git synchronization before setup. |
| `GitPullStrategy` | string | `SkipIfDirty` | `SkipIfDirty` or `ErrorIfDirty`. |
| `LogLevel` | string | `INFO` | `DEBUG`, `INFO`, `WARN`, `ERROR`. |
| `PackageManager` | string | `auto` | `auto`, `uv`, or `poetry`. |
| `PinnedPoetryVersion` | string | empty | Optional Poetry runtime pin. |
| `PinnedUvVersion` | string | empty | Optional uv runtime pin. |

Machine-specific DigiCert paths and destructive Git force behavior are intentionally not stored in project configuration.

Detailed reference: [Configuration Reference](PythonVenvAutomation/docs/CONFIGURATION_REFERENCE.md).

## Config write failures

Configuration persistence is fail-safe:

- **interactive:** the user is explicitly asked whether setup may continue without saving;
- **non-interactive / CI:** the write error is thrown and the pipeline fails.

The tool no longer logs a config write error and silently continues in CI.

## PowerShell `ShouldProcess`

Mutating setup operations implement or are routed through functions implementing `SupportsShouldProcess`, including Git synchronization, configuration writes, signing, venv creation/removal/backup/restore, filesystem cleanup, project `.pth` writes, VS Code configuration, dependency updates, and setup pipeline actions.

Preview a setup without mutation:

```powershell
Invoke-PythonVenvSetup -WhatIf
```

or:

```powershell
devsetup dry
```

Explicit destructive operations can be paired with `-Confirm`.

## Update mode

Use update mode when `.venv` already exists:

```powershell
devsetup update
```

The update path:

1. validates the existing environment;
2. detects the dependency system;
3. refreshes dependencies with uv, Poetry, or pip;
4. persists `.venv\Scripts` on PATH;
5. scans Authenticode state;
6. signs only new/changed/invalid binaries.

It does not reinstall the package-manager runtime or blindly recreate the environment.

## Testing

Run the complete test suite locally:

```powershell
.\Run-Tests.ps1
```

The runner requires Pester 5+, produces NUnit and JaCoCo output, and enforces a **70% coverage gate on the refactored core logic**.

Core test areas include:

- safe Git synchronization;
- configuration persistence failures;
- uv/Poetry package-manager detection;
- intelligent code signing;
- setup pipeline ordering/error behavior;
- structured logging;
- PowerShell syntax parsing;
- existing module/shim/build compatibility tests.

GitHub Actions and Azure Pipelines both execute the Windows Pester/coverage validation before build/publish stages.

## Repository layout

```text
PythonVenvAutomation/
├─ Public/
├─ Private/
├─ config/
├─ templates/
└─ docs/

scripts4PythonAutomation/
├─ Setup-Core.psm1
├─ setup-core.ps1
└─ SetupCore/modules/
   ├─ Constants.psm1
   ├─ Errors.psm1
   ├─ Logging.psm1
   ├─ GitSync.psm1
   ├─ SetupPipeline.psm1
   ├─ SetupSteps.psm1
   ├─ CodeSigning.psm1
   ├─ Config.psm1
   └─ ...

tests/
Run-Tests.ps1
azure-pipelines.yml
.github/workflows/publish.yml
```

## Installation and backward compatibility

The module is still designed to be installed at user scope; no administrator rights are required for the command shim itself. Existing script calls remain supported:

```powershell
.\scripts4PythonAutomation\setup-core.ps1
.\scripts4PythonAutomation\setup-core.ps1 -DryRun
.\scripts4PythonAutomation\setup-core.ps1 -Mode update-venv
.\scripts4PythonAutomation\setup-core.ps1 -ForceRecreateVenv
```

Programmatic entry point:

```powershell
Import-Module PythonVenvAutomation
Invoke-PythonVenvSetup
```

## Versioning and publishing

`VERSION` remains the module version source of truth. `build\Update-Version.ps1` keeps the module manifest aligned, and the build validates that they match.

Version tags (`v1.2.3`) are used for release publishing. GitHub Actions and Azure Pipelines separate validation, build, and publish stages; credentials are supplied through secret variables rather than committed configuration.

## Documentation

- [Documentation index](PythonVenvAutomation/docs/README.md)
- [Safe Git Synchronization](PythonVenvAutomation/docs/SAFE_GIT_SYNC.md)
- [Intelligent DigiCert Signing](PythonVenvAutomation/docs/SMART_CODE_SIGNING.md)
- [Phase 2 Architecture](PythonVenvAutomation/docs/PHASE2_ARCHITECTURE.md)
- [Configuration Reference](PythonVenvAutomation/docs/CONFIGURATION_REFERENCE.md)
- [Security Model and Troubleshooting](PythonVenvAutomation/docs/SECURITY_AND_TROUBLESHOOTING.md)
- [Migration Guide](PythonVenvAutomation/docs/MIGRATION_GUIDE.md)
- [Detailed setup flow](scripts4PythonAutomation/Flow.md)

## Troubleshooting

Start with [Security Model and Troubleshooting](PythonVenvAutomation/docs/SECURITY_AND_TROUBLESHOOTING.md). Common cases:

- `DIGICERT_NOT_FOUND`: install DigiCert Utility or set `DIGICERT_UTILITY_EXE`;
- Git `SkippedDirty`: commit/stash local changes or explicitly skip Git sync;
- Git `Diverged`: resolve the branch manually; automation intentionally does not merge;
- config persistence failure: check filesystem permissions/disk space;
- update-mode signing appears active: the scan is expected, but valid binaries are skipped and only `NewlySigned` targets reach DigiCert.
