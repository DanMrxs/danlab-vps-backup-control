# Restore Notes

## Local Smoke Test

Use Docker Desktop to test a dump without touching the VPS:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Restore-Smoke-Test.ps1 -BackupSet C:\Backups\danlab-vps\<backup-id>
```

The script:

1. Decrypts `payload\databases\postgres_pg_dumpall.sql.gz.enc` into a temp directory.
2. Starts a temporary local `postgres:14` container.
3. Copies the dump into the container.
4. Restores with `psql -v ON_ERROR_STOP=1`.
5. Runs `select 1`.
6. Removes the test container and plaintext temp dump unless `-KeepContainer` is set.

## Manual Decrypt

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Unprotect-Artifact.ps1 -InputPath C:\Backups\danlab-vps\<backup-id>\payload\databases\postgres_pg_dumpall.sql.gz.enc
```

Only decrypt into a temp or controlled restore folder. Remove plaintext after use.

## VPS Restore Principle

Do not restore directly into production without:

- A fresh VPS snapshot or provider-level backup
- Current service inventory
- Confirmation of target stack/service names
- Confirmation that the target database/volume can be overwritten
- A tested local restore path

Production restore should be a separate, explicit operation.
