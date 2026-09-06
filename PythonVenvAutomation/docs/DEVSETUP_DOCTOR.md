# devsetup doctor

**Zielgruppe:** End User, Support
**Modul:** `scripts4PythonAutomation/SetupCore/modules/Diagnostics.psm1`

## Garantie: read-only

`devsetup doctor` verändert **nichts**. Die Garantie ist strukturell:

- `Get-DevSetupDoctorReport` deklariert bewusst **kein** `SupportsShouldProcess`,
  weil es keine Aktion gibt, die das bräuchte.
- Jede Prüfung ist ein `Get-*` oder `Test-*`-Aufruf.
- Der Shim überspringt für `doctor` den Self-Update-Check, damit die Diagnose
  den Zustand meldet, den der Benutzer tatsächlich hat.

Getestet wird das über einen SHA256-Baum-Snapshot vor und nach zwei Läufen
(`tests/Commands.Tests.ps1`).

## Ablauf

```mermaid
flowchart TD
    A[devsetup doctor] --> B[Get-PythonVenvSetupInfo]
    B --> C[Get-DevSetupDoctorReport]

    C --> D1[DevSetup + Installationspfad]
    C --> D2[Git verfügbar]
    C --> D3[Repository-Status]
    C --> D4[Projektkonfiguration<br/>Get-PyProjectHealthReport]
    C --> D5[Paketmanager erkannt]
    C --> D6[Paketmanager-Programm]
    C --> D7[Python-Anforderung]
    C --> D8[Umgebung .venv]
    C --> D9[Abhängigkeiten / Lock]
    C --> D10[Signaturen]
    C --> D11[VS Code Einstellungen]

    D1 --> E[Checks: OK / WARN / FAIL / SKIP]
    D2 --> E
    D3 --> E
    D4 --> E
    D5 --> E
    D6 --> E
    D7 --> E
    D8 --> E
    D9 --> E
    D10 --> E
    D11 --> E

    E --> F[Format-DevSetupDoctorReport]
    F --> G{Ergebnis}
    G -->|FAIL vorhanden| G1["Probleme gefunden<br/>+ Hinweis auf devsetup repair<br/>falls SafeAutoFix dabei"]:::err
    G -->|nur WARN| G2[Hinweise, Projekt ist arbeitsbereit]:::warn
    G -->|alles OK| G3[Keine Probleme gefunden]:::ok

    classDef ok fill:#e6f5e6,stroke:#2d7a2d
    classDef warn fill:#fff4e0,stroke:#b37400
    classDef err fill:#fde8e8,stroke:#c0392b
```

Eine einzelne fehlschlagende Prüfung bricht den Report nicht ab: `Invoke-SafeProbe`
fängt sie ab und macht daraus eine rote Zeile.

## Beispielausgabe

```
DevSetup Diagnose

✓ DevSetup
✓ Installationspfad
✓ Git
✓ Projektkonfiguration
✓ Paketmanager
✓ Paketmanager-Programm
✓ Python-Anforderung
! Umgebung (.venv) - Noch nicht vorhanden.
✓ Abhaengigkeiten
! Signaturen - Signaturwerkzeug nicht gefunden.

Hinweise gefunden, das Projekt ist aber arbeitsbereit.
```

Bei einem mehrdeutigen Projekt:

```
✗ Projektkonfiguration - The package manager cannot be determined: ...
✗ Paketmanager - Nicht eindeutig - uv oder Poetry muss festgelegt werden.

Es wurden Probleme gefunden, die eine Entscheidung benoetigen.
```

## Status-Bedeutung

| Status | Zeichen | Bedeutung |
|---|---|---|
| OK | `✓` | Alles in Ordnung |
| WARN | `!` | Hinweis, Projekt bleibt arbeitsbereit |
| FAIL | `✗` | Muss behoben werden |
| SKIP | `-` | Auf dieser Plattform nicht anwendbar (nur mit `-Detailed` sichtbar) |

## Verwandte Kommandos

- `devsetup repair` — behebt genau die Findings mit `AutoFixable = true`
- `devsetup support` — erzeugt ein bereinigtes Support-Paket
- `devsetup about` — Version, Kanal, Installationspfad, Projektstatus
