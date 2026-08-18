#!/usr/bin/env bash
set -Eeuo pipefail

mode="daily"
dry_run=0

usage() {
  cat <<'EOF'
Usage: backup-vps.sh [--mode daily|weekly] [--dry-run]

Runs the VPS-side v2 backup flow:
inventory + logical dumps + optional volumes + restic + manifest + GitHub publish + Healthchecks.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$mode" != "daily" && "$mode" != "weekly" ]]; then
  echo "Invalid mode: $mode" >&2
  exit 2
fi

CONFIG_FILE="${VPS_CONTROL_CONFIG:-/etc/vps-control/config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

SERVER_ID="${SERVER_ID:-$(hostname -s)}"
CONTROL_REPO="${CONTROL_REPO:-/opt/vps-backup-control}"
WORK_ROOT="${WORK_ROOT:-/var/backups/vps-control/work}"
LOG_ROOT="${LOG_ROOT:-/var/log/vps-control}"
RESTIC_ENV_FILE="${RESTIC_ENV_FILE:-/etc/vps-control/restic.env}"
HEALTHCHECKS_ENV_FILE="${HEALTHCHECKS_ENV_FILE:-/etc/vps-control/healthchecks.env}"
RESTIC_REPOSITORY_ALIAS="${RESTIC_REPOSITORY_ALIAS:-hetzner-storage-box}"
POSTGRES_CONTAINER_FILTER="${POSTGRES_CONTAINER_FILTER:-postgres_postgres}"
PGVECTOR_CONTAINER_FILTER="${PGVECTOR_CONTAINER_FILTER:-pgvector_pgvector}"
REDIS_CONTAINER_FILTER="${REDIS_CONTAINER_FILTER:-redis_redis}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
PGVECTOR_USER="${PGVECTOR_USER:-postgres}"
RESTORE_POSTGRES_IMAGE="${RESTORE_POSTGRES_IMAGE:-postgres:14}"
CONTENTOS_DATABASE="${CONTENTOS_DATABASE:-content_os}"
CONTENTOS_DATABASE_DUMP="${CONTENTOS_DATABASE_DUMP:-contentos_content_os.dump}"
VOLUME_NAMES="${VOLUME_NAMES:-baserow_data contentos-tools_searxng-config minio_data portainer_data volume_swarm_certificates}"

if [[ -f "$HEALTHCHECKS_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$HEALTHCHECKS_ENV_FILE"
fi

HC_DAILY_SLUG="${HC_DAILY_SLUG:-vps-backup-daily}"
HC_WEEKLY_SLUG="${HC_WEEKLY_SLUG:-vps-backup-weekly}"
HC_MONTHLY_SLUG="${HC_MONTHLY_SLUG:-vps-restore-monthly}"

healthcheck_url=""
if [[ "$mode" == "daily" ]]; then
  healthcheck_url="${HC_DAILY_URL:-}"
else
  healthcheck_url="${HC_WEEKLY_URL:-}"
fi

backup_id="$(date -u +%Y%m%dT%H%M%SZ)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
workdir=""
log_path=""
errors_file=""
warnings_file=""
restore_status="not-run"
restore_details=""
retention_status="not-run"

ping_healthcheck() {
  local suffix="${1:-}"
  [[ -n "$healthcheck_url" ]] || return 0
  curl -fsS -m 10 "${healthcheck_url}${suffix}" >/dev/null || true
}

record_error() {
  echo "$*" | tee -a "$errors_file" >&2
}

record_warning() {
  echo "$*" | tee -a "$warnings_file" >&2
}

on_error() {
  local exit_code=$?
  if [[ -n "${errors_file:-}" ]]; then
    echo "backup job failed with exit code ${exit_code}" >> "$errors_file"
  fi
  ping_healthcheck "/fail"
  exit "$exit_code"
}

trap on_error ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "Required command not found: $1" >&2; exit 127; }
}

docker_container_by_filter() {
  local filter="$1"
  docker ps --filter "name=${filter}" --format '{{.Names}}' | head -n 1
}

safe_name() {
  echo "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

collect_inventory() {
  local inventory_dir="$1"
  mkdir -p "$inventory_dir"
  {
    echo "generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "hostname=$(hostname)"
    uname -a
    docker info --format 'docker={{.ServerVersion}} swarm={{.Swarm.LocalNodeState}}'
    df -h /
    free -h
  } > "$inventory_dir/system.txt" 2>&1 || true
  docker service ls --format '{{json .}}' | sort > "$inventory_dir/services.jsonl" || true
  docker stack ls --format '{{json .}}' | sort > "$inventory_dir/stacks.jsonl" || true
  docker ps --format '{{json .}}' | sort > "$inventory_dir/containers.jsonl" || true
  docker volume ls --format '{{.Name}}' | sort > "$inventory_dir/volumes.txt" || true
  docker network ls --format '{{json .}}' | sort > "$inventory_dir/networks.jsonl" || true
  ss -tuln > "$inventory_dir/listening-ports.txt" || true
}

dump_databases() {
  local db_dir="$1"
  mkdir -p "$db_dir"
  local pgc pgvc redisc

  pgc="$(docker_container_by_filter "$POSTGRES_CONTAINER_FILTER")"
  if [[ -n "$pgc" ]]; then
    docker exec "$pgc" sh -lc "pg_dumpall -U '$POSTGRES_USER'" | gzip -c > "$db_dir/postgres_pg_dumpall.sql.gz" || record_error "postgres dump failed"
    docker exec "$pgc" pg_dump \
      -U "$POSTGRES_USER" \
      -d "$CONTENTOS_DATABASE" \
      --format=custom \
      --no-owner \
      --no-privileges \
      > "$db_dir/$CONTENTOS_DATABASE_DUMP" || record_error "ContentOS database dump failed"
  else
    record_error "postgres container not found by filter ${POSTGRES_CONTAINER_FILTER}"
  fi

  pgvc="$(docker_container_by_filter "$PGVECTOR_CONTAINER_FILTER")"
  if [[ -n "$pgvc" ]]; then
    docker exec "$pgvc" sh -lc "pg_dumpall -U '$PGVECTOR_USER'" | gzip -c > "$db_dir/pgvector_pg_dumpall.sql.gz" || record_error "pgvector dump failed"
  else
    record_warning "pgvector container not found by filter ${PGVECTOR_CONTAINER_FILTER}"
  fi

  redisc="$(docker_container_by_filter "$REDIS_CONTAINER_FILTER")"
  if [[ -n "$redisc" ]]; then
    docker exec "$redisc" sh -lc "redis-cli SAVE" >/dev/null 2>&1 || record_warning "redis SAVE returned non-zero"
    docker cp "$redisc:/data/dump.rdb" "$db_dir/redis_dump.rdb" && gzip -f "$db_dir/redis_dump.rdb" || record_error "redis dump copy failed"
  else
    record_warning "redis container not found by filter ${REDIS_CONTAINER_FILTER}"
  fi
}

backup_volumes() {
  local volume_dir="$1"
  mkdir -p "$volume_dir"
  local backed=()
  for vol in $VOLUME_NAMES; do
    if docker volume inspect "$vol" >/dev/null 2>&1; then
      local path="/var/lib/docker/volumes/${vol}/_data"
      local out="$volume_dir/$(safe_name "$vol").tgz"
      if [[ -d "$path" ]] && tar -C "$path" -czf "$out" .; then
        backed+=("$vol")
      else
        record_warning "volume backup failed for ${vol}"
      fi
    else
      record_warning "volume not found: ${vol}"
    fi
  done
  printf '%s\n' "${backed[@]}" > "$workdir/volumes-backed-up.txt"
}

run_weekly_restore_test() {
  local dump_path="$1"
  local contentos_dump_path="$2"
  local name="vps-restore-${backup_id}"
  if [[ ! -s "$dump_path" || ! -s "$contentos_dump_path" ]]; then
    restore_status="fail"
    restore_details="postgres or ContentOS dump missing"
    return 0
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run --rm --name "$name" -e POSTGRES_USER=restore_admin -e POSTGRES_PASSWORD=restore -d "$RESTORE_POSTGRES_IMAGE" >/dev/null
  for _ in $(seq 1 45); do
    if docker exec "$name" pg_isready -U restore_admin -d postgres >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  if gunzip -c "$dump_path" | docker exec -i "$name" psql -U restore_admin -d postgres -v ON_ERROR_STOP=1 -f - >/tmp/"${name}.restore.log" 2>&1 &&
     docker exec "$name" psql -U restore_admin -d postgres -tAc "select 1" >/dev/null 2>&1 &&
     docker exec "$name" createdb -U restore_admin contentos_restore_probe >/dev/null 2>&1 &&
     docker exec -i "$name" pg_restore -U restore_admin -d contentos_restore_probe --exit-on-error --no-owner --no-privileges < "$contentos_dump_path" >>/tmp/"${name}.restore.log" 2>&1 &&
     docker exec "$name" psql -U restore_admin -d contentos_restore_probe -tAc "select (count(*) > 0)::int from information_schema.tables where table_schema = 'public'" | grep -qx 1; then
    restore_status="pass"
    restore_details="postgres pg_dumpall and dedicated ContentOS dump restored into disposable container"
  else
    restore_status="fail"
    restore_details="postgres or ContentOS restore failed; see VPS logs"
    record_error "weekly postgres/ContentOS restore smoke test failed"
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
}

cleanup_staging_dirs() {
  local keep_success=1
  local -a staging_dirs=()
  local candidate candidate_id candidate_snapshot resolved work_resolved status
  local successful_seen=0
  local snapshot_matches=0

  work_resolved="$(realpath -e -- "$WORK_ROOT")"
  mapfile -t staging_dirs < <(ls -1dt "$WORK_ROOT"/*/ 2>/dev/null)
  for candidate in "${staging_dirs[@]}"; do
    candidate="${candidate%/}"
    status="$(jq -r '.status // empty' "$candidate/manifest.json" 2>/dev/null || true)"
    if [[ "$status" != "pass" || ! -f "$candidate/restic-backup.json" ||
          -L "$candidate" || -L "$candidate/manifest.json" || -L "$candidate/restic-backup.json" ]]; then
      echo "cleanup: keeping ${candidate} (not an exact successful local staging copy)"
      continue
    fi

    successful_seen=$((successful_seen + 1))
    if [[ "$successful_seen" -le "$keep_success" ]]; then
      echo "cleanup: keeping newest successful local staging dir ${candidate}"
      continue
    fi

    resolved="$(realpath -e -- "$candidate")"
    if [[ "$(dirname -- "$resolved")" != "$work_resolved" ]]; then
      record_warning "cleanup: refusing path outside exact work root ${candidate}"
      continue
    fi
    candidate_id="$(jq -r '.backup_id // empty' "$candidate/manifest.json")"
    candidate_snapshot="$(jq -r '.restic.snapshot_id // empty' "$candidate/manifest.json")"
    if [[ ! "$candidate_id" =~ ^[0-9]{8}T[0-9]{6}Z$ || ! "$candidate_snapshot" =~ ^[0-9a-f]{8,64}$ ]]; then
      record_warning "cleanup: refusing ${candidate}; invalid backup or snapshot identity"
      continue
    fi
    snapshot_matches="$(restic snapshots --json --tag "id=${candidate_id}" 2>/dev/null |
      jq --arg snapshot "$candidate_snapshot" '[.[] | select((.id | startswith($snapshot)))] | length' 2>/dev/null || echo 0)"
    if [[ "$snapshot_matches" != "1" ]]; then
      record_warning "cleanup: keeping ${candidate}; exact offsite snapshot is not uniquely visible"
      continue
    fi

    if rm -rf --one-file-system -- "$resolved"; then
      echo "cleanup: removed exact older successful staging dir ${resolved} (offsite snapshot ${candidate_snapshot})"
    else
      record_warning "cleanup: failed to remove staging dir ${resolved}"
    fi
  done
  echo "cleanup: local successful staging retention keep=${keep_success}; offsite retention unchanged"
}

main() {
  require_command docker
  require_command jq
  require_command python3
  require_command restic
  require_command git
  require_command curl

  if [[ "$dry_run" -eq 1 ]]; then
    echo "Dry run OK. Mode=${mode} server=${SERVER_ID} repo=${CONTROL_REPO}"
    return 0
  fi

  [[ -f "$RESTIC_ENV_FILE" ]] || { echo "Missing restic env file: $RESTIC_ENV_FILE" >&2; exit 2; }
  set -a
  # shellcheck disable=SC1090
  source "$RESTIC_ENV_FILE"
  set +a

  mkdir -p "$WORK_ROOT" "$LOG_ROOT" /run/lock
  workdir="$(mktemp -d "${WORK_ROOT}/${backup_id}.XXXXXX")"
  log_path="${LOG_ROOT}/${backup_id}-${mode}.log"
  errors_file="$workdir/errors.txt"
  warnings_file="$workdir/warnings.txt"
  : > "$errors_file"
  : > "$warnings_file"

  exec > >(tee -a "$log_path") 2>&1
  ping_healthcheck "/start"

  (
    flock -n 9 || { echo "Another v2 backup is already running." >&2; exit 3; }

    mkdir -p "$workdir/payload/databases" "$workdir/payload/inventory" "$workdir/payload/volumes"
    collect_inventory "$workdir/payload/inventory"
    dump_databases "$workdir/payload/databases"
    if [[ "$mode" == "weekly" ]]; then
      backup_volumes "$workdir/payload/volumes"
      run_weekly_restore_test \
        "$workdir/payload/databases/postgres_pg_dumpall.sql.gz" \
        "$workdir/payload/databases/$CONTENTOS_DATABASE_DUMP"
    else
      : > "$workdir/volumes-backed-up.txt"
    fi

    (
      cd "$workdir"
      restic backup payload \
        --tag "server=${SERVER_ID}" \
        --tag "job=${mode}" \
        --tag "id=${backup_id}" \
        --json > "$workdir/restic-backup.json"
    )

    if [[ "$mode" == "weekly" ]]; then
      if restic forget --tag "server=${SERVER_ID}" --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune; then
        retention_status="pass"
      else
        retention_status="fail"
        record_error "restic retention forget/prune failed"
      fi
    fi

    completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mapfile -t volumes_backed_up < "$workdir/volumes-backed-up.txt"

    python3 "$CONTROL_REPO/scripts/v2/generate-manifest.py" \
      --backup-id "$backup_id" \
      --server-id "$SERVER_ID" \
      --job "$mode" \
      --started-at "$started_at" \
      --completed-at "$completed_at" \
      --payload-dir "$workdir/payload" \
      --inventory-dir "$workdir/payload/inventory" \
      --restic-summary "$workdir/restic-backup.json" \
      --repository-alias "$RESTIC_REPOSITORY_ALIAS" \
      --retention-status "$retention_status" \
      --weekly-restore-status "$restore_status" \
      --weekly-restore-details "$restore_details" \
      --volume-names $VOLUME_NAMES \
      --volumes-backed-up "${volumes_backed_up[@]}" \
      --healthcheck-daily-slug "$HC_DAILY_SLUG" \
      --healthcheck-weekly-slug "$HC_WEEKLY_SLUG" \
      --healthcheck-monthly-slug "$HC_MONTHLY_SLUG" \
      --error-file "$errors_file" \
      --warning-file "$warnings_file" \
      --output "$workdir/manifest.json"

    python3 "$CONTROL_REPO/scripts/v2/validate-manifest.py" \
      --schema "$CONTROL_REPO/schema/manifest.v2.schema.json" \
      --manifest "$workdir/manifest.json"

    "$CONTROL_REPO/scripts/v2/publish-manifest.sh" \
      --control-repo "$CONTROL_REPO" \
      --manifest "$workdir/manifest.json" \
      --inventory-dir "$workdir/payload/inventory"
  ) 9>/run/lock/vps-control-backup.lock

  manifest_status="$(jq -r '.status' "$workdir/manifest.json")"
  if [[ "$manifest_status" == "pass" ]]; then
    ping_healthcheck ""
    (
      flock -n 9 || { echo "cleanup: backup controller lock busy; skipping local retention"; exit 0; }
      cleanup_staging_dirs
    ) 9>/run/lock/vps-control-backup.lock || record_warning "staging cleanup failed; backup result unaffected" || true
  else
    ping_healthcheck "/fail"
    echo "Backup completed with manifest status=${manifest_status}; treating as failed for scheduler/monitoring." >&2
    exit 1
  fi
}

main "$@"
