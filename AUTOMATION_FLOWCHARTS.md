# Python Venv Automation Flowcharts

This document contains two Mermaid diagrams for the automation in `python_venv_Automation`:

- A compact demo flow for quick presentation
- A development flow that shows the real orchestration path and key branching points

## Demo Flow

```mermaid
flowchart TD
    A[Start: setup-core.ps1] --> B[Detach from VS Code host]
    B --> C[Import Setup-Core.psm1]
    C --> D[Start-Setup]
    D --> E[Detect package manager]
    E --> F[Run prechecks]
    F --> G[Choose Python]
    G --> H[Ensure package manager runtime]
    H --> I[Create and validate .venv]
    I --> J[Install or update dependencies]
    J --> K[Write .pth and VS Code settings]
    K --> L[Optional code signing]
    L --> M[Best-effort activate venv]
    M --> N[Done]
```

## Development Flow

```mermaid
flowchart TD
    A[setup-core.ps1 entrypoint] --> A1[Forward CLI args to subprocess]
    A1 --> A2[Unblock module files]
    A2 --> A3[Import Setup-Core.psm1]
    A3 --> B[Start-Setup]

    B --> B1[Build setup context]
    B1 --> B2[Clear VIRTUAL_ENV / POETRY_ACTIVE / CONDA_PREFIX]
    B2 --> C[DETECT: Invoke-PmDetection]

    C --> C1[Apply .setup-config.json prefs]
    C1 --> C2{PackageManager override?}
    C2 -->|CLI| C3[Use uv or poetry]
    C2 -->|Config| C4[Use pinned manager]
    C2 -->|TOML scan| C5[Detect from pyproject / lock files]
    C2 -->|None| C6[Default to poetry]

    C3 --> D[0/13 Prechecks]
    C4 --> D
    C5 --> D
    C6 --> D

    D --> D1{Code signing usable?}
    D1 -->|Yes| D2[Keep signing enabled]
    D1 -->|No| D3[Disable signing]
    D2 --> E
    D3 --> E

    E[1/13 Parse pyproject.toml] --> F[2/13 Resolve Python]
    F --> F1{Selection mode}
    F1 -->|semi-auto| F2[Pick best compatible Python]
    F1 -->|list mode| F3[User picks from discovered interpreters]
    F1 -->|explicit path| F4[Validate supplied python.exe]

    F2 --> G
    F3 --> G
    F4 --> G

    G[3/13 Ensure PM runtime] --> G1[Update pip]
    G1 --> G2[uv or poetry runtime install / init]
    G2 --> H[3a/13 Optional sign PM executable]

    H --> I[4/13 Configure PM defaults]
    I --> J[5a/13 Clean stale PM env links]
    J --> K{Force recreate .venv?}
    K -->|Yes| K1[5b/13 Backup and remove old .venv]
    K -->|No| L[5c/13 Prepare .venv]
    K1 --> L
    L --> L1[Create or reuse venv with selected Python]

    L1 --> M[6/13 Validate .venv structure]
    M --> N[7/13 Copy Python runtime DLL]
    N --> O{UpdateDependencies?}
    O -->|No| P[8/13 Lock sync]
    O -->|Yes| Q[Skip lock sync]

    P --> R{Skip install step?}
    Q --> R
    R -->|No, update| S[9/13 Re-resolve dependencies]
    R -->|No, install| T[9/13 Install from lock file]
    R -->|Yes| U[Skip dependency step]

    S --> V[10/13 Resolve site-packages path]
    T --> V
    U --> V

    V --> W[Write project .pth]
    W --> X[11/13 Pin interpreter in .vscode/settings.json]
    X --> Y[12/13 Copy tcl runtime]
    Y --> Z{Code signing still enabled?}
    Z -->|Yes| Z1[13/13 Sign .venv executables]
    Z -->|No| AA[Skip signing]

    Z1 --> AB[POST-a Clean stale quarantine / backup dirs]
    AA --> AB
    AB --> AC{Backup exists?}
    AC -->|Yes| AD[POST-b Remove successful backup]
    AC -->|No| AE[Persist resolved config if allowed]
    AD --> AE
    AE --> AF[Activate venv in current shell]
    AF --> AG[Return summary object]

    D --> X1{Any mandatory step fails?}
    E --> X1
    F --> X1
    G --> X1
    H --> X1
    I --> X1
    J --> X1
    K1 --> X1
    L --> X1
    M --> X1
    N --> X1
    P --> X1
    S --> X1
    T --> X1
    W --> X1
    X --> X1
    Y --> X1
    Z1 --> X1
    X1 -->|Yes| X2[Log fatal error and rollback .venv backup]
```
