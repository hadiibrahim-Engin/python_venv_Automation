# PyProject Health und Healing

**Zielgruppe:** Developer, Support
**Module:** `PyProjectHealth.psm1`, `TomlParser.psm1`

## Zwei getrennte Vorgänge

| | `Get-PyProjectHealthReport` | `Invoke-PyProjectHealing` |
|---|---|---|
| Schreibt? | nie | nur SafeAutoFix-Findings |
| Benutzt von | `devsetup doctor` | `devsetup repair` |
| Lock-Dateien | nur bewerten | **nie** anfassen |

## Finding-Modell

Jedes Finding trägt:

```
Code            PYPROJECT_DUPLICATE_DEPENDENCY
Severity        INFO | WARN | ERROR | FATAL
Message         Klartext für den Benutzer
AutoFixable     $true nur bei FixClass = SafeAutoFix
FixClass        SafeAutoFix | NeedsDecision | NotFixable
CurrentValue    was gefunden wurde
SuggestedValue  was stattdessen gelten sollte
Path            Datei oder TOML-Pfad
Category        file | syntax | metadata | python | dependencies | tooling | packagemanager | lock
```

## Health-Codes

| Code | Severity | FixClass |
|---|---|---|
| `PYPROJECT_MISSING` | FATAL | NeedsDecision |
| `PYPROJECT_EMPTY` | FATAL | NeedsDecision |
| `PYPROJECT_PARSE_INVALID` | FATAL | NotFixable |
| `PYPROJECT_NAME_MISSING` | ERROR | NeedsDecision |
| `PYPROJECT_VERSION_MISSING` | WARN | NeedsDecision |
| `PYPROJECT_REQUIRES_PYTHON_MISSING` | ERROR | NeedsDecision |
| `PYPROJECT_PYTHON_CONSTRAINT_INVALID` | ERROR | NeedsDecision |
| `PYPROJECT_PYTHON_CONSTRAINT_CONFLICT` | ERROR | NeedsDecision |
| `PYPROJECT_PM_AMBIGUOUS` | ERROR | NeedsDecision |
| `PYPROJECT_MULTIPLE_LOCKFILES` | ERROR | NeedsDecision |
| `PYPROJECT_DUPLICATE_DEPENDENCY` | WARN | **SafeAutoFix** |
| `PYPROJECT_METADATA_DIVERGED` | ERROR | NeedsDecision |
| `PYPROJECT_UV_SOURCE_ORPHANED` | WARN | NeedsDecision |
| `PYPROJECT_LEGACY_UV_DEV_DEPENDENCIES` | WARN | **SafeAutoFix** * |
| `PYPROJECT_POETRY_METADATA_LEGACY` | WARN | NeedsDecision |
| `LOCK_MISSING` | WARN | SafeAutoFix |
| `LOCK_OUTDATED` | WARN | SafeAutoFix |
| `LOCK_INVALID` | ERROR | NeedsDecision |
| `LOCK_WRONG_MANAGER` | ERROR | NeedsDecision |

\* wird zu **NeedsDecision** hochgestuft, wenn Dev-Dependencies gleichzeitig in
`[tool.uv].dev-dependencies` **und** `[dependency-groups].dev` stehen — dann ist
nicht entscheidbar, welche Liste gilt.

## Analysefluss

```mermaid
flowchart TD
    A[Get-PyProjectHealthReport] --> B{pyproject.toml existiert?}
    B -->|Nein| B1[PYPROJECT_MISSING - FATAL]:::err
    B -->|Ja| C{Datei leer?}
    C -->|Ja| C1[PYPROJECT_EMPTY - FATAL]:::err
    C -->|Nein| D[ConvertFrom-TomlText]

    D -->|wirft| D1[PYPROJECT_PARSE_INVALID - FATAL]:::err
    D -->|ok| E[ConvertTo-CanonicalMetadata]

    E --> F[Metadata-Prüfungen]
    E --> G[Python-Prüfungen]
    E --> H[Dependency-Prüfungen]
    E --> I[Tooling-Prüfungen]

    F --> J{FATAL vorhanden?}
    G --> J
    H --> J
    I --> J
    D1 --> J
    B1 --> J
    C1 --> J

    J -->|Ja| K["Lock-Health überspringen<br/>PM wäre nur geraten"]:::warn
    J -->|Nein| L[Get-PmDetectionReport]
    L --> M[Test-PyProjectLockHealth]

    K --> N["Findings deduplizieren<br/>(Code + Path)"]
    M --> N
    N --> O[Report mit Counts,<br/>HasErrors, IsHealthy]:::ok

    classDef ok fill:#e6f5e6,stroke:#2d7a2d
    classDef warn fill:#fff4e0,stroke:#b37400
    classDef err fill:#fde8e8,stroke:#c0392b
```

## Transaktionales Healing

```mermaid
flowchart TD
    A[Invoke-PyProjectHealing] --> B[Health-Report holen]
    B --> C{SafeAutoFix-Findings<br/>vorhanden?}
    C -->|Nein| C1[Nichts tun, Skipped melden]:::skip
    C -->|Ja| D[SHA256 des Originals]
    D --> E{ShouldProcess?}
    E -->|Nein / -WhatIf| E1[Abbruch, keine Sicherung]:::skip
    E -->|Ja| F["Backup schreiben<br/>pyproject.toml.devsetup-backup-&lt;ts&gt;"]

    F --> G[Patch im Speicher]
    G --> G1[Duplikate entfernen]
    G --> G2["[tool.uv].dev-dependencies<br/>-> [dependency-groups].dev"]
    G1 --> H[Nach jedem Patch neu parsen<br/>Zeilennummern verschieben sich]
    G2 --> H

    H --> I[Temp-Datei schreiben]
    I --> J[TOML-Syntax validieren]
    J --> K{Gültig?}
    K -->|Nein| R[Rollback]:::err
    K -->|Ja| L[Health erneut prüfen]

    L --> M{"Name, Version oder eine<br/>ganze Dependency-Liste verloren?"}
    M -->|Ja| R
    M -->|Nein| N[Diff erzeugen]
    N --> O[Atomar ersetzen<br/>Move-Item -Force]
    O --> P[TOML- und Health-Cache leeren]:::ok

    R --> R1[Temp-Datei löschen]
    R1 --> R2[Original aus Backup zurückspielen]
    R2 --> R3[Cache leeren]
    R3 --> R4[PYPROJECT_HEAL_FAILED werfen<br/>-> DS-P206]:::err

    classDef ok fill:#e6f5e6,stroke:#2d7a2d
    classDef skip fill:#eeeeee,stroke:#777
    classDef err fill:#fde8e8,stroke:#c0392b
```

**Es bleibt nie ein halb reparierter Zustand zurück.** Schlägt ein Schritt nach
dem Backup fehl, wird das Original zurückgespielt und geworfen.

## Sicherheitsnetz gegen zerstörerische Patches

Vor dem atomaren Ersetzen wird das kanonische Modell vorher/nachher verglichen.
Ein Patch wird zurückgerollt, wenn er

- den Projektnamen entfernt,
- die Projektversion entfernt,
- die komplette Runtime-Dependency-Liste leert oder
- die komplette Dev-Dependency-Liste leert.

## TOML-Parser

`TomlParser.psm1` ist ein bewusster **Teilmengen**-Parser für das, was echte
`pyproject.toml`-Dateien benutzen: Table-Header, Array-of-Tables, dotted und
quoted Keys, Basic/Literal/Multi-Line-Strings, Zahlen, Booleans, Arrays
(auch mehrzeilig mit Kommentaren) und Inline-Tables.

Er ist **fail-closed**: was er nicht sicher versteht, führt zu
`TOML_PARSE_ERROR`. Ein Healing-Lauf arbeitet nie auf einem nur halb
verstandenen Dokument. Datums-/Zeitwerte werden explizit abgelehnt.

Zusätzlich merkt er sich pro Key die Start- und Endzeile des Werts, damit der
Patch-Layer exakt die richtigen Zeilen ersetzt — statt globaler
Regex-Ersetzungen.

## Kommentare und Formatierung

Der Patch-Layer erhält Einrückung, Anführungszeichenstil, Zeilenumbrüche und
die Array-Form: ein einzeiliges Array bleibt einzeilig, ein mehrzeiliges bleibt
mehrzeilig.
