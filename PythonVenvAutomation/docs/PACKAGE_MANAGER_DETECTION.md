# Package Manager Detection

**Zielgruppe:** Developer, Support
**Modul:** `scripts4PythonAutomation/SetupCore/modules/Detection.psm1`, `Toml.psm1`

## Grundregel

PEP 621 `[project]` ist **tool-neutral**. Die Anwesenheit von `[project]` sagt
nichts darüber aus, ob ein Projekt mit uv oder mit Poetry verwaltet wird.
Deshalb entscheidet DevSetup ausschließlich anhand *starker* Signale und
verweigert eine Antwort, wenn die Belege widersprüchlich oder nicht vorhanden
sind.

| Manager | Starke Signale |
|---|---|
| uv | `[tool.uv]` / `[tool.uv.*]`, `uv.lock` |
| Poetry | `build-backend = "poetry.core.masonry.api"`, `[tool.poetry]` / `[tool.poetry.*]`, `poetry.lock` |

`LastWriteTime` der Lock-Dateien wird **nicht** als Tie-Breaker benutzt. Welche
Datei zuletzt geschrieben wurde, ist ein Artefakt der Werkzeugreihenfolge und
keine Aussage über die Absicht des Teams.

## Entscheidungsfluss

```mermaid
flowchart TD
    A[Resolve-PackageManager] --> B{CliChoice != auto?}
    B -->|Ja| B1[Source = cli]:::ok
    B -->|Nein| C{".setup-config.json<br/>PackageManager gepinnt?"}
    C -->|Ja| C1[Source = config-file]:::ok
    C -->|Nein| D[Get-PmDetectionReport]

    D --> E[Belege sammeln]
    E --> E1["uv-Belege:<br/>[tool.uv], uv.lock"]
    E --> E2["poetry-Belege:<br/>poetry-Backend, [tool.poetry], poetry.lock"]

    E1 --> F{Beide Seiten<br/>haben Belege?}
    E2 --> F
    F -->|Ja| G[Status = Ambiguous]:::warn
    F -->|Nein| H{Genau eine Seite<br/>hat Belege?}

    H -->|Ja| H1[Status = Resolved]:::ok
    H -->|Nein| I{"[project] vorhanden?"}
    I -->|Ja| J["Status = Ambiguous<br/>PEP 621 ist tool-neutral"]:::warn
    I -->|Nein| K[Status = Default -> poetry]:::ok

    G --> L{Beide Lock-Dateien?}
    L -->|Ja| L1[PYPROJECT_MULTIPLE_LOCKFILES]:::warn
    L -->|Nein| L2[PYPROJECT_PM_AMBIGUOUS]:::warn

    L1 --> M[Resolve-AmbiguousPackageManager]
    L2 --> M
    J --> M

    M --> N{NonInteractive?}
    N -->|Ja| N1[SetupException<br/>Pipeline stoppt bei DETECT]:::err
    N -->|Nein| N2[Auswahl: 1 uv / 2 poetry]
    N2 --> N3[Source = user-decision]:::ok

    classDef ok fill:#e6f5e6,stroke:#2d7a2d
    classDef warn fill:#fff4e0,stroke:#b37400
    classDef err fill:#fde8e8,stroke:#c0392b
```

## Ergebnisobjekt

`Get-PmDetectionReport` liefert:

| Feld | Bedeutung |
|---|---|
| `PackageManager` | `uv`, `poetry` oder `$null` bei `Ambiguous` |
| `Status` | `Resolved` \| `Ambiguous` \| `Default` |
| `AmbiguityCode` | `PYPROJECT_PM_AMBIGUOUS` \| `PYPROJECT_MULTIPLE_LOCKFILES` \| `$null` |
| `Candidates` | Noch mögliche Manager bei `Ambiguous` |
| `Reason` | Klartextbegründung, die auch im Log erscheint |
| `HasUvSection`, `HasPoetrySection`, `HasPoetryBackend`, `HasProjectSection`, `HasUvLock`, `HasPoetryLock` | Rohsignale |

## Verhalten in CI

Nicht-interaktiv (`-NonInteractive`, `CI=1`, `TF_BUILD=1`) ist Mehrdeutigkeit
ein harter Fehler mit Support-Code **DS-P204**. Das ist Absicht: ein Build, der
selbst rät, produziert irgendwann eine falsche `.venv`.

## Auflösen einer Mehrdeutigkeit

1. `[tool.uv]` oder `[tool.poetry]` in `pyproject.toml` ergänzen — der saubere Weg.
2. Die nicht benutzte Lock-Datei löschen.
3. Einmalig pinnen: `devsetup -- -PackageManager uv` (schreibt `.setup-config.json`).

## Siehe auch

- [PyProject Health und Healing](PYPROJECT_HEALING.md)
- [devsetup doctor](DEVSETUP_DOCTOR.md)
