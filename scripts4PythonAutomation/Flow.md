# Python Venv Automation Flowcharts

This document reflects the current `setup-core.ps1` / `Start-Setup` process.
The automation is Windows-only: `Start-Setup` aborts immediately on any
non-Windows host before detection, prechecks, or filesystem mutation.
DigiCert Utility is required infrastructure: on Windows, a real setup run
aborts at prechecks if DigiCert is missing. Dry-run mode reports that abort
condition and continues printing the remaining plan without mutating files.

## Operator Flow

```mermaid
flowchart TD
    A[Start setup-core.ps1] --> B[Normalize CLI args]
    B --> B1[Parse boolean args: true/false, 1/0, yes/no, on/off]
    B1 --> C{Running inside VS Code host?}
    C -->|Yes| C1[Forward args to detached pwsh/powershell subprocess]
    C1 --> C2{Child succeeded and not DryRun?}
    C2 -->|Yes| C3[Try to activate .venv in parent shell]
    C2 -->|No| C4[Return child exit code]
    C -->|No| D{UnblockScripts?}
    D -->|Yes| D1[Explicitly unblock toolkit ps1/psm1/psd1 files]
    D -->|No| E[Import Setup-Core.psm1]
    D1 --> E
    E --> F[Start-Setup]

    F --> F1{Windows host?}
    F1 -->|No| F2[Abort: Windows-only automation]
    F1 -->|Yes| G[Build setup context]
    G --> H[DETECT: Resolve package manager]
    H --> I[0/13 Prechecks]
    I --> J{Critical precheck failure?}
    J -->|Yes, real run| J1[Abort before mutation]
    J -->|Yes, DryRun| J2[Mark real setup would abort]
    J -->|No| K[Continue]
    J2 --> K

    K --> L{Python mode already known?}
    L -->|Explicit PythonExePath| M[Validate explicit interpreter]
    L -->|ListMode| N[Show all interpreters and enforce constraint]
    L -->|No mode and interactive| O[Prompt: auto, list, or explicit path]
    L -->|No mode and NonInteractive/DryRun| P[Auto-discover compatible Python]
    O --> M
    O --> N
    O --> P
    M --> Q[Resolve compatible Python]
    N --> Q
    P --> Q

    Q --> R[Run remaining setup pipeline]
    R --> S{DryRun?}
    S -->|Yes| S1[Skip every mutating step and print plan]
    S -->|No| T[Create/reuse .venv, install deps, write settings, sign executables]
    S1 --> U[Done: dry-run completed]
    T --> V[Best-effort activation]
    V --> W[Return summary object]
```

## Detailed Pipeline

```mermaid
flowchart TD
    A[setup-core.ps1] --> A1[Capture CLI values]
    A1 --> A2[Resolve NonInteractive: explicit, DryRun, or CI=true]
    A2 --> A3[Resolve bool-like options]
    A3 --> A4{VS Code integrated host?}
    A4 -->|Yes| A5[Start detached subprocess with forwarded args]
    A4 -->|No| A6{UnblockScripts?}
    A6 -->|Yes| A7[Unblock toolkit files only]
    A6 -->|No| A8[Import root module]
    A7 --> A8
    A8 --> B[Start-Setup]

    B --> B0{Windows host?}
    B0 -->|No| B00[Throw: Windows-only automation]
    B0 -->|Yes| B1[Clear VIRTUAL_ENV, POETRY_ACTIVE, CONDA_PREFIX]
    B1 --> B2[Build mutable context]
    B2 --> C[DETECT: Invoke-PmDetection]

    C --> C1[Merge .setup-config.json pinned tool versions]
    C1 --> C2{PackageManager source}
    C2 -->|CLI uv/poetry| C3[Use explicit CLI package manager]
    C2 -->|Config PackageManager| C4[Use pinned config manager]
    C2 -->|pyproject signal| C5[Detect from backend, tool sections, project table]
    C2 -->|lock files| C6[Use uv.lock or poetry.lock tiebreaker]
    C2 -->|no signal| C7[Default to poetry]
    C3 --> D[0/13 Prechecks]
    C4 --> D
    C5 --> D
    C6 --> D
    C7 --> D

    D --> D1[Network diagnostic]
    D1 --> D2[DigiCert Utility availability check]
    D2 --> D3{Any failure?}
    D3 -->|Only non-critical| D4[Apply autofix and continue]
    D3 -->|Critical + DryRun| D5[Record PrechecksWouldAbort and continue plan]
    D3 -->|Critical + real run| D6[Throw: critical prechecks failed]
    D3 -->|None| E[1/13 Parse pyproject.toml]
    D4 --> E
    D5 --> E

    E --> E1[Read project name and requires-python]
    E1 --> E2[Parse version constraints]
    E2 --> F[2/13 Resolve Python]

    F --> F1{Selection mode}
    F1 -->|ListMode| F2[Find all interpreters and prompt for compatible choice]
    F1 -->|Explicit path| F3[Normalize, start, parse version, enforce constraints]
    F1 -->|Auto| F4[Discover compatible interpreters outside .venv]
    F4 --> F5{Compatible Python found?}
    F5 -->|Yes| F6[Select lowest compatible version]
    F5 -->|No + AllowPythonInstall| F7[Verified python.org installer path]
    F5 -->|No + no AllowPythonInstall| F8[Throw actionable install/path message]
    F2 --> G[Configure signing defaults if signing enabled and not DryRun]
    F3 --> G
    F6 --> G
    F7 --> G

    G --> H[3/13 Ensure package-manager runtime]
    H --> H1{PackageManager}
    H1 -->|uv| H2[Find or install uv via selected Python pip]
    H1 -->|poetry| H3[Find or install Poetry]
    H2 --> I[3a/13 Sign PM executable if signing enabled and shim exists]
    H3 --> I
    I --> J[4/13 Configure PM defaults]
    J --> J1[Poetry: local virtualenvs.in-project config]
    J --> J2[uv: no-op]
    J1 --> K[5a/13 Clean stale PM env associations]
    J2 --> K

    K --> L{ForceRecreateVenv?}
    L -->|Yes| L1[5b/13 Backup .venv then remove old .venv]
    L -->|No| M[5c/13 Prepare .venv]
    L1 --> M
    M --> M1{Existing .venv?}
    M1 -->|No| M2[Create venv with selected Python]
    M1 -->|Yes| M3[Validate existing venv Python compatibility]
    M2 --> N[6/13 Validate .venv structure]
    M3 --> N

    N --> O[7/13 Copy Python runtime DLL if present]
    O --> P{UpdateDependencies?}
    P -->|No| P1[8/13 Sync lock file without upgrades]
    P -->|Yes| P2[Skip step 8; update step will rewrite lock]
    P1 --> Q{SkipPoetryInstall?}
    P2 --> Q
    Q -->|No + UpdateDependencies| Q1[9/13 Re-resolve dependencies]
    Q -->|No + default| Q2[9/13 Install exact versions from lock]
    Q -->|Yes| Q3[Skip dependency install/update]

    Q1 --> R[10/13 Resolve site-packages and write project .pth]
    Q2 --> R
    Q3 --> R
    R --> S[11/13 Write .vscode/settings.json interpreter path]
    S --> T[12/13 Copy tcl runtime if source exists]
    T --> U{EnableCodeSigning?}
    U -->|Yes| U1[13/13 Sign generated executables in .venv]
    U -->|No| U2[Skip venv executable signing]
    U1 --> V[POST-a Clean stale quarantine and backup dirs]
    U2 --> V
    V --> W{Backup from 5b exists?}
    W -->|Yes| W1[POST-b Remove successful .venv backup]
    W -->|No| X[Persist non-dry-run config]
    W1 --> X
    X --> X1[Persist pinned tool versions and explicit CLI package manager only]
    X1 --> Y[Done message]
    Y --> Z[POST Best-effort activation]
    Z --> ZA[Return summary object]

    D6 --> ERR[Failure handler]
    F8 --> ERR
    H --> ERR
    I --> ERR
    J --> ERR
    K --> ERR
    L1 --> ERR
    M --> ERR
    N --> ERR
    O --> ERR
    P1 --> ERR
    Q1 --> ERR
    Q2 --> ERR
    R --> ERR
    S --> ERR
    T --> ERR
    U1 --> ERR
    ERR --> ERR1[Log failing step, module, message, location, stack]
    ERR1 --> ERR2{.venv backup exists?}
    ERR2 -->|Yes| ERR3[Restore .venv backup]
    ERR2 -->|No| ERR4[Exit 1]
    ERR3 --> ERR4
```

## Dry-Run Rules

```mermaid
flowchart TD
    A[DryRun enabled] --> A1{Windows host?}
    A1 -->|No| A2[Abort: Windows-only automation]
    A1 -->|Yes| B[NonInteractive auto-enabled]
    B --> C[Read-only steps still execute]
    C --> C1[DETECT]
    C --> C2[0/13 Prechecks]
    C --> C3[1/13 Parse pyproject]
    C --> C4[2/13 Resolve Python]
    C2 --> D{Critical precheck failure?}
    D -->|Yes| D1[Report: real setup would abort]
    D -->|No| E[Continue plan]
    D1 --> E
    E --> F[Mutating steps are skipped by Invoke-SetupStep]
    F --> G[No .venv, lock, config, VS Code, Tcl, or signing changes]
    G --> H[Exit 0 if the plan itself is valid]
```
