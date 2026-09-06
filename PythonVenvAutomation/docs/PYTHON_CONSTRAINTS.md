# Python Version Constraints

**Zielgruppe:** Developer
**Modul:** `scripts4PythonAutomation/SetupCore/modules/Versioning.psm1`

## Grundregel: fail closed

`ConvertTo-VersionConstraints` überspringt **nichts** stillschweigend. Wenn ein
Constraint nicht vollständig und eindeutig interpretiert werden kann, wird
`PYTHON_CONSTRAINT_UNSUPPORTED` geworfen.

Vorher wurde ein unverstandener Token mit einer Warnung verworfen. Aus
`>=3.11,@@@` wurde dadurch effektiv `>=3.11` — die Anforderung des Projekts
wurde also stillschweigend abgeschwächt und DevSetup konnte eine Python-Version
auswählen, die das Projekt gar nicht unterstützt.

## Parsing-Fluss

```mermaid
flowchart TD
    A["ConvertTo-VersionConstraints(str)"] --> B{Leer oder nur<br/>Leerzeichen?}
    B -->|Ja| E1[PYTHON_CONSTRAINT_UNSUPPORTED]:::err
    B -->|Nein| C["Split an ','"]

    C --> D{Segment leer?<br/>z.B. Doppelkomma}
    D -->|Ja| E1
    D -->|Nein| F[Pass 1: Shorthand expandieren]

    F --> F1["^X.Y  -> >=X.Y, &lt;(X+1).0"]
    F --> F2["~X.Y  -> >=X.Y, &lt;X.(Y+1)"]
    F --> F3["~=X.Y -> >=X.Y, &lt;(X+1).0"]
    F --> F4["~=X.Y.Z -> >=X.Y.Z, &lt;X.(Y+1)"]
    F --> F5["==X.Y.* -> >=X.Y, &lt;X.(Y+1)"]
    F --> F6[Alles andere unverändert]

    F1 --> G[Pass 2: Vergleiche parsen]
    F2 --> G
    F3 --> G
    F4 --> G
    F5 --> G
    F6 --> G

    G --> H{"Passt auf<br/>(op)(major.minor[.patch])?"}
    H -->|Nein| E1
    H -->|Ja| I{Mindestens<br/>major.minor?}
    I -->|Nein| E1
    I -->|Ja| J{Version castbar?}
    J -->|Nein| E1
    J -->|Ja| K{Operator}

    K -->|"==X.Y"| K1["-> >=X.Y, &lt;X.(Y+1)<br/>die ganze Minor-Linie"]:::ok
    K -->|"!=X.Y"| K2["-> Op '!=line'<br/>schliesst 3.12.* komplett aus"]:::ok
    K -->|sonst| K3[Direkt übernehmen]:::ok

    K1 --> L{Ergebnis leer?}
    K2 --> L
    K3 --> L
    L -->|Ja| E1
    L -->|Nein| M[List of Op/Version]:::ok

    classDef ok fill:#e6f5e6,stroke:#2d7a2d
    classDef err fill:#fde8e8,stroke:#c0392b
```

## Unterstützte Syntax

| Eingabe | Ergebnis |
|---|---|
| `>=3.11,<3.13` | `>=3.11` `<3.13` |
| `>=3.11` | `>=3.11` |
| `==3.11` | `>=3.11` `<3.12` (die 3.11-Linie, nicht exakt 3.11.0) |
| `==3.11.4` | exakt `3.11.4` |
| `==3.11.*` | `>=3.11` `<3.12` |
| `^3.11` | `>=3.11` `<4.0` |
| `^0.5` | `>=0.5` `<0.6` |
| `~3.11` | `>=3.11` `<3.12` |
| `~=3.11` | `>=3.11` `<4.0` |
| `~=3.11.4` | `>=3.11.4` `<3.12` |
| `!=3.12` | schließt **jede** 3.12.x aus |
| `!=3.12.1` | schließt genau 3.12.1 aus |
| `3.11` | wie `==3.11` |

## Abgelehnte Syntax

`~=3` · `>=3` · `>=abc` · `foo` · `>=3.11 <3.13` (fehlendes Komma) ·
`>=3.11,,<3.13` · `>=3.11,` · `===3.11` · `3.11.*.*` · `>=3.11.x`

Jeder dieser Fälle liefert `PYTHON_CONSTRAINT_UNSUPPORTED`, was auf den
Support-Code **DS-P202** abgebildet wird.

## `!=` schließt die ganze Minor-Linie aus

`!=3.12` bedeutet in der Praxis „diese Python-Linie funktioniert nicht", nicht
„exakt 3.12.0 funktioniert nicht". Deshalb erzeugt der Parser den internen
Operator `!=line`:

| Version | `>=3.11,!=3.12` |
|---|---|
| 3.11.9 | erfüllt |
| 3.12.0 | **nicht** erfüllt |
| 3.12.5 | **nicht** erfüllt |
| 3.13.1 | erfüllt |

`Test-VersionConstraints` wirft bei einem unbekannten Operator ebenfalls, statt
ihn als „erfüllt" durchzuwinken.
