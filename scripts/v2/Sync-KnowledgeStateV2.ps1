[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$VaultRoot = "C:\Users\danie\Documents\Obsidian\2ndBrain",
    [string]$GraphifyBuildScript = "C:\Users\danie\graphify-scopes\scripts\build-all.ps1",
    [switch]$SkipGraphRebuild
)

$ErrorActionPreference = "Stop"

$controlRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $controlRoot "manifest.json"
}
$schemaPath = Join-Path $controlRoot "schema\manifest.v2.schema.json"
$validator = Join-Path $PSScriptRoot "validate-manifest.py"

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "v2 manifest not found: $ManifestPath"
}
if (-not (Test-Path -LiteralPath $schemaPath)) {
    throw "v2 schema not found: $schemaPath"
}

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    $python = Get-Command python3 -ErrorAction SilentlyContinue
}
if (-not $python) {
    throw "Python is required to validate the v2 manifest."
}

& $python.Source $validator --schema $schemaPath --manifest $ManifestPath
if ($LASTEXITCODE -ne 0) {
    throw "v2 manifest validation failed; refusing to update Obsidian."
}

$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
if ($manifest.version -ne 2) {
    throw "Expected manifest version 2; refusing to update Obsidian."
}
$manifestSha256 = $manifest.manifest_sha256
$inventorySha256 = $manifest.inventory_sha256

function Convert-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return ("{0:N0} B" -f $Bytes)
}

$updated = (Get-Date).ToString("yyyy-MM-dd")
$notePath = Join-Path $VaultRoot "wiki\entities\danlab-VPS-Backup-State.md"
$noteDir = Split-Path -Parent $notePath
New-Item -ItemType Directory -Force -Path $noteDir | Out-Null

$serviceRows = @($manifest.services | Select-Object -First 40 | ForEach-Object {
    "| {0} | {1} | {2} |" -f $_.name, $_.replicas, $_.image
})
if ($serviceRows.Count -eq 0) { $serviceRows = @("| none | | |") }

$zeroRows = @($manifest.scaled_to_zero | Select-Object -First 40 | ForEach-Object {
    "| {0} | {1} | {2} |" -f $_.name, $_.replicas, $_.image
})
if ($zeroRows.Count -eq 0) { $zeroRows = @("| none | | |") }

$portRows = @($manifest.ports_listening | Sort-Object port, protocol | ForEach-Object {
    "| {0} | {1} | {2} |" -f $_.protocol, $_.address, $_.port
})
if ($portRows.Count -eq 0) { $portRows = @("| none | | |") }

$markdown = @"
---
type: entity
tags: [infrastructure, backup, rag, graphify, vps]
aliases: [danlab backup state, VPS backup state, danlab RAG sync]
related: [danlab-VPS, Graphify, Scoped-Graph-System-Design-Accelerator]
status: active
updated: $updated
---

# danlab VPS Backup State

Generated from the canonical v2 `manifest.json`. This note is a derived view and must not be edited by hand.

## Canonical State

| Field | Value |
|---|---|
| Backup ID | $($manifest.backup_id) |
| Status | $($manifest.status) |
| Job | $($manifest.job) |
| Started UTC | $($manifest.started_at) |
| Completed UTC | $($manifest.completed_at) |
| Restic repository | $($manifest.restic.repository_alias) |
| Restic snapshot | $($manifest.restic.snapshot_id) |
| Restic total bytes | $(Convert-Bytes $manifest.restic.stats.total_bytes) |
| Manifest checksum | $manifestSha256 |
| Inventory checksum | $inventorySha256 |

## Restore Tests

| Test | Status | Last run | Details |
|---|---|---|---|
| Weekly Postgres | $($manifest.restore_tests.weekly_postgres.status) | $($manifest.restore_tests.weekly_postgres.last_run) | $($manifest.restore_tests.weekly_postgres.details) |
| Monthly Cross-machine | $($manifest.restore_tests.monthly_cross_machine.status) | $($manifest.restore_tests.monthly_cross_machine.last_run) | $($manifest.restore_tests.monthly_cross_machine.details) |

## Running Services

| Service | Replicas | Image |
|---|---:|---|
$($serviceRows -join "`n")

## Scaled To Zero

| Service | Replicas | Image |
|---|---:|---|
$($zeroRows -join "`n")

## Listening Ports

| Protocol | Address | Port |
|---|---|---:|
$($portRows -join "`n")

## Sync Rule

1. VPS-side systemd timer runs the v2 backup script.
2. restic stores encrypted off-site snapshots on Hetzner Storage Box.
3. The backup script publishes the canonical `manifest.json` to GitHub.
4. This note is regenerated only after schema and checksum validation pass.
5. Graphify reads the control repo, schema, manifest, runbooks, and this generated note.

## Links

- [[danlab-VPS]] -- VPS entity and operating context
- [[Graphify]] -- generated design map layer
- [[Scoped-Graph-System-Design-Accelerator]] -- scoped graph operating model
"@

Set-Content -LiteralPath $notePath -Value $markdown -Encoding UTF8

if (-not $SkipGraphRebuild) {
    if (-not (Test-Path -LiteralPath $GraphifyBuildScript)) {
        throw "Graphify build script not found: $GraphifyBuildScript"
    }
    & $GraphifyBuildScript -Scope @("obsidian-wiki", "danlab-vps-backup-control")
}

[pscustomobject]@{
    NotePath = $notePath
    BackupId = $manifest.backup_id
    ManifestSha256 = $manifest.manifest_sha256
    GraphRebuilt = -not [bool]$SkipGraphRebuild
}
