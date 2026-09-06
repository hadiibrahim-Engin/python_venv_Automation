# PythonVenvAutomation docs

Reference documentation:

- [Safe Git Synchronization](SAFE_GIT_SYNC.md) — Git pre-sync security model, configuration, CLI flags, decision matrix, and Mermaid process diagram.
- [Intelligent DigiCert Signing](SMART_CODE_SIGNING.md) — idempotent signing for existing `.venv` files and explicit re-signing.
- [Phase 2 Architecture](PHASE2_ARCHITECTURE.md) — centralized constants, structured exceptions, pipeline primitives, target architecture, and error-code strategy.
- [Configuration Reference](CONFIGURATION_REFERENCE.md) — all supported `.setup-config.json` keys and defaults.
- [Security Model and Troubleshooting](SECURITY_AND_TROUBLESHOOTING.md) — security invariants, common errors, and operator fixes.
- [Migration Guide](MIGRATION_GUIDE.md) — behavior changes for Git sync, signing, DigiCert, logging, configuration persistence, and tests.

## Für Endanwender

- [devsetup doctor](DEVSETUP_DOCTOR.md) — read-only Diagnose, Statusbedeutung, Beispielausgabe.
- [Support Bundle und Fehlercodes](SUPPORT_BUNDLE.md) — `devsetup support`, Redaction-Fluss, alle `DS-`-Codes.
- [Dependency-Semantik](DEPENDENCY_SEMANTICS.md) — was `devsetup`, `update` und `upgrade` jeweils tun.

## Für Entwickler

- [Package Manager Detection](PACKAGE_MANAGER_DETECTION.md) — starke Signale, Mehrdeutigkeit, fail-closed Verhalten.
- [Python Version Constraints](PYTHON_CONSTRAINTS.md) — unterstützte Syntax, fail-closed Parsing, `!=`-Semantik.
- [PyProject Health und Healing](PYPROJECT_HEALING.md) — Finding-Modell, alle Health-Codes, transaktionales Healing.
- [Modul-Architektur](MODULE_ARCHITECTURE.md) — Ladereihenfolge, Verantwortlichkeiten, PowerShell-Fallstricke.
- [Testen und Dummy-Workspace](TESTING_AND_DUMMY_WORKSPACE.md) — Testebenen, Fixtures, Feature-Matrix.
- Repository-level overview: [`../../README.md`](../../README.md)
- Detailed setup pipeline flow: [`../../scripts4PythonAutomation/Flow.md`](../../scripts4PythonAutomation/Flow.md)
- Example config: [`../../.setup-config.example.json`](../../.setup-config.example.json)
