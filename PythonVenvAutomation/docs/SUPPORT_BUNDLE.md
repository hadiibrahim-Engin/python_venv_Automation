# Support Bundle und Fehlercodes

**Zielgruppe:** End User, Support
**Module:** `Diagnostics.psm1`, `Redaction.psm1`, `SupportCodes.psm1`

## Für den Benutzer

```
devsetup support
```

erzeugt `DevSetup-Support-<YYYYMMDD-HHMMSS>.zip` im Projektverzeichnis. Das
Paket enthält **keine** Kennwörter, Tokens oder Zugangsdaten.

## Inhalt

| Datei | Inhalt |
|---|---|
| `system.json` | OS, Architektur, PowerShell-Version, Umgebungsvariablen (nach Schlüsselnamen bereinigt) |
| `devsetup-version.json` | Version, Installationspfad, Auto-Update-Konfiguration |
| `health-report.json` | vollständiger Doctor-Report |
| `pyproject-health.json` | alle pyproject-Findings + kanonisches Projektmodell |
| `python-report.json` | gefundene Python-Interpreter, `.venv` vorhanden |
| `git-status.txt` | `git status --porcelain -b` und `git remote -v` |
| `setup-log.ndjson` | strukturiertes Log des letzten Laufs (falls vorhanden) |
| `setup-config.json` | `.setup-config.json` des Projekts (bereinigt) |

## Redaction-Fluss

```mermaid
flowchart TD
    A[New-DevSetupSupportBundle] --> B[Staging-Verzeichnis im Temp]

    B --> C1[system.json]
    B --> C2[devsetup-version.json]
    B --> C3[health-report.json]
    B --> C4[pyproject-health.json]
    B --> C5[python-report.json]
    C1 --> D[Protect-SecretObject]
    C2 --> D
    C3 --> D
    C4 --> D
    C5 --> D

    B --> E1[git-status.txt]
    B --> E2[setup-log.ndjson]
    B --> E3[setup-config.json]
    E1 --> F[Protect-SecretText / Protect-SecretFile]
    E2 --> F
    E3 --> F

    D --> G[Compress-Archive]
    F --> G
    G --> H[DevSetup-Support-&lt;ts&gt;.zip]:::ok
    G --> I[Staging im finally-Block löschen]

    subgraph red["Protect-SecretObject"]
        R1{"Schlüsselname verdächtig?<br/>password token pat secret<br/>apikey authorization credential ..."}
        R1 -->|Ja| R2["Wert -> ***REDACTED***"]
        R1 -->|Nein| R3{Wert ist String?}
        R3 -->|Ja| R4[Protect-SecretText]
        R3 -->|Nein| R5[rekursiv weiter<br/>Tiefenlimit 12]
    end

    subgraph txt["Protect-SecretText"]
        T1["https://user:PAT@host<br/>-> user bleibt, PAT weg"]
        T2["Authorization: Bearer xyz<br/>-> komplett weg"]
        T3["token=... / apiKey: ...<br/>-> Wert weg"]
        T4["ghp_... und ADO-PAT-Muster<br/>-> weg"]
    end

    classDef ok fill:#e6f5e6,stroke:#2d7a2d
```

Ein Wert wird auch dann bereinigt, wenn der Schlüsselname harmlos aussieht — ein
`remote`-Feld mit `https://u:p4ss@host` wird trotzdem erkannt.

## Fehlercodes für Benutzer

Technische Exceptions erreichen den Endbenutzer nie. Stattdessen gibt es einen
stabilen Code:

```
Ein Konfigurationskonflikt benoetigt eine fachliche Entscheidung.

Es ist nicht eindeutig, ob das Projekt mit uv oder mit Poetry verwaltet wird.

Fehlercode: DS-P204

Bitte fuehren Sie bei Bedarf aus:

    devsetup support
```

### Code-Bereiche

| Bereich | Thema |
|---|---|
| `DS-U1xx` | Update / Installation |
| `DS-P2xx` | Projektkonfiguration (pyproject, Paketmanager, Lock) |
| `DS-V3xx` | Virtuelle Umgebung und Python |
| `DS-S4xx` | Signierung |
| `DS-G5xx` | Git |
| `DS-X9xx` | Nicht klassifiziert |

### Wichtige Codes

| Code | Bedeutung |
|---|---|
| `DS-U101` | Azure DevOps nicht erreichbar, lokale Version wird weiterbenutzt |
| `DS-U102` | Installierte Version zu alt und keine Verbindung |
| `DS-U103` | Update-Paket beschädigt (SHA256/Signatur) |
| `DS-U104` | Neue Version startete nicht, vorherige wiederhergestellt |
| `DS-U105` | Ein anderes Fenster aktualisiert gerade |
| `DS-P201` | pyproject.toml fehlt, leer oder Syntaxfehler |
| `DS-P202` | `requires-python` nicht auswertbar |
| `DS-P203` | Pflichtangaben fehlen |
| `DS-P204` | Paketmanager nicht eindeutig |
| `DS-P205` | Lock-Datei passt nicht zum Projekt |
| `DS-P206` | Reparatur fehlgeschlagen und zurückgerollt |
| `DS-V301` | Keine passende Python-Version gefunden |
| `DS-V302` | `.venv` nicht erstellbar oder ungültig |
| `DS-V303` | Abhängigkeitsinstallation fehlgeschlagen |
| `DS-V304` | `.venv` von anderem Programm belegt |
| `DS-S401` | Signaturprüfung fehlgeschlagen |
| `DS-S402` | DigiCert-Werkzeug nicht gefunden |
| `DS-G501` | Repository nicht aktualisierbar |
| `DS-G502` | Git nicht verfügbar |
| `DS-X901` | Unerwarteter Fehler |

Die vollständige Tabelle liefert `Get-DevSetupSupportCodeTable`.

## Für Support-Mitarbeiter

Der Support-Code steht auch im strukturierten Log, zusammen mit dem
vollständigen technischen Kontext (ErrorCode, Step, Context-Hashtable,
Correlation-ID). Der Benutzer nennt den `DS-`-Code, das Log liefert den Rest.
