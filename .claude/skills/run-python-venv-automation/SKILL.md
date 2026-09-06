---
name: run-python-venv-automation
description: Run, build, test, and drive the PythonVenvAutomation / devsetup PowerShell automation. Use when asked to run devsetup, start or execute the setup pipeline, run the Pester tests, check package-manager detection, build the module package, or verify a change works in the real app rather than only in tests.
---

# Run PythonVenvAutomation (devsetup)

Windows-targeted PowerShell automation that creates, repairs, signs and activates
Python virtual environments, exposed to end users as a single `devsetup` command.

It is **driven programmatically** by `.claude/skills/run-python-venv-automation/driver.ps1`.
There is no GUI. All paths below are relative to the repo root.

**It runs on macOS/Linux far further than the README implies** — the "Windows-only"
guard is a single `$env:OS` check, and the driver flips it. See
[Platform ceiling](#platform-ceiling) for exactly where it stops.

## Prerequisites

Verified on macOS 25.6 (arm64), PowerShell 7.5.5, Pester 5.7.1.

```bash
pwsh -v            # PowerShell 7+ (or Windows PowerShell 5.1)
```

If Pester is missing or older than 5:

```bash
pwsh -NoProfile -Command "Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck"
```

No Python, `uv` or `poetry` is required for anything in this skill — the dry-run
pipeline never shells out to them.

## Run (agent path) — use this first

Everything goes through one driver. It takes a verb as its first positional arg.

```bash
pwsh -NoProfile -File .claude/skills/run-python-venv-automation/driver.ps1 selftest
```

That is the one-shot "is this repo healthy" check. Expected output:

```
==> Self-test: engine import + syntax + detection + pipeline
  [ok] engine imported, all required functions resolvable
  [ok] all PowerShell files parse
  [ok] detection returns poetry for a poetry project
  [ok] dry-run pipeline reaches VENV-VALIDATE (10 steps)
SELF-TEST PASSED
```

### Verbs

| Command | What it does |
|---|---|
| `selftest` | Engine import + syntax parse of every `.ps1`/`.psm1` + detection + a full dry-run pipeline. Start here. |
| `test` | Pester suite + 70% coverage gate. Add `-SkipSigningTests` off Windows. |
| `info` | `Get-PythonVenvSetupInfo` — command name, shim paths, engine path, auto-update config. |
| `detect` | `Resolve-PackageManager` across four generated pyproject fixtures. |
| `pipeline` | Runs the real `Invoke-PythonVenvSetup` orchestration. `-WhatIf` by default; `-Real` to actually mutate. |
| `fixtures` | Writes the fixture projects and exits. |
| `exec` | Evaluates `-Script <snippet>` or `-File <path.ps1>` with the whole engine loaded. **This is the direct-invocation path** — use it to call any internal function. |

Useful flags: `-ProjectPath <dir>` (`detect`, `pipeline`), `-WorkDir <dir>`
(where fixtures land, default `$TMPDIR/devsetup-driver`), `-Real`, `-NoCoverage`.

### How the driver gets the engine loaded

```mermaid
flowchart TD
    A[driver.ps1 verb] --> B[Import-DevSetupEngine]
    B --> C[Pass 1: Import PythonVenvAutomation.psd1<br/>chains to Setup-Core.psm1]
    C --> D{Constants, Toml, Errors ...<br/>still global?}
    D -->|No — de-globalized by nested<br/>-Force imports| E[Pass 2: re-import all 24 SetupCore<br/>modules with -Global, REVERSE order]
    D -->|Yes| F[Assert required functions resolve]
    E --> F
    F -->|missing| G[throw: Engine import incomplete]
    F -->|ok| H[Enable-WindowsHostSpoof<br/>set $env:OS = Windows_NT]
    H --> I[Run the verb]
```

Reverse order matters: leaf modules (`Constants`, `Errors`, `Logging`, …) must be
imported **last** so they land in the global session state instead of inside a
dependent module. See [Gotchas](#gotchas).

### Direct invocation (most PRs need only this)

Call any internal function with the engine live:

```bash
pwsh -NoProfile -File .claude/skills/run-python-venv-automation/driver.ps1 exec -Script '
$c = Get-SetupConstants
"ConfigFileName     : " + $c.ConfigFileName
"DefaultPullStrategy: " + $c.Git.DefaultPullStrategy
"Get-VenvPythonExe  : " + (Get-VenvPythonExe -VenvDir "/tmp/x/.venv")
'
```

Verified output:

```
ConfigFileName     : .setup-config.json
DefaultPullStrategy: SkipIfDirty
Get-VenvPythonExe  : /tmp/x/.venv/Scripts/python.exe
```

### The setup pipeline

```bash
pwsh -NoProfile -File .claude/skills/run-python-venv-automation/driver.ps1 pipeline
```

```mermaid
flowchart TD
    INIT[INIT · Core] --> DETECT[DETECT · Detection]
    DETECT --> PRECHECK[PRECHECK · Prechecks]
    PRECHECK --> METADATA[METADATA · Toml]
    METADATA --> PYTHON[PYTHON · PythonDiscovery]
    PYTHON --> PMRT[PM-RUNTIME · PackageManager]
    PMRT --> PMSIGN[PM-SIGN · CodeSigning]
    PMSIGN --> PMCFG[PM-CONFIG · PackageManager]
    PMCFG --> PMCLEAN[PM-CLEAN · PackageManager]
    PMCLEAN --> VPREP[VENV-PREPARE · Venv]
    VPREP --> VVAL[VENV-VALIDATE · Venv]

    INIT -.->|non-Windows host| X1[PLATFORM_UNSUPPORTED<br/>driver spoofs past this]
    PYTHON -.->|-Real off Windows| X2[PYTHON_RESOLUTION_FAILED<br/>drive 'C' does not exist]
    VVAL -.->|-WhatIf| X3[VENV_INVALID<br/>expected: dry run skips VENV-PREPARE]

    style X1 stroke-dasharray: 4 4
    style X2 stroke-dasharray: 4 4
    style X3 stroke-dasharray: 4 4
```

A dry run **ends in a `VENV_INVALID` failure and that is the expected result** —
`-WhatIf` skips `VENV-PREPARE`, so `VENV-VALIDATE` finds no `.venv`. Reaching
that step means all 10 steps executed. The step is not dry-run aware; treat a
run that stops *earlier* as the real regression signal.

### Platform ceiling

| Mode | Reaches | Stops because |
|---|---|---|
| `pipeline` (dry run) | all 10 steps → `VENV-VALIDATE` | `-WhatIf` skipped venv creation (expected) |
| `pipeline -Real` | 3 steps → dies in `PYTHON` | `PythonDiscovery` enumerates `C:\` — "A drive with the name 'C' does not exist" |

`DETECT`, `PRECHECK` and `METADATA` execute for real in both modes, so
detection, precheck and TOML-parsing changes are fully testable here. Anything
touching `PythonDiscovery`, `Venv`, or `CodeSigning` needs a Windows host or CI.

## Test

```bash
pwsh -NoProfile -File .claude/skills/run-python-venv-automation/driver.ps1 test -SkipSigningTests
```

Verified: `Passed=159 Failed=0 Skipped=0`, `Coverage: 73,93%` (gate is 70%).

The project's own runner works too and is what CI calls, but it fails off Windows:

```bash
pwsh -NoProfile -File ./Run-Tests.ps1 -MinimumCoverage 70
```

→ `Pester failed: tests=5, containers=0, blocks=0` — the 5 `CodeSigning.Tests.ps1`
cases. Everything else (159 tests) and the coverage gate pass. Use
`driver.ps1 test -SkipSigningTests` locally and let CI (`windows-latest`) run the
full suite.

## Build

```bash
pwsh -NoProfile -File ./build/Build.ps1
```

Works on macOS. Verified output:

```
Version check OK: 1.0.0
Staged manifest validated.
Wrote .../artifacts/PythonVenvAutomation-1.0.0.zip
Wrote .../artifacts/nuget/PythonVenvAutomation.1.0.0.nupkg
```

`artifacts/` and `PythonVenvAutomation/engine/` are gitignored. The version in
`VERSION` and in `PythonVenvAutomation.psd1` must match or the build fails —
`build/Update-Version.ps1` keeps them in sync.

## Run (human path)

End users never touch any of the above. They run `Install-DevSetupCommand` once,
which writes a `devsetup.cmd`/`devsetup.ps1` shim into
`%LOCALAPPDATA%\Company\PythonVenvAutomation\bin` and puts it on the user PATH;
afterwards they only type `devsetup`. This is Windows-only and interactive —
`Invoke-PythonVenvSetup` without `-NonInteractive` prompts with a
`Read-Host` mode menu, so never call it that way from an agent.

Reference docs: `scripts4PythonAutomation/Flow.md` (mermaid flowcharts of the
whole engine), `PythonVenvAutomation/docs/`, and
`pwsh -NoProfile -File ./scripts4PythonAutomation/Get-SetupHelp.ps1`.

## Gotchas

- **Importing the engine the obvious way silently half-loads it.** `Import-Module
  Setup-Core.psm1` leaves only 11 of 24 modules global. `Get-SetupConstants`,
  `Get-ProjectMetadata`, `New-SetupException` are all missing, and the pipeline
  dies at `METADATA` with *"The term 'Get-ProjectMetadata' is not recognized"*.
  Cause: 14 SetupCore modules re-import their dependencies with `-Force` but
  **without `-Global`** (e.g. `Filesystem.psm1:10` → `Constants.psm1`). `-Force`
  *relocates* an already-global module into the importer's private session state.
  `Filesystem` is where it first breaks. Always load via
  `Import-DevSetupEngine` in the driver, never a bare `Import-Module`.

- **The "Windows-only" guard is one env var.** `Setup-Core.psm1:245` throws
  `PLATFORM_UNSUPPORTED` unless `Get-IsWindows` is true, and `Compat.psm1:83`
  defines that as `$env:OS -eq 'Windows_NT'`. Setting `$env:OS='Windows_NT'` is
  enough — no source patch. The driver does this in `Enable-WindowsHostSpoof`.

- **INIT requires an existing DigiCert executable path** even with
  `-EnableCodeSigning:$false` — the check runs before the flag is consulted.
  Without it: `DIGICERT_NOT_FOUND`. The driver passes an empty stub file.

- **`Get-VenvPythonExe` always returns `Scripts\python.exe`**, hardcoded for
  Windows, so anything that resolves a venv interpreter cannot work off Windows
  regardless of the spoof.

- **`Invoke-PythonVenvSetup` prompts** unless `-NonInteractive` is passed. It also
  runs a git pull by default — pass `-SkipGitPull` for scratch projects.

- **Running tests dirties the repo.** `Run-Tests.ps1` writes `test-results.xml`
  and `coverage.xml` to the repo root and neither is in `.gitignore`. Since the
  automation's own git sync defaults to `SkipIfDirty`, this can silently change
  behaviour on a later run. Delete them or add them to `.gitignore`.

- **Detection currently treats bare `[project]` as uv.** `driver.ps1 detect`
  shows it: a PEP 621-only pyproject and a project with *both* `uv.lock` and
  `poetry.lock` both resolve to `uv` with reason *"[project] table (PEP 621)
  present, no [tool.poetry]"*. PEP 621 is tool-neutral, so this is a known
  correctness gap, not driver noise — use `detect` to verify any fix.

- **CI is `windows-latest` only** (`.github/workflows/publish.yml`). Treat green
  local runs as a smoke check; the Windows-only paths are only genuinely
  validated there.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `The term 'Get-SetupConstants' is not recognized` | You imported the module directly. Use `driver.ps1 exec` / `Import-DevSetupEngine`. |
| `The term 'Get-ProjectMetadata' is not recognized` at step `METADATA` | Same cause — the reverse-order second pass did not run. |
| `This setup automation is Windows-only.` (`PLATFORM_UNSUPPORTED`) | Set `$env:OS='Windows_NT'`; the driver does it for you. |
| `DigiCert Utility not found` (`DIGICERT_NOT_FOUND`) | Pass `-DigiCertUtilityExe <path to any existing file>`; the driver uses a stub. |
| `Cannot find drive. A drive with the name 'C' does not exist.` | You used `pipeline -Real` off Windows. Expected — drop `-Real`. |
| `.venv directory was not created` (`VENV_INVALID`) after 10 steps | Expected outcome of a dry run. Not a failure. |
| `Could not find Command Get-AuthenticodeSignature` (×5) | `CodeSigning.Tests.ps1` off Windows. Use `test -SkipSigningTests`. |
| `Pester 5 or newer is required` | `Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck` |
