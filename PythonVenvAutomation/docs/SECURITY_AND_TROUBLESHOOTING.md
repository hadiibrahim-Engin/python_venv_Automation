# Security Model and Troubleshooting

## Security model

### Git

Normal synchronization is `fetch -> inspect -> pull --ff-only`. The automation never auto-merges, auto-rebases, or runs `git clean`. Dirty repositories are protected by default. `git reset --hard` is reachable only with explicit `-ForceGitPull` and participates in PowerShell `ShouldProcess` / `-Confirm`.

### DigiCert

The DigiCert executable is validated before setup starts mutating project state. Configure it with `DIGICERT_UTILITY_EXE` or `-DigiCertUtilityExe`. Missing tooling fails closed.

### Signing

Authenticode is inspected before DigiCert is invoked. `Valid` signatures are preserved; unsigned, changed (`HashMismatch`) or invalid binaries are signing candidates. This applies to full setup and `update-venv`.

### Configuration

Project configuration cannot enable destructive Git reset and does not persist machine-specific DigiCert paths. Failed config writes abort CI/non-interactive execution.

### Logging

Each run gets a correlation ID. Structured events are written as NDJSON to `%TEMP%\python-setup-log.json`. Secrets and credentials must never be written into logging context.

## Troubleshooting

### `DIGICERT_NOT_FOUND`

Install DigiCert Utility or set:

```powershell
$env:DIGICERT_UTILITY_EXE = 'C:\path\to\DigiCertUtil.exe'
```

### `PRECHECK_FAILED`

Review the precheck block and structured log. Network diagnostics can be non-critical; missing required infrastructure is critical.

### `PM_DETECTION_FAILED`

Check `.setup-config.json`, `pyproject.toml`, and lock files. An explicit `-PackageManager uv|poetry` has highest priority.

### `VENV_UPDATE_FAILED`

Verify `.venv\Scripts\python.exe` exists and the project package-manager CLI is available. A refresh does not bootstrap a missing package-manager runtime.

### Git sync says `SkippedDirty`

Commit or stash local changes, or run with `-SkipGitPull`. Use `-ForceGitPull` only when discarding tracked local changes/commits is intentional.

### Git sync says `Diverged`

Resolve the branch manually with your normal Git workflow. Automatic merges/rebases are deliberately disabled.

### Config cannot be written

Interactive execution asks whether to continue without persistence. CI/non-interactive execution fails. Check filesystem permissions and disk space.

### Signing scans many files

Scanning is expected; actual DigiCert signing is limited to files whose Authenticode status is not `Valid`. Check `NewlySigned` and `Skipped` in the returned signing result.

### Tests

Run:

```powershell
.\Run-Tests.ps1
```

For functional debugging without the coverage threshold:

```powershell
.\Run-Tests.ps1 -NoCoverage
```
