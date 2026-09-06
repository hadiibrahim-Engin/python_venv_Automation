# Migration Guide

This guide covers the behavior changes introduced by the Phase 1-3 refactoring.

## Git synchronization

Setup now performs a conservative Git synchronization before the environment pipeline unless disabled.

Default behavior:

```json
{
  "AutoGitPull": true,
  "GitPullStrategy": "SkipIfDirty"
}
```

A clean branch that is behind its upstream is updated with `git pull --ff-only`. Dirty or diverged repositories are not merged automatically.

To disable Git synchronization for one run:

```powershell
devsetup -- -SkipGitPull
```

A destructive reset is possible only through the explicit CLI switch:

```powershell
devsetup -- -ForceGitPull -Confirm
```

`ForceGitPull` cannot be enabled through project configuration.

## Code signing

Signing is now idempotent. Existing valid Authenticode signatures are preserved.

Old behavior:

```text
Every update -> sign every discovered EXE/DLL again
```

New behavior:

```text
Discover EXE/DLL
   -> inspect Authenticode
   -> Valid: skip
   -> unsigned/changed/invalid: sign
```

`update-venv` performs the same intelligent scan after dependency changes, so newly installed executables are signed without re-signing already valid files.

## DigiCert path

The DigiCert path is validated at setup initialization. Resolution order is:

1. explicit `-DigiCertUtilityExe`
2. environment variable `DIGICERT_UTILITY_EXE`
3. built-in default path

If the resolved executable does not exist, setup stops with:

```text
DigiCert Utility not found. Please install or set environment variable.
```

There is no silent fallback after a missing path is detected.

## Configuration persistence

Config write failures no longer warn and continue silently.

- interactive run: user is asked whether to continue without persistence
- non-interactive/CI run: setup throws and the pipeline fails

## Logging

Each run now receives a correlation ID and writes structured NDJSON events to:

```text
%TEMP%\python-setup-log.json
```

Supported levels:

```text
DEBUG
INFO
WARN
ERROR
```

Configure project default:

```json
{
  "LogLevel": "INFO"
}
```

or override from the CLI:

```powershell
devsetup -- -LogLevel DEBUG
```

## Setup architecture

The previous monolithic `Start-Setup` body has been split into named actions in `SetupSteps.psm1` and is executed through `SetupPipeline.psm1`.

The public interfaces remain:

```text
devsetup
Invoke-PythonVenvSetup
scripts4PythonAutomation\setup-core.ps1
```

## Tests

Run the complete Pester suite locally with:

```powershell
.\Run-Tests.ps1
```

The default minimum coverage target is 70% for the configured core paths.
