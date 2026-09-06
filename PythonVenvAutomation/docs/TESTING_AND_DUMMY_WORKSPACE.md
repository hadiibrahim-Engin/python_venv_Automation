# Testen und Dummy-Workspace

**Zielgruppe:** Developer, CI/Admin

## Drei Ebenen

```mermaid
flowchart TD
    subgraph unit["1 - Pester Unit-/Modultests"]
        U1[tests/*.Tests.ps1]
        U2["./Run-Tests.ps1 -MinimumCoverage 70"]
        U1 --> U2
    end
    subgraph py["2 - Python-Tests"]
        P1[tests/python/test_bump_version.py]
        P2[".venv/bin/python -m pytest tests/python -q"]
        P1 --> P2
    end
    subgraph e2e["3 - Feature-Matrix gegen echte Fixtures"]
        E1[tests/dummy/New-DummyProject.ps1]
        E2[tests/dummy/Invoke-FeatureMatrix.ps1]
        E1 --> E2
    end
    unit --> ci{CI-Gate}
    py --> ci
    e2e --> ci
    ci --> ok[Build grün]:::ok
    classDef ok fill:#e6f5e6,stroke:#2d7a2d
```

## Dummy-Workspace

`tests/dummy/New-DummyProject.ps1` baut einen Wegwerf-Workspace mit allen
Projektformen, die DevSetup unterscheiden muss — und mit **echten**
Git-Repositories samt echter Upstreams, damit Safe Git Sync nicht gemockt,
sondern wirklich ausgeführt wird.

### Python-Projekte

| Verzeichnis | Aufbau | Erwartung |
|---|---|---|
| `uv-project` | `[project]` + `[tool.uv]` + `uv.lock` | Resolved: uv |
| `poetry-project` | `[tool.poetry]` + Poetry-Backend + Lock | Resolved: poetry |
| `pep621-only` | nur `[project]` | Ambiguous |
| `dual-lock` | `[project]` + beide Locks | Ambiguous (MULTIPLE_LOCKFILES) |
| `both-tools` | `[tool.uv]` **und** `[tool.poetry]` | Ambiguous |
| `no-signal` | leeres Verzeichnis | Default: poetry |
| `bad-constraint` | `requires-python = ">=3.11 <3.13"` | Constraint fail-closed |
| `no-version` | `[project]` ohne `version` | VERSION_MISSING |
| `malformed` | kaputtes TOML | PARSE_INVALID |
| `diverged-meta` | `[tool.poetry].version` ≠ `[project].version` | METADATA_DIVERGED |
| `requirements-only` | nur `requirements.txt` | PYPROJECT_MISSING |

### Git-Repositories

| Verzeichnis | Zustand | Erwarteter Status |
|---|---|---|
| `clean` | synchron | `UpToDate` |
| `behind` | Upstream ist voraus | `FastForwarded` |
| `dirty-behind` | hinterher **und** lokale Änderungen | `SkippedDirty` |
| `diverged` | beide Seiten bewegt | `Diverged` |
| `no-upstream` | Branch ohne Tracking | `NoUpstream` |
| `detached` | Detached HEAD | `DetachedHead` |
| `not-a-repo` | normales Verzeichnis | `NotGitRepository` |

## Feature-Matrix

`Invoke-FeatureMatrix.ps1` fährt jedes auf diesem Host ausführbare Feature gegen
die Fixtures und druckt eine Pass/Fail-Matrix. Features, die außerhalb von
Windows wirklich nicht laufen können, erscheinen als **SKIP mit Begründung** —
nie stillschweigend weggelassen.

```mermaid
flowchart TD
    A[Invoke-FeatureMatrix] --> B[New-DummyProject]
    B --> C[Engine laden]
    C --> D1[Package-Manager-Erkennung]
    C --> D2[Python-Constraints]
    C --> D3[Projekt-Metadaten]
    C --> D4[Safe Git Sync + Recovery Ref]
    C --> D5[Projektkonfiguration]
    C --> D6[Strukturiertes Logging]
    C --> D7[Setup-Pipeline dry-run]
    C --> D8[pyproject Health]
    C --> D9[pyproject Healing]
    C --> D10[Dependency-Semantik]
    C --> D11[User Commands]
    C --> D12[Version-Bumping]
    C --> D13[Plattform-gebundene Features]

    D1 --> E[PASS / FAIL / SKIP je Prüfung]
    D13 --> E
    E --> F[feature-matrix.json]
    E --> G{FAIL > 0?}
    G -->|Ja| G1[exit 1]:::err
    G -->|Nein| G2[exit 0]:::ok

    classDef ok fill:#e6f5e6,stroke:#2d7a2d
    classDef err fill:#fde8e8,stroke:#c0392b
```

## Ausführen

```powershell
# Alle Pester-Tests inklusive Coverage-Gate (wie in CI)
./Run-Tests.ps1 -MinimumCoverage 70

# Dummy-Workspace erzeugen
./tests/dummy/New-DummyProject.ps1

# Feature-Matrix
./tests/dummy/Invoke-FeatureMatrix.ps1
```

Auf macOS/Linux schlagen die 5 Tests in `CodeSigning.Tests.ps1` fehl, weil sie
`Get-AuthenticodeSignature` mocken, das dort nicht existiert. Der Agent-Treiber
`.claude/skills/run-python-venv-automation/driver.ps1 test -SkipSigningTests`
schließt genau diese Datei aus.

## Nicht-interaktiv

Fehlerpfade fragen `Test-SetupInteractive`, bevor sie einen Prompt zeigen.
`DEVSETUP_NONINTERACTIVE=1` erzwingt den unbeaufsichtigten Modus; `CI`,
`TF_BUILD` und `GITHUB_ACTIONS` wirken automatisch.
