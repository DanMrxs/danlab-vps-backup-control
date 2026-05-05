# danlab VPS Backup Control

GitHub-safe control repo for local backups of `danlab-vps`.

Real backup artifacts live under `C:\Backups\danlab-vps` and are excluded from git. Database dumps and volume archives are encrypted locally with a Windows DPAPI-protected AES key stored at:

```text
C:\Users\danie\.danlab-backup\backup-key.dpapi
```

The key can only be decrypted by the same Windows user profile unless rotated or exported through a separate recovery process.

## Quick Start

Initialize the local encryption key:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Initialize-BackupKey.ps1
```

Run an inventory-only backup:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Inventory-Vps.ps1
```

Run a database backup:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Backup-Vps.ps1
```

Include selected application volumes:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Backup-Vps.ps1 -IncludeVolumes
```

Run a local restore smoke test for the main Postgres dump:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Restore-Smoke-Test.ps1 -BackupSet C:\Backups\danlab-vps\<backup-id>
```

## Git Safety

Commit only scripts, docs, sanitized inventory, and manifests. Do not commit:

- `.sql`, `.sql.gz`, `.dump`
- `.rdb`, `.rdb.gz`
- `.tgz`, `.tar`, `.zip`
- `.enc`
- `.env`, keys, tokens, credential exports

The `.gitignore` enforces this by default.
