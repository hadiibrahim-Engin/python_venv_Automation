# Installation

**Zielgruppe:** End User

## Sie müssen genau zwei Dinge kennen

| Wann | Was |
|---|---|
| **Einmalig** | `Install-DevSetup.cmd` doppelklicken |
| **Danach immer** | `devsetup` |

Kein Administrator, keine PowerShell-Kenntnisse, kein Token, kein Kennwort.

## Was beim Doppelklick passiert

```mermaid
flowchart TD
    A["Install-DevSetup.cmd<br/>(Doppelklick)"] --> B["startet PowerShell<br/>für diesen einen Vorgang"]
    B --> C{Voraussetzungen}
    C -->|"PowerShell &lt; 5.1<br/>oder kein Git"| C1["Verständliche Meldung,<br/>Abbruch"]:::err
    C -->|ok| D["Verzeichnisse unter<br/>%LOCALAPPDATA%\\Company\\DevSetup"]
    D --> E["config.json<br/>(nur Repo-Adresse und Channel)"]
    E --> F["devsetup.cmd + devsetup.ps1<br/>im bin-Ordner"]
    F --> G["Nur der bin-Ordner<br/>kommt in den Benutzer-PATH"]
    G --> H["Anmeldung über Ihr<br/>Microsoft-Konto (GCM / Entra)"]
    H --> I["Release-Branch klonen"]
    I --> J["Manifest + Prüfsummen<br/>+ Signaturen prüfen"]
    J --> K[Version aktivieren]
    K --> L[Selbsttest]
    L --> M["DevSetup ist einsatzbereit."]:::ok

    classDef ok fill:#e6f5e6,stroke:#2d7a2d
    classDef err fill:#fde8e8,stroke:#c0392b
```

## Installationsziel

Alles liegt in Ihrem eigenen Benutzerprofil. Es wird nichts systemweit
verändert:

```
%LOCALAPPDATA%\Company\DevSetup\
├── bin\            devsetup.cmd, devsetup.ps1   <- nur dieser Ordner kommt in den PATH
├── bootstrap\      DevSetup.Bootstrap.ps1
├── distribution\   flacher Klon des Release-Branches
├── versions\       1.8.0\, 1.9.0\
├── staging\        Zwischenablage beim Update
├── logs\
├── state\          current.json
└── config.json
```

## Anmeldung

Beim ersten Zugriff auf Azure DevOps öffnet der Git Credential Manager eine
normale Microsoft-Anmeldung. Danach ist nichts mehr nötig.

**DevSetup speichert keine Zugangsdaten.** Das übernimmt vollständig der Git
Credential Manager. Ein Personal Access Token wird nie abgefragt und nie
benötigt. Eine Adresse mit eingebetteten Zugangsdaten (`https://user:token@...`)
wird abgelehnt statt gespeichert.

## Danach

Terminal öffnen, in Ihr Projekt wechseln, eingeben:

```
devsetup
```

Das war es. DevSetup prüft bei jedem Start selbst, ob es eine neuere Version
gibt, und aktualisiert sich bei Bedarf — ohne dass Sie etwas tun müssen.

## Weitere Befehle

| Befehl | Wirkung |
|---|---|
| `devsetup` | Projekt arbeitsbereit machen |
| `devsetup doctor` | Alles prüfen, nichts ändern |
| `devsetup repair` | Nur sichere Reparaturen durchführen |
| `devsetup upgrade` | Abhängigkeiten bewusst aktualisieren |
| `devsetup rebuild` | `.venv` neu erzeugen |
| `devsetup about` | Version und Status anzeigen |
| `devsetup support` | Support-Paket erzeugen (ohne Zugangsdaten) |
| `devsetup help` | Hilfe |

## Wenn etwas nicht klappt

DevSetup zeigt nie einen technischen Fehler, sondern einen Satz und einen Code:

```
DevSetup konnte das Projekt nicht vollstaendig vorbereiten.

Ein Konfigurationskonflikt benoetigt eine fachliche Entscheidung.

Fehlercode: DS-P204

Bitte fuehren Sie bei Bedarf aus:

    devsetup support
```

`devsetup support` erzeugt eine ZIP-Datei mit Diagnosedaten — **ohne**
Kennwörter, Tokens oder Zugangsdaten. Diese Datei und den Fehlercode an den
Support geben.

Die Bedeutung aller Codes steht in
[Support Bundle und Fehlercodes](SUPPORT_BUNDLE.md).
