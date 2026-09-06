# Configuration Reference

Project-local configuration lives in `.setup-config.json`.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `AutoGitPull` | boolean | `true` | Run safe Git synchronization before setup. |
| `GitPullStrategy` | string | `SkipIfDirty` | `SkipIfDirty` or `ErrorIfDirty`. |
| `LogLevel` | string | `INFO` | `DEBUG`, `INFO`, `WARN`, or `ERROR`. |
| `PackageManager` | string | `auto` | `auto`, `uv`, or `poetry`. Explicit CLI choices may be persisted. |
| `PinnedPoetryVersion` | string | empty | Optional Poetry runtime version pin. |
| `PinnedUvVersion` | string | empty | Optional uv runtime version pin. |

Example:

```json
{
  "AutoGitPull": true,
  "GitPullStrategy": "SkipIfDirty",
  "LogLevel": "INFO",
  "PackageManager": "auto",
  "PinnedPoetryVersion": "",
  "PinnedUvVersion": ""
}
```

Machine-specific and destructive settings are intentionally not persisted here. In particular, DigiCert executable paths should come from `DIGICERT_UTILITY_EXE` or `-DigiCertUtilityExe`, and forced Git reset is CLI-only through `-ForceGitPull`.
