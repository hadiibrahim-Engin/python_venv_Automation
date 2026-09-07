# Distributions-Architektur

**Zielgruppe:** Developer, CI/Admin
**Module:** `Distribution.psm1`, `build/Publish-Distribution.ps1`

## Ein Repository, zwei Branches

Es gibt **kein** zweites Repository. Releases liegen auf einem Orphan-Branch
desselben Repos, der keine gemeinsame History mit `main` hat.

```mermaid
flowchart TD
    subgraph repo["python_venv_Automation (ein Repo)"]
        direction TB
        subgraph main["main"]
            M1[scripts4PythonAutomation/]
            M2[PythonVenvAutomation/]
            M3[tests/]
            M4[docs/]
            M5[install/]
        end
        subgraph dist["distribution (orphan, keine gemeinsame History)"]
            D1["install/<br/>Install-DevSetup.cmd<br/>Install-DevSetup.ps1<br/>DevSetup.Bootstrap.ps1"]
            D2["channels/<br/>stable.json<br/>pilot.json"]
            D3["packages/1.8.0/<br/>manifest.json<br/>SHA256SUMS.txt<br/>content/"]
            D4["packages/1.9.0/<br/>manifest.json<br/>SHA256SUMS.txt<br/>content/"]
        end
    end

    main -->|"Azure Pipeline<br/>Publish-Distribution.ps1"| dist
    dist -->|"git clone --single-branch --depth 1"| C[Client]:::ok

    classDef ok fill:#e6f5e6,stroke:#2d7a2d
```

Der Client klont **nur** den Distribution-Branch, flach. Er lädt nie den
Quellcode, nie die Tests, nie die History. Entwickler-Clones von `main`
enthalten umgekehrt nie Release-Stände.

## Warum keine ZIP

| | ZIP | Lose Dateien |
|---|---|---|
| Integrität | eine Prüfsumme über alles | Prüfsumme **pro Datei** |
| Git-Kompression | keine Delta-Kompression, jede Version kostet die volle Größe – dauerhaft | Delta-komprimiert, kaum Zuwachs bei kleinen Änderungen |
| Review | „Was hat sich geändert?" nicht beantwortbar | normaler `git diff` |
| Zusätzliche Schritte | packen + entpacken | keine |

Git ist bereits ein content-addressed, unveränderlicher Transport. Eine ZIP
darüberzulegen bringt keine Garantie hinzu und kostet Repo-Größe und
Nachvollziehbarkeit.

## Vertrauenskette

```mermaid
flowchart LR
    A["Azure DevOps<br/>HTTPS + Entra / GCM"]:::trust
    B["channels/stable.json<br/>nennt Version + Pfad"]
    C["packages/&lt;v&gt;/manifest.json<br/>pinnt checksumsSha256"]
    D["SHA256SUMS.txt<br/>Hash je Datei"]
    E["Authenticode<br/>Signatur je Datei (Windows)"]
    F[Aktivierung]:::ok

    A --> B --> C --> D --> E --> F

    classDef trust fill:#e8eefc,stroke:#3b5bdb
    classDef ok fill:#e6f5e6,stroke:#2d7a2d
```

Jede Stufe wird geprüft, **bevor** der nächsten vertraut wird. Das Manifest
pinnt den Hash der Prüfsummenliste — eine manipulierte Liste fliegt auf, bevor
auch nur ein Datei-Hash geglaubt wird.

## Package-Format

```
packages/1.9.0/
├── manifest.json      Metadaten + Hash von SHA256SUMS.txt
├── SHA256SUMS.txt     "<sha256>␣␣<pfad>" je Datei, sortiert, /-Trenner
└── content/
    ├── PythonVenvAutomation/
    └── scripts4PythonAutomation/
```

`manifest.json`:

```json
{
  "schemaVersion": 1,
  "product": "DevSetup",
  "version": "1.9.0",
  "contentPath": "content",
  "checksums": "SHA256SUMS.txt",
  "checksumsSha256": "4ad4bcdff277...",
  "fileCount": 77,
  "channel": "stable",
  "minimumBootstrapVersion": "1.0.0",
  "publishedUtc": "2026-09-06T19:30:00Z"
}
```

`channels/stable.json`:

```json
{
  "schemaVersion": 1,
  "product": "DevSetup",
  "channel": "stable",
  "version": "1.9.0",
  "manifest": "packages/1.9.0/manifest.json",
  "minimumSupportedVersion": "1.7.0",
  "force": false,
  "publishedUtc": "2026-09-06T19:30:00Z"
}
```

`force = true` bedeutet: diese Version ist verpflichtend. Ein Offline-Client
darf dann **nicht** auf eine ältere lokale Version zurückfallen.

## Manifest-Validierung

Pflichtfelder und Datentypen werden strikt geprüft; **unbekannte zukünftige
Felder werden toleriert**, damit ein neuerer Publisher Daten ergänzen kann,
ohne ältere Clients zu brechen.

Eine Besonderheit: `ConvertFrom-Json` wandelt ISO-8601-Strings selbstständig in
`[datetime]` um. `publishedUtc` wird deshalb als *Timestamp* validiert, der
beide Formen akzeptiert.

## Immutability

```mermaid
flowchart TD
    A["Publish-Distribution.ps1 -Version X"] --> B{"packages/X<br/>existiert bereits?"}
    B -->|Nein| C[Package bauen]
    C --> D[SHA256SUMS.txt schreiben]
    D --> E[manifest.json schreiben]
    E --> F[Sofort verifizieren]
    F -->|ungültig| F1[Abbruch, kein Commit]:::err
    F -->|gültig| G[Channel setzen]

    B -->|Ja + -NoPromote| B1["Abbruch:<br/>DISTRIBUTION_VERSION_EXISTS"]:::err
    B -->|Ja + Channel| H["Nur Channel umbiegen,<br/>kein Rebuild"]:::ok
    H --> I[Commit + Push]
    G --> I
    I --> J[Aus frischem Clone erneut verifizieren]:::ok

    classDef ok fill:#e6f5e6,stroke:#2d7a2d
    classDef err fill:#fde8e8,stroke:#c0392b
```

Eine veröffentlichte Version wird **nie** überschrieben. Fixes bekommen eine
neue SemVer-Version. Der Guard sitzt in `New-DevSetupPackage`, greift also
auch bei manuellen Aufrufen.

## Channels: pilot und stable

Promotion ist reines Umbiegen einer Datei — das Package existiert bereits und
ist unveränderlich.

```mermaid
sequenceDiagram
    participant P as Pipeline
    participant D as distribution branch
    participant T as Tester (Channel pilot)
    participant U as Endanwender (Channel stable)

    P->>D: publish 1.10.0, pilot.json -> 1.10.0
    D-->>T: devsetup holt 1.10.0
    Note over U: stable.json steht weiter auf 1.9.3<br/>Endanwender bleiben unberührt
    T-->>P: Pilot erfolgreich
    P->>D: stable.json -> 1.10.0 (kein Rebuild)
    D-->>U: devsetup holt 1.10.0
```

`Set-DevSetupChannel` verifiziert das Ziel-Package vollständig, bevor der
Channel umgebogen wird. Ein Channel kann daher nie auf eine fehlende oder
beschädigte Version zeigen.

## Berechtigungen im Azure Repo

| Gruppe | Recht |
|---|---|
| Users | Read |
| Developers | Read |
| Build Service (`<Projekt> Build Service (<Org>)`) | Read + **Contribute** |

Der Push der Pipeline läuft über `persistCredentials: true`, also über die
Build-Service-Identität. Es steht **kein PAT** im YAML.

Der `distribution`-Branch ist im Trigger **ausgeschlossen** — sonst würde jeder
Release-Push die Pipeline erneut starten.

## Siehe auch

- [Self-Update](SELF_UPDATE.md) — was der Client bei jedem Start tut
- [Azure DevOps Distribution](AZURE_DEVOPS_DISTRIBUTION.md) — Pipeline und Betrieb
