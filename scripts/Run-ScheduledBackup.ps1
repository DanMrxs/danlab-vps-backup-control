[CmdletBinding()]
param(
    [ValidateSet("Inventory", "Database", "Full")]
    [string]$Mode = "Database",
    [string]$BackupRoot = "C:\Backups\danlab-vps",
    [switch]$RestoreSmokeTest
)

$ErrorActionPreference = "Stop"
$controlRoot = Split-Path -Parent $PSScriptRoot
$logRoot = Join-Path $BackupRoot "logs"
$lockPath = Join-Path $BackupRoot ".backup.lock"
New-Item -ItemType Directory -Force -Path $BackupRoot, $logRoot | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $logRoot "$timestamp-$Mode.log"

function New-BackupLock {
    if (Test-Path -LiteralPath $lockPath) {
        $existing = Get-Item -LiteralPath $lockPath
        if ($existing.LastWriteTime -gt (Get-Date).AddHours(-12)) {
            throw "Another backup appears to be running. Lock file: $lockPath"
        }
        Remove-Item -LiteralPath $lockPath -Force
    }
    New-Item -ItemType File -Path $lockPath -Value "$PID $timestamp $Mode" -ErrorAction Stop | Out-Null
}

function Invoke-BackupScript {
    param([string]$Script, [string[]]$Arguments)

    & powershell -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Script failed with exit code $LASTEXITCODE"
    }
}

Start-Transcript -Path $logPath -Append | Out-Null
try {
    New-BackupLock
    Write-Host "Starting danlab VPS scheduled backup. Mode=$Mode Time=$((Get-Date).ToString('o'))"

    $backupScript = Join-Path $PSScriptRoot "Backup-Vps.ps1"
    $inventoryScript = Join-Path $PSScriptRoot "Inventory-Vps.ps1"
    $restoreScript = Join-Path $PSScriptRoot "Restore-Smoke-Test.ps1"
    $syncScript = Join-Path $PSScriptRoot "Sync-KnowledgeState.ps1"

    switch ($Mode) {
        "Inventory" {
            Invoke-BackupScript -Script $inventoryScript -Arguments @("-BackupRoot", $BackupRoot)
        }
        "Database" {
            Invoke-BackupScript -Script $backupScript -Arguments @("-BackupRoot", $BackupRoot)
        }
        "Full" {
            Invoke-BackupScript -Script $backupScript -Arguments @("-BackupRoot", $BackupRoot, "-IncludeVolumes")
        }
    }

    $latestManifest = Join-Path $controlRoot "manifests\latest.json"
    if ($RestoreSmokeTest -and (Test-Path -LiteralPath $latestManifest)) {
        $latest = Get-Content -Raw -LiteralPath $latestManifest | ConvertFrom-Json
        if ($latest.local.backupSet) {
            Invoke-BackupScript -Script $restoreScript -Arguments @("-BackupSet", $latest.local.backupSet)
        }
    }

    if (Test-Path -LiteralPath $syncScript) {
        Invoke-BackupScript -Script $syncScript -Arguments @()
    }

    if (Test-Path -LiteralPath (Join-Path $controlRoot ".git")) {
        Push-Location $controlRoot
        try {
            & git add manifests inventory
            if ((git status --short).Trim()) {
                & git commit -m "Update danlab scheduled backup manifest"
                & git push
            }
        }
        finally {
            Pop-Location
        }
    }

    Write-Host "Completed danlab VPS scheduled backup. Mode=$Mode Time=$((Get-Date).ToString('o'))"
}
finally {
    if (Test-Path -LiteralPath $lockPath) {
        Remove-Item -LiteralPath $lockPath -Force
    }
    Stop-Transcript | Out-Null
}
