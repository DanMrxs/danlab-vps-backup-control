# v2 AI-First VPS Control Layer Runbook

## Operating Model

v2 moves backup execution onto the VPS and makes the local machine a consumer of derived state.

- Canonical state: `manifest.json`
- Off-site encrypted backup: restic repository in Backblaze B2
- Scheduler: VPS `systemd` timers
- Alerting: Healthchecks.io pings
- Derived views: Obsidian note and Graphify scope generated from the manifest

## Secret Files

Real files live only on the VPS or restore endpoint:

```text
/etc/vps-control/config.env
/etc/vps-control/restic.env
/etc/vps-control/restic-passphrase
/etc/vps-control/healthchecks.env
```

Rules:

- Never commit real `.env`, restic passphrases, B2 keys, Healthchecks URLs, SSH private keys, or dumps.
- Store the restic passphrase in the password manager as the recovery source.
- Keep `/etc/vps-control/restic-passphrase` mode `0400`.
- Keep Healthchecks ping URLs secret; only slugs/names enter `manifest.json`.

## First Install On VPS

```bash
cd /opt/vps-backup-control
bash scripts/v2/install-vps.sh
cp config/v2/backup.env.example /etc/vps-control/config.env
cp config/v2/restic.env.example /etc/vps-control/restic.env
cp config/v2/healthchecks.env.example /etc/vps-control/healthchecks.env
chmod 0400 /etc/vps-control/restic-passphrase /etc/vps-control/restic.env /etc/vps-control/healthchecks.env
```

Initialize restic only after filling real B2 values:

```bash
set -a
. /etc/vps-control/restic.env
set +a
restic init
```

## Manual Runs

Syntax and dry-run checks:

```bash
bash -n scripts/v2/backup-vps.sh
scripts/v2/backup-vps.sh --mode daily --dry-run
```

Manual daily backup:

```bash
scripts/v2/backup-vps.sh --mode daily
```

Manual weekly backup and restore smoke test:

```bash
scripts/v2/backup-vps.sh --mode weekly
```

## Enable Timers

Enable only after one manual daily run passes:

```bash
systemctl enable --now vps-control-backup-daily.timer
systemctl enable --now vps-control-backup-weekly.timer
systemctl list-timers 'vps-control-*'
```

## Restore

List snapshots:

```bash
set -a
. /etc/vps-control/restic.env
set +a
restic snapshots --tag server=danlab-vps
```

Restore latest snapshot to a temporary directory:

```bash
mkdir -p /tmp/vps-restore
restic restore latest --target /tmp/vps-restore --tag server=danlab-vps
```

The monthly restore endpoint should run:

```bash
/opt/vps-backup-control/scripts/v2/monthly-restore-drill.sh
```

## Migration Safety

- Keep v1 Windows tasks running for 7 days.
- Disable v1 only after two successful daily v2 runs and one successful weekly v2 restore smoke test.
- Keep v1 scripts and existing local backup artifacts until the first monthly cross-machine restore passes.

## Failure Handling

If a backup fails:

1. Check Healthchecks failure and `/var/log/vps-control`.
2. Run `journalctl -u vps-control-backup-daily.service -n 200 --no-pager`.
3. Check `restic snapshots`.
4. Do not edit the Obsidian generated note by hand; fix the manifest source and regenerate.

## Validation

```bash
python3 scripts/v2/validate-manifest.py --schema schema/manifest.v2.schema.json --manifest manifest.json
jq . manifest.json >/dev/null
git status --short
```
