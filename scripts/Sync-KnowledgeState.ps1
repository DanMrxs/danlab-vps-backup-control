[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$VaultRoot = "C:\Users\danie\Documents\Obsidian\2ndBrain",
    [string]$GraphifyBuildScript = "C:\Users\danie\graphify-scopes\scripts\build-all.ps1",
    [switch]$SkipGraphRebuild
)

$ErrorActionPreference = "Stop"

$controlRoot = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $controlRoot "manifests\latest.json"
}

function Convert-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return ("{0:N0} B" -f $Bytes)
}

function Read-JsonLines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $items = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line.Trim()) {
            try { $items += ($line | ConvertFrom-Json) } catch {}
        }
    }
    return $items
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Manifest not found: $ManifestPath"
}

$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
$inventoryRoot = Join-Path $controlRoot "inventory\latest"
$services = @(Read-JsonLines -Path (Join-Path $inventoryRoot "services.jsonl"))
$stacks = @(Read-JsonLines -Path (Join-Path $inventoryRoot "stacks.jsonl"))
$volumesPath = Join-Path $inventoryRoot "volumes.txt"
$portsPath = Join-Path $inventoryRoot "listening-ports.txt"

$runningServices = @($services | Where-Object { $_.Replicas -and $_.Replicas -notmatch '^0/0$' } | Sort-Object Name)
$scaledZeroServices = @($services | Where-Object { $_.Replicas -match '^0/0$' } | Sort-Object Name)
$artifactCount = @($manifest.artifacts).Count
$artifactBytes = 0
foreach ($artifact in @($manifest.artifacts)) {
    if ($artifact.encryptedBytes) { $artifactBytes += [double]$artifact.encryptedBytes }
}
$remoteErrorCount = @($manifest.remoteErrors).Count
$volumeCount = if (Test-Path -LiteralPath $volumesPath) { @(Get-Content -LiteralPath $volumesPath).Count } else { 0 }

$updated = (Get-Date).ToString("yyyy-MM-dd")
$notePath = Join-Path $VaultRoot "wiki\entities\danlab-VPS-Backup-State.md"
$noteDir = Split-Path -Parent $notePath
New-Item -ItemType Directory -Force -Path $noteDir | Out-Null

$artifactRows = @($manifest.artifacts | ForEach-Object {
    "| {0} | {1} | {2} |" -f $_.source, $_.encrypted, (Convert-Bytes $_.encryptedBytes)
})
if ($artifactRows.Count -eq 0) { $artifactRows = @("| none | none | 0 B |") }

$runningRows = @($runningServices | Select-Object -First 40 | ForEach-Object {
    "| {0} | {1} | {2} |" -f $_.Name, $_.Replicas, $_.Image
})
if ($runningRows.Count -eq 0) { $runningRows = @("| none |  |  |") }

$zeroRows = @($scaledZeroServices | Select-Object -First 40 | ForEach-Object {
    "| {0} | {1} | {2} |" -f $_.Name, $_.Replicas, $_.Image
})
if ($zeroRows.Count -eq 0) { $zeroRows = @("| none |  |  |") }

$portsBlock = if (Test-Path -LiteralPath $portsPath) {
    (Get-Content -LiteralPath $portsPath | Select-Object -First 80) -join "`n"
}
else {
    "No listening-ports inventory found."
}

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

Generated from GitHub-safe backup manifests and sanitized inventory. This note is safe for LLM/RAG/Graphify use and intentionally excludes secrets, raw database dumps, encrypted binary artifacts, and credential values.

## Latest Backup

| Field | Value |
|---|---|
| Backup ID | $($manifest.backupId) |
| Created UTC | $($manifest.createdAtUtc) |
| Local backup set | $($manifest.local.backupSet) |
| Inventory included | $($manifest.includes.inventory) |
| Databases included | $($manifest.includes.databases) |
| Volumes included | $($manifest.includes.volumes) |
| Encrypted artifacts | $artifactCount |
| Encrypted artifact size | $(Convert-Bytes $artifactBytes) |
| Remote errors | $remoteErrorCount |
| Known Docker volumes | $volumeCount |

## Artifact Summary

| Source | Encrypted artifact | Size |
|---|---|---:|
$($artifactRows -join "`n")

## Running Services

| Service | Replicas | Image |
|---|---:|---|
$($runningRows -join "`n")

## Scaled To Zero

| Service | Replicas | Image |
|---|---:|---|
$($zeroRows -join "`n")

## Listening Ports Snapshot

$(($portsBlock -split "`n" | ForEach-Object { "    $_" }) -join "`n")

## Sync Loop

1. Windows Task Scheduler runs `Run-ScheduledBackup.ps1`.
2. Backup script pulls sanitized inventory and encrypted local artifacts.
3. Manifest and inventory are pushed to the private GitHub control repo.
4. This note is regenerated from `manifests/latest.json` and `inventory/latest`.
5. Scoped Graphify rebuilds `obsidian-wiki` and `danlab-vps-backup-control`.

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
    BackupId = $manifest.backupId
    ArtifactCount = $artifactCount
    RemoteErrors = $remoteErrorCount
    GraphRebuilt = -not [bool]$SkipGraphRebuild
}
