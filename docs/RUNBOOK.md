# Backup Runbook

## Normal Backup

Run from `C:\Users\danie\danlab-vps-backup-control`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Backup-Vps.ps1
```

This creates a timestamped backup set under `C:\Backups\danlab-vps`.

Default contents:

- Sanitized Docker/system inventory
- Main Postgres `pg_dumpall`
- pgvector `pg_dumpall`
- Redis `dump.rdb`
- Manifest copied to `manifests\`

Database and Redis artifacts are encrypted locally and plaintext copies are removed after encryption.

## Volume Backup

For app/config volumes:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Backup-Vps.ps1 -IncludeVolumes
```

Default selected volumes:

- `baserow_data`
- `chatwoot_data`
- `contentos-tools_searxng-config`
- `evolutionv2_instances`
- `minio_data`
- `portainer_data`
- `volume_swarm_certificates`

Live database volumes are intentionally not tarred by default. Use logical dumps for Postgres/pgvector and Redis snapshots for Redis.

## GitHub Sync

The repo should contain scripts, docs, inventory, and manifests only:

```powershell
git status
git add .gitignore README.md docs scripts lib manifests
git commit -m "Add danlab VPS backup control"
git push
```

Never commit `C:\Backups\danlab-vps` artifacts.

## Automatic Schedule

Install or refresh scheduled tasks:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-ScheduledTasks.ps1
```

Installed tasks:

- `\Danlab\Danlab VPS Database Backup`: daily at 03:15.
- `\Danlab\Danlab VPS Weekly Full Backup`: Sunday at 04:15, includes selected volumes and a local Postgres restore smoke test.

Logs are written to:

```text
C:\Backups\danlab-vps\logs
```

The scheduled runner:

- Prevents overlapping runs with `C:\Backups\danlab-vps\.backup.lock`.
- Creates local encrypted artifacts under `C:\Backups\danlab-vps`.
- Updates and pushes GitHub-safe manifests/inventory.
- Regenerates the Obsidian RAG note `wiki/entities/danlab-VPS-Backup-State.md`.
- Rebuilds Graphify scopes `obsidian-wiki` and `danlab-vps-backup-control`.
- Does not delete old backup sets automatically.

Windows Task Scheduler is configured for the current interactive user. If the machine is off or the user is not logged in, the task runs when available after login/wake.

## Operational Rules

- Run inventory first if the VPS changed recently.
- Check `remoteErrors` in each manifest.
- Run restore smoke tests after any backup script change.
- Do not prune Docker, alter volumes, rotate credentials, or scale services as part of backup.
