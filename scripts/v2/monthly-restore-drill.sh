#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${VPS_CONTROL_CONFIG:-/etc/vps-control/config.env}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

SERVER_ID="${SERVER_ID:-danlab-vps}"
CONTROL_REPO="${CONTROL_REPO:-/opt/vps-backup-control}"
RESTIC_ENV_FILE="${RESTIC_ENV_FILE:-/etc/vps-control/restic.env}"
HEALTHCHECKS_ENV_FILE="${HEALTHCHECKS_ENV_FILE:-/etc/vps-control/healthchecks.env}"
RESTORE_POSTGRES_IMAGE="${RESTORE_POSTGRES_IMAGE:-postgres:14}"

[[ -f "$RESTIC_ENV_FILE" ]] || { echo "Missing restic env file: $RESTIC_ENV_FILE" >&2; exit 2; }
set -a
source "$RESTIC_ENV_FILE"
set +a

[[ -f "$HEALTHCHECKS_ENV_FILE" ]] && source "$HEALTHCHECKS_ENV_FILE"
HC_MONTHLY_SLUG="${HC_MONTHLY_SLUG:-vps-restore-monthly}"
HC_MONTHLY_URL="${HC_MONTHLY_URL:-}"

drill_id="$(date -u +%Y%m%dT%H%M%SZ)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; docker rm -f "vps-monthly-restore-${drill_id}" >/dev/null 2>&1 || true' EXIT

ping_hc() {
  [[ -n "$HC_MONTHLY_URL" ]] || return 0
  curl -fsS -m 10 "${HC_MONTHLY_URL}${1:-}" >/dev/null || true
}

status="fail"
details=""
snapshot_id=""

ping_hc "/start"
if snapshot_json="$(restic snapshots --json --latest 1 --tag "server=${SERVER_ID}" 2>/dev/null)" &&
   snapshot_id="$(echo "$snapshot_json" | jq -r '.[0].short_id // .[0].id // empty')" &&
   [[ -n "$snapshot_id" ]]; then
  restic restore "$snapshot_id" --target "$tmp/restore"
  payload_dir="$(find "$tmp/restore" -type d -name payload | head -n 1)"
  dump_path="$payload_dir/databases/postgres_pg_dumpall.sql.gz"
  name="vps-monthly-restore-${drill_id}"
  docker run --rm --name "$name" -e POSTGRES_USER=restore_admin -e POSTGRES_PASSWORD=restore -d "$RESTORE_POSTGRES_IMAGE" >/dev/null
  for _ in $(seq 1 45); do
    docker exec "$name" pg_isready -U restore_admin -d postgres >/dev/null 2>&1 && break
    sleep 2
  done
  if [[ -s "$dump_path" ]] &&
     gunzip -c "$dump_path" | docker exec -i "$name" psql -U restore_admin -d postgres -v ON_ERROR_STOP=1 -f - >/tmp/"${name}.log" 2>&1 &&
     docker exec "$name" psql -U restore_admin -d postgres -tAc "select 1" >/dev/null 2>&1; then
    status="pass"
    details="restic snapshot restored and postgres dump replayed on separate host"
  else
    details="restore failed during postgres replay"
  fi
else
  details="could not find latest restic snapshot for server=${SERVER_ID}"
fi

completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$CONTROL_REPO/restore-drills"
jq -n \
  --arg version "1" \
  --arg drill_id "$drill_id" \
  --arg server_id "$SERVER_ID" \
  --arg started_at "$started_at" \
  --arg completed_at "$completed_at" \
  --arg status "$status" \
  --arg details "$details" \
  --arg snapshot_id "$snapshot_id" \
  --arg hc "$HC_MONTHLY_SLUG" \
  '{
    version: ($version | tonumber),
    drill_id: $drill_id,
    server_id: $server_id,
    started_at: $started_at,
    completed_at: $completed_at,
    status: $status,
    details: $details,
    restic_snapshot_id: $snapshot_id,
    healthcheck: {slug: $hc}
  }' > "$CONTROL_REPO/restore-drills/latest.json"

git -C "$CONTROL_REPO" add restore-drills/latest.json
if ! git -C "$CONTROL_REPO" diff --cached --quiet; then
  git -C "$CONTROL_REPO" commit -m "Update monthly v2 restore drill ${drill_id}"
  git -C "$CONTROL_REPO" push
fi

if [[ "$status" == "pass" ]]; then
  ping_hc ""
else
  ping_hc "/fail"
  exit 1
fi
