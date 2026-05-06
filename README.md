# danlab VPS Backup Control

GitHub-safe control repo for the `danlab-vps` backup/control layer.

## v2 Target Architecture

v2 moves backup execution onto the VPS and makes this repository the public-safe control plane:

- VPS-side `systemd` timers run backup jobs.
- restic writes encrypted off-site snapshots to Hetzner Storage Box over SFTP.
- Healthchecks.io monitors every scheduled job.
- `manifest.json` is the canonical state file.
- Obsidian and Graphify are derived views generated from the canonical manifest.
- The local Windows backup path remains as a temporary v1 fallback during migration.

Start here:

```bash
cat docs/V2-RUNBOOK.md
```

Main v2 paths:

```text
scripts/v2/                 VPS-side backup, publish, validation, and restore drill scripts
schema/manifest.v2.schema.json
systemd/                    Daily and weekly timer/service units
config/v2/*.example         Secret-free configuration templates
.github/workflows/          gitleaks secret scan
```

Do not enable v2 timers until Storage Box SSH access, the restic passphrase, and Healthchecks URLs are installed under `/etc/vps-control` on the VPS.

## v1 Local Backup Fallback

Real backup artifacts live under `C:\Backups\danlab-vps` and are excluded from git. Database dumps and volume archives are encrypted locally with a Windows DPAPI-protected AES key stored at:

```text
C:\Users\danie\.danlab-backup\backup-key.dpapi
```

The key can only be decrypted by the same Windows user profile unless rotated or exported through a separate recovery process.

This v1 path is kept only for migration safety. Disable it after v2 has two successful daily runs, one successful weekly restore smoke test, and one successful monthly cross-machine restore drill.

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

Install automatic Windows scheduled tasks:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-ScheduledTasks.ps1
```

Default schedule:

- Daily database/Redis/inventory backup at 03:15.
- Weekly full selected-volume backup plus restore smoke test on Sunday at 04:15.
- Tasks run when the Windows user is logged on and start when available if a scheduled run is missed.

Each scheduled run also refreshes the local LLM/RAG state:

- Regenerates `C:\Users\danie\Documents\Obsidian\2ndBrain\wiki\entities\danlab-VPS-Backup-State.md`
- Rebuilds Graphify scopes `obsidian-wiki` and `danlab-vps-backup-control`
- Pushes GitHub-safe manifests and inventory to the private control repo

## Git Safety

Commit only scripts, docs, sanitized inventory, and manifests. Do not commit:

- `.sql`, `.sql.gz`, `.dump`
- `.rdb`, `.rdb.gz`
- `.tgz`, `.tar`, `.zip`
- `.enc`
- `.env`, keys, tokens, credential exports

The `.gitignore` enforces this by default.
