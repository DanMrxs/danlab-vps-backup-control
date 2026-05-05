#!/usr/bin/env bash
set -euo pipefail

control_repo="${CONTROL_REPO:-/opt/vps-backup-control}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the VPS." >&2
  exit 1
fi

apt-get update
apt-get install -y restic age git jq curl python3 python3-jsonschema

mkdir -p /etc/vps-control /var/backups/vps-control/work /var/log/vps-control /opt
chmod 0750 /etc/vps-control /var/backups/vps-control /var/backups/vps-control/work /var/log/vps-control

if [[ ! -d "$control_repo/.git" ]]; then
  echo "Clone the control repo to $control_repo before installing units." >&2
  exit 2
fi

install -m 0755 "$control_repo/scripts/v2/backup-vps.sh" /usr/local/sbin/vps-control-backup
install -m 0755 "$control_repo/scripts/v2/monthly-restore-drill.sh" /usr/local/sbin/vps-control-monthly-restore-drill
install -m 0644 "$control_repo/systemd/vps-control-backup-daily.service" /etc/systemd/system/vps-control-backup-daily.service
install -m 0644 "$control_repo/systemd/vps-control-backup-daily.timer" /etc/systemd/system/vps-control-backup-daily.timer
install -m 0644 "$control_repo/systemd/vps-control-backup-weekly.service" /etc/systemd/system/vps-control-backup-weekly.service
install -m 0644 "$control_repo/systemd/vps-control-backup-weekly.timer" /etc/systemd/system/vps-control-backup-weekly.timer

systemctl daemon-reload

echo "Installed v2 dependencies and systemd units."
echo "Next: create /etc/vps-control/restic.env, restic-passphrase, healthchecks.env, then enable timers."
