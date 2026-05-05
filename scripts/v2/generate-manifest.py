#!/usr/bin/env python3
"""Generate the canonical v2 VPS control manifest from sanitized backup inputs."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def load_json_lines(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    items: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            items.append(value)
    return items


def parse_services(inventory_dir: Path) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    services: list[dict[str, str]] = []
    scaled_to_zero: list[dict[str, str]] = []
    for item in load_json_lines(inventory_dir / "services.jsonl"):
        service = {
            "name": str(item.get("Name", "")),
            "image": str(item.get("Image", "")),
            "replicas": str(item.get("Replicas", "")),
        }
        if not service["name"]:
            continue
        if service["replicas"].startswith("0/"):
            scaled_to_zero.append(service)
        else:
            services.append(service)
    return sorted(services, key=lambda x: x["name"]), sorted(scaled_to_zero, key=lambda x: x["name"])


def parse_ports(inventory_dir: Path) -> list[dict[str, Any]]:
    path = inventory_dir / "listening-ports.txt"
    if not path.exists():
        return []
    ports: list[dict[str, Any]] = []
    seen: set[tuple[str, str, int]] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip() or line.lower().startswith("netid "):
            continue
        parts = line.split()
        if len(parts) < 5:
            continue
        proto = parts[0]
        local = parts[4]
        if ":" not in local:
            continue
        address, raw_port = local.rsplit(":", 1)
        try:
            port = int(raw_port)
        except ValueError:
            continue
        key = (proto, address, port)
        if key in seen:
            continue
        seen.add(key)
        ports.append({"protocol": proto, "address": address, "port": port})
    return sorted(ports, key=lambda x: (x["port"], x["protocol"], x["address"]))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_tree(path: Path) -> str:
    digest = hashlib.sha256()
    if not path.exists():
        return hashlib.sha256(b"").hexdigest()
    for child in sorted(p for p in path.rglob("*") if p.is_file()):
        rel = child.relative_to(path).as_posix().encode("utf-8")
        digest.update(rel)
        digest.update(b"\0")
        digest.update(sha256_file(child).encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def load_restic_summary(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    summary: dict[str, Any] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("message_type") == "summary":
            summary = event
    return summary


def read_gzip_exists(path: Path) -> bool:
    if not path.exists():
        return False
    try:
        with gzip.open(path, "rb") as handle:
            handle.read(1)
        return True
    except OSError:
        return False


def canonical_hash(manifest: dict[str, Any]) -> str:
    candidate = dict(manifest)
    candidate["manifest_sha256"] = "0" * 64
    encoded = json.dumps(candidate, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backup-id", required=True)
    parser.add_argument("--server-id", required=True)
    parser.add_argument("--job", required=True, choices=["daily", "weekly", "monthly-restore"])
    parser.add_argument("--started-at", required=True)
    parser.add_argument("--completed-at", default=utc_now())
    parser.add_argument("--payload-dir", required=True)
    parser.add_argument("--inventory-dir", required=True)
    parser.add_argument("--restic-summary", required=True)
    parser.add_argument("--repository-alias", required=True)
    parser.add_argument("--retention-status", default="not-run", choices=["not-run", "pass", "fail"])
    parser.add_argument("--weekly-restore-status", default="not-run", choices=["pass", "fail", "not-run"])
    parser.add_argument("--weekly-restore-details", default="")
    parser.add_argument("--monthly-restore-status", default="not-run", choices=["pass", "fail", "not-run"])
    parser.add_argument("--monthly-restore-details", default="")
    parser.add_argument("--volume-names", nargs="*", default=[])
    parser.add_argument("--volumes-backed-up", nargs="*", default=[])
    parser.add_argument("--healthcheck-daily-slug", default="vps-backup-daily")
    parser.add_argument("--healthcheck-weekly-slug", default="vps-backup-weekly")
    parser.add_argument("--healthcheck-monthly-slug", default="vps-restore-monthly")
    parser.add_argument("--error-file", default="")
    parser.add_argument("--warning-file", default="")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    inventory_dir = Path(args.inventory_dir)
    payload_dir = Path(args.payload_dir)
    restic_summary = load_restic_summary(Path(args.restic_summary))
    services, scaled_to_zero = parse_services(inventory_dir)
    ports = parse_ports(inventory_dir)

    errors: list[str] = []
    warnings: list[str] = []
    if args.error_file and Path(args.error_file).exists():
        errors = [line.strip() for line in Path(args.error_file).read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
    if args.warning_file and Path(args.warning_file).exists():
        warnings = [line.strip() for line in Path(args.warning_file).read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]

    postgres_dump = payload_dir / "databases" / "postgres_pg_dumpall.sql.gz"
    if not read_gzip_exists(postgres_dump):
        warnings.append("postgres dump is missing or not a valid gzip stream")

    snapshot_id = str(restic_summary.get("snapshot_id", ""))
    stats = {
        "total_bytes": int(restic_summary.get("total_bytes_processed") or restic_summary.get("total_bytes") or 0),
        "files_new": int(restic_summary.get("files_new") or 0),
        "files_changed": int(restic_summary.get("files_changed") or 0),
        "files_unmodified": int(restic_summary.get("files_unmodified") or 0),
    }
    status = "pass"
    if errors:
        status = "fail"
    elif warnings:
        status = "partial"

    weekly_last_run = args.completed_at if args.weekly_restore_status != "not-run" else None
    monthly_last_run = args.completed_at if args.monthly_restore_status != "not-run" else None

    manifest: dict[str, Any] = {
        "version": 2,
        "backup_id": args.backup_id,
        "server_id": args.server_id,
        "started_at": args.started_at,
        "completed_at": args.completed_at,
        "status": status,
        "job": args.job,
        "restic": {
            "repository_alias": args.repository_alias,
            "snapshot_id": snapshot_id,
            "tags": [f"server={args.server_id}", f"job={args.job}", f"id={args.backup_id}"],
            "stats": stats,
        },
        "retention_policy": {
            "keep_daily": 14,
            "keep_weekly": 8,
            "keep_monthly": 12,
            "last_forget_status": args.retention_status,
        },
        "services": services,
        "scaled_to_zero": scaled_to_zero,
        "ports_listening": ports,
        "volumes_considered": sorted(args.volume_names),
        "volumes_backed_up": sorted(args.volumes_backed_up),
        "restore_tests": {
            "weekly_postgres": {
                "last_run": weekly_last_run,
                "status": args.weekly_restore_status,
                "details": args.weekly_restore_details,
            },
            "monthly_cross_machine": {
                "last_run": monthly_last_run,
                "status": args.monthly_restore_status,
                "details": args.monthly_restore_details,
            },
        },
        "healthchecks": {
            "daily": {"slug": args.healthcheck_daily_slug},
            "weekly": {"slug": args.healthcheck_weekly_slug},
            "monthly": {"slug": args.healthcheck_monthly_slug},
        },
        "errors": errors,
        "warnings": warnings,
        "manifest_sha256": "0" * 64,
        "inventory_sha256": sha256_tree(inventory_dir),
    }
    manifest["manifest_sha256"] = canonical_hash(manifest)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
