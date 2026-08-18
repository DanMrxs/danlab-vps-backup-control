# Local Staging Retention

The VPS backup controller keeps exactly one newest successful staging copy in
`WORK_ROOT`. This bounds local staging growth while keeping Restic's offsite
retention unchanged at 14 daily, 8 weekly, and 12 monthly snapshots.

A staging directory is eligible for local removal only when all of these checks
pass while the controller holds `/run/lock/vps-control-backup.lock`:

- its manifest has `status=pass`;
- its `restic-backup.json` is a regular file;
- the directory and control files are not symlinks;
- its resolved path is an immediate child of the resolved `WORK_ROOT`;
- its backup ID and snapshot ID have valid formats; and
- exactly one matching offsite Restic snapshot is visible.

Failed, partial, ambiguous, and out-of-root directories are retained for manual
review and do not count as the one successful local copy. Cleanup uses one exact
resolved directory path and never invokes a filesystem, Docker, volume, database,
media, or Restic prune.

The four-GiB capacity forecast remains fixed. Local cleanup is a capacity lever,
not a substitute for forecast reservations. Restic's offsite forget/prune policy
is independent and unchanged.

Before an exceptional manual deletion, capture the exact path, manifest hashes,
snapshot identity, restore proof, controller lock, and before/after disk evidence.
