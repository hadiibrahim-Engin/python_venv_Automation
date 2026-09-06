# Dependency-Semantik

**Zielgruppe:** End User, Developer
**Modul:** `scripts4PythonAutomation/SetupCore/modules/SetupSteps.psm1`

## Grundregel

Ein normaler `devsetup`-Lauf stellt den **gewünschten Zustand** her. Er
aktualisiert **keine** Abhängigkeiten auf neuere Versionen. Upgrades sind immer
eine bewusste Handlung.

Vorher rief `Invoke-DependencyInstallStep` am Ende bedingungslos
`Invoke-PmUpdateDeps` auf. Damit hat jede Arbeitsplatzvorbereitung die
Lock-Datei neu geschrieben und neue Upstream-Releases eingezogen — ohne dass
jemand danach gefragt hatte.

## Kommandos

| Kommando | Bedeutung | Interne Aktion |
|---|---|---|
| `devsetup` | Desired State herstellen | `Invoke-PmInstallDeps` (lock-konform) |
| `devsetup update` | vorhandenes `.venv` synchronisieren | `Invoke-PmInstallDeps` |
| `devsetup upgrade` | bewusst alle Abhängigkeiten aktualisieren | `Invoke-PmUpdateDeps` |
| `devsetup update -- -UpgradePackage my-lib` | nur ein Paket aktualisieren | `Invoke-PmUpdateSelectedDeps` |
| `devsetup -- -PinExact` | exakt die Lock-Versionen | `Invoke-PmInstallDeps` |

## Entscheidungsfluss

```mermaid
flowchart TD
    A[Invoke-DependencyInstallStep] --> B{SkipPoetryInstall?}
    B -->|Ja| B1["return 'skipped'"]:::skip
    B -->|Nein| C{ShouldProcess?<br/>-WhatIf / -Confirm}
    C -->|Nein| C1["return 'whatif'<br/>kein Paketmanager-Aufruf"]:::skip
    C -->|Ja| D{PinExact?}

    D -->|Ja| D1["Invoke-PmInstallDeps<br/>return 'pin-exact'"]:::ok
    D -->|Nein| E{UpgradePackages<br/>nicht leer?}

    E -->|Ja| E1["Invoke-PmUpdateSelectedDeps<br/>return 'selective-upgrade'"]:::warn
    E -->|Nein| F{UpdateDependencies?}

    F -->|Ja| F1["Invoke-PmUpdateDeps<br/>return 'upgrade-all'"]:::warn
    F -->|Nein| G["Invoke-PmInstallDeps<br/>return 'sync-locked'"]:::ok

    classDef ok fill:#e6f5e6,stroke:#2d7a2d
    classDef warn fill:#fff4e0,stroke:#b37400
    classDef skip fill:#eeeeee,stroke:#777
```

Selektives Upgrade hat Vorrang vor einem Pauschal-Upgrade: wer `-UpgradePackage`
angibt, meint genau dieses Paket.

## Drei getrennte Vorgänge

```mermaid
flowchart LR
    subgraph sync["1 - sync / install"]
        S1[Lock-Datei lesen]
        S2[Exakt diese Versionen installieren]
        S1 --> S2
    end
    subgraph heal["2 - heal-lock"]
        H1[Lock ist nur stale]
        H2[Lock neu erzeugen<br/>ohne Upgrade-Absicht]
        H1 --> H2
    end
    subgraph up["3 - upgrade"]
        U1[Constraints neu auflösen]
        U2[Neueste zulässige Versionen]
        U1 --> U2
    end
    sync -.->|niemals implizit| up
    heal -.->|niemals implizit| up
```

Lock-Healing und Dependency-Upgrade sind strikt getrennt. Eine veraltete
Lock-Datei zu reparieren heißt **nicht**, Pakete zu aktualisieren.

## Lock Health

`Test-PyProjectLockHealth` klassifiziert vor der Installation:

| Finding | Bedeutung | FixClass |
|---|---|---|
| `LOCK_MISSING` | Lock fehlt, kann aus `pyproject.toml` erzeugt werden | SafeAutoFix |
| `LOCK_OUTDATED` | Lock ist älter als `pyproject.toml` | SafeAutoFix |
| `LOCK_INVALID` | Lock ist leer oder unlesbar | NeedsDecision |
| `LOCK_WRONG_MANAGER` | Lock gehört zum anderen Paketmanager | NeedsDecision |
| `PYPROJECT_MULTIPLE_LOCKFILES` | `uv.lock` **und** `poetry.lock` | NeedsDecision |

Eine ungültige oder fremde Lock-Datei wird **nie** blind überschrieben.
