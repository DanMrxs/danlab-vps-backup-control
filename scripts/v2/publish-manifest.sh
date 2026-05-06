#!/usr/bin/env bash
set -euo pipefail

manifest_path=""
inventory_dir=""
restore_drill_path=""
control_repo="${CONTROL_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

usage() {
  cat <<'EOF'
Usage: publish-manifest.sh --manifest PATH --inventory-dir DIR [--restore-drill PATH]

Copies canonical safe state into the control repo and pushes it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) manifest_path="$2"; shift 2 ;;
    --inventory-dir) inventory_dir="$2"; shift 2 ;;
    --restore-drill) restore_drill_path="$2"; shift 2 ;;
    --control-repo) control_repo="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$manifest_path" && -f "$manifest_path" ]] || { echo "Manifest missing: $manifest_path" >&2; exit 2; }
[[ -n "$inventory_dir" && -d "$inventory_dir" ]] || { echo "Inventory dir missing: $inventory_dir" >&2; exit 2; }
[[ -d "$control_repo/.git" ]] || { echo "Control repo is not a git checkout: $control_repo" >&2; exit 2; }

git -C "$control_repo" fetch origin main
git -C "$control_repo" rebase --autostash origin/main

mkdir -p "$control_repo/manifests" "$control_repo/inventory/v2" "$control_repo/restore-drills"
cp "$manifest_path" "$control_repo/manifest.json"
cp "$manifest_path" "$control_repo/manifests/latest-v2.json"
rm -rf "$control_repo/inventory/v2/latest"
mkdir -p "$control_repo/inventory/v2/latest"
cp -a "$inventory_dir/." "$control_repo/inventory/v2/latest/"

if [[ -n "$restore_drill_path" && -f "$restore_drill_path" ]]; then
  cp "$restore_drill_path" "$control_repo/restore-drills/latest.json"
fi

git -C "$control_repo" add manifest.json manifests/latest-v2.json inventory/v2/latest restore-drills
if git -C "$control_repo" diff --cached --quiet; then
  echo "No v2 manifest changes to publish."
  exit 0
fi

backup_id="$(jq -r '.backup_id' "$manifest_path")"
git -C "$control_repo" commit -m "Update v2 VPS backup manifest ${backup_id}"
git -C "$control_repo" pull --rebase --autostash origin main
git -C "$control_repo" push
