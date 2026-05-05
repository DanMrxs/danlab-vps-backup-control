#!/usr/bin/env python3
"""Validate a v2 manifest against schema and its embedded checksum."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


def canonical_hash(manifest: dict[str, Any]) -> str:
    candidate = dict(manifest)
    candidate["manifest_sha256"] = "0" * 64
    encoded = json.dumps(candidate, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schema", required=True)
    parser.add_argument("--manifest", required=True)
    args = parser.parse_args()

    schema = json.loads(Path(args.schema).read_text(encoding="utf-8"))
    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))

    try:
        import jsonschema
    except ImportError:
        print("python jsonschema package is required for strict manifest validation", file=sys.stderr)
        return 2

    jsonschema.validate(instance=manifest, schema=schema)
    expected = canonical_hash(manifest)
    actual = manifest.get("manifest_sha256")
    if actual != expected:
        print(f"manifest_sha256 mismatch: expected {expected}, got {actual}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
