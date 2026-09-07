# Self-Update

**Zielgruppe:** Developer, Support
**Datei:** `PythonVenvAutomation/templates/DevSetup.Bootstrap.ps1`

## Grundregel

Der Updatecheck läuft bei **jedem** `devsetup`-Start. Es gibt bewusst keine
12h/24h-Cache-Logik. Ein Netzwerkfehler blockiert den Benutzer trotzdem nicht.

## Ablauf

```mermaid
flowchart TD
    A[devsetup] --> B{Diagnose-Befehl?<br/>doctor / about / support / help}
    B -->|Ja| B1["Kein Update-Check:<br/>der Zustand soll gemeldet werden,<br/>den der Benutzer wirklich hat"]:::skip
    B -->|Nein| C[Update-Lock nehmen]

    C --> C1{Lock erhalten?}
    C1 -->|Nein| C2["Anderes Fenster aktualisiert.<br/>State erneut lesen:<br/>fertig -> neue Version nutzen"]:::warn
    C1 -->|Ja| D{Distribution-Clone<br/>vorhanden und intakt?}

    D -->|Nein| D1["neu klonen<br/>--single-branch --depth 1"]
    D -->|Ja| D2["git fetch --depth 1<br/>git reset --hard origin/&lt;branch&gt;"]
    D1 --> E
    D2 --> E

    E{Erreichbar?}
    E -->|Ja| F["channels/&lt;channel&gt;.json lesen<br/>lastKnownMinimum merken"]
    E -->|Nein| G[Offline-Pfad]

    F --> H[Get-DevSetupBootDecision]
    G --> H

    H --> I{Action}
    I -->|none| I1[Aktuelle Version starten]:::ok
    I -->|fail| I2["Verständliche Meldung<br/>DS-U102"]:::err
    I -->|install / update| J[Install-DevSetupBootVersion]

    J --> K{Erfolg?}
    K -->|Ja| K1["Neu starten,<br/>damit die neuen Dateien geladen werden"]:::ok
    K -->|Nein| K2["Vorherige Version bleibt aktiv<br/>DS-U104"]:::warn

    classDef ok fill:#e6f5e6,stroke:#2d7a2d
    classDef warn fill:#fff4e0,stroke:#b37400
    classDef err fill:#fde8e8,stroke:#c0392b
    classDef skip fill:#eeeeee,stroke:#777
```

## Entscheidungsmatrix

`Get-DevSetupBootDecision` ist eine reine Funktion ohne I/O — jeder Zweig ist
direkt testbar.

| Zustand | Ergebnis |
|---|---|
| installiert == Channel | `none` |
| installiert > Channel | `none` |
| installiert < Channel | `update` |
| nichts installiert | `install` |
| installiert < `minimumSupportedVersion` | `update` (nicht mehr optional) |
| Channel nennt keine Version | `fail` |
| Zielversion steht in `failedVersions` | `none` (kein Loop) |
| **offline**, installiert ≥ Minimum | `none` + Warnung |
| **offline**, installiert < Minimum | `fail` |
| **offline**, nichts installiert | `fail` |
| **offline**, `force = true` | `fail` (kein Fallback) |
| **offline**, `AllowOfflineContinue = false` | `fail` |

Der zuletzt bekannte `minimumSupportedVersion` wird als `lastKnownMinimum` im
State gespeichert. Nur dadurch kann die Untergrenze auch offline greifen.

## Atomare Aktivierung

```mermaid
flowchart TD
    A["packages/&lt;v&gt; im Clone"] --> B[Manifest prüfen]
    B --> C["SHA256SUMS.txt gegen<br/>manifest.checksumsSha256"]
    C --> D["Hash je Datei<br/>+ keine unlisted Datei"]
    D --> E["Authenticode<br/>(nur Windows)"]
    E --> F["staging/&lt;v&gt;"]
    F --> G["Self-Test im KIND-Prozess:<br/>1. alles parst<br/>2. Modul importiert"]
    G --> H["versions/&lt;v&gt;"]
    H --> I["current.json atomar umschalten<br/>(Temp-Datei + Move)"]:::ok

    B -->|ungültig| R[Rollback]:::err
    C -->|ungültig| R
    D -->|ungültig| R
    E -->|ungültig| R
    G -->|fehlgeschlagen| R

    R --> R1[staging löschen]
    R1 --> R2["versions/&lt;v&gt; löschen"]
    R2 --> R3["Version in failedVersions merken"]
    R3 --> R4["Vorherige Version bleibt unverändert aktiv"]:::warn

    classDef ok fill:#e6f5e6,stroke:#2d7a2d
    classDef warn fill:#fff4e0,stroke:#b37400
    classDef err fill:#fde8e8,stroke:#c0392b
```

Die aktive Installation wird **nie** direkt überschrieben. Der Self-Test läuft
in einem Kindprozess, damit ein defektes Paket die laufende Sitzung nicht
vergiften kann.

`state/current.json`:

```json
{
  "version": "1.9.0",
  "previousVersion": "1.8.3",
  "activatedUtc": "2026-09-06T19:31:02.1234567Z",
  "failedVersions": ["1.9.1"],
  "lastKnownMinimum": "1.7.0"
}
```

## Kein Update-Loop

Eine Version, die beim Aktivieren scheitert, landet in `failedVersions`.
`Get-DevSetupBootDecision` bietet sie danach nicht mehr an — der Benutzer
arbeitet auf der letzten funktionierenden Version weiter, statt bei jedem
Start denselben fehlschlagenden Versuch zu sehen. Ein späterer, korrigierter
Publish derselben Version räumt die Markierung beim erfolgreichen Aktivieren
wieder ab.

Benutzerausgabe in diesem Fall:

```
Eine neue DevSetup-Version konnte nicht gestartet werden.

Die vorherige funktionierende Version wurde automatisch wiederhergestellt.

Sie koennen weiterarbeiten.

Fehlercode: DS-U104
```

## Parallele Terminals

```mermaid
sequenceDiagram
    participant A as Terminal A
    participant L as update.lock
    participant B as Terminal B

    A->>L: Lock nehmen (PID + Zeitstempel)
    B->>L: Lock nehmen -> belegt
    Note over B: wartet (LockWaitSeconds)
    A->>A: staging -> versions -> current.json
    A->>L: Lock freigeben
    B->>L: Lock erhalten
    B->>B: State erneut lesen: bereits aktuell
    Note over B: kein zweites Update,<br/>keine parallelen Schreibzugriffe
```

Ein Lock gilt als **stale**, wenn

* der eingetragene Prozess nicht mehr läuft,
* die Datei unlesbar ist (abgestürzter Schreiber), oder
* sie älter als `LockStaleMinutes` ist (PID kann wiederverwendet worden sein).

## Architektur-Grenze

Der Bootstrap kennt ausschließlich: Distribution-Repo, Channel, lokale
Versionen, Lock, Manifest-Validierung, SHA256, Authenticode, Staging,
Aktivierung, Rollback und den Start der eigentlichen Version.

Er kennt **nicht**: `pyproject.toml`, Poetry, uv, Python Discovery, `.venv`,
Dependency Management, VS Code, Tcl.

Das ist kein Vorsatz auf dem Papier: `tests/Bootstrap.Tests.ps1` scannt die
Datei und schlägt fehl, sobald einer dieser Begriffe auftaucht oder das Modul
importiert wird.

## Konfiguration

`%LOCALAPPDATA%\Company\DevSetup\config.json` — enthält nie Zugangsdaten:

| Schlüssel | Default | Bedeutung |
|---|---|---|
| `DistributionUri` | – | Clone-URL des Repos |
| `DistributionBranch` | `distribution` | Release-Branch |
| `Channel` | `stable` | `stable` oder `pilot` |
| `AutoUpdateEnabled` | `true` | Updatecheck aktiv |
| `AllowOfflineContinue` | `true` | Offline mit lokaler Version weiterarbeiten |
| `GitTimeoutSeconds` | `60` | Timeout je git-Aufruf |
| `LockWaitSeconds` | `90` | Wartezeit auf das Update-Lock |
| `LockStaleMinutes` | `15` | Alter, ab dem ein Lock als verwaist gilt |
| `KeepVersions` | `3` | behaltene Versionen (aktive und vorherige immer) |
