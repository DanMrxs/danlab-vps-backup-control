[CmdletBinding()]
param(
    [string]$SshHost = "danlab-vps",
    [string]$BackupRoot = "C:\Backups\danlab-vps",
    [string]$KeyPath = "$env:USERPROFILE\.danlab-backup\backup-key.dpapi",
    [switch]$SkipDatabases,
    [switch]$IncludeVolumes,
    [string[]]$VolumeNames = @(
        "baserow_data",
        "chatwoot_data",
        "contentos-tools_searxng-config",
        "evolutionv2_instances",
        "minio_data",
        "portainer_data",
        "volume_swarm_certificates"
    ),
    [switch]$KeepRemote
)

$ErrorActionPreference = "Stop"
$controlRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $controlRoot "lib\DanlabBackup.psm1"
Import-Module $modulePath -Force

function Get-LocalRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $baseFull = [System.IO.Path]::GetFullPath($BasePath)
    if (-not $baseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $baseFull += [System.IO.Path]::DirectorySeparatorChar
    }
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
    $baseUri = New-Object System.Uri($baseFull)
    $targetUri = New-Object System.Uri($targetFull)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

Initialize-DanlabBackupKey -KeyPath $KeyPath | Out-Null

$backupId = Get-Date -Format "yyyyMMdd-HHmmss"
$createdAt = (Get-Date).ToUniversalTime().ToString("o")
$setDir = Join-Path $BackupRoot $backupId
$rawDir = Join-Path $setDir "payload"
$manifestDir = Join-Path $controlRoot "manifests"
$inventoryRoot = Join-Path $controlRoot "inventory"
New-Item -ItemType Directory -Force -Path $setDir, $rawDir, $manifestDir, $inventoryRoot | Out-Null

$remoteDir = "/root/backups/danlab-vps/$backupId"
$includeDatabasesFlag = if ($SkipDatabases) { "0" } else { "1" }
$includeVolumesFlag = if ($IncludeVolumes) { "1" } else { "0" }
$volumeList = ($VolumeNames | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join " "

$remoteScript = @"
set -Eeuo pipefail
remote_dir="$remoteDir"
include_databases="$includeDatabasesFlag"
include_volumes="$includeVolumesFlag"
volume_names="$volumeList"

rm -rf "`$remote_dir"
mkdir -p "`$remote_dir/inventory" "`$remote_dir/databases" "`$remote_dir/volumes" "`$remote_dir/errors"

{
  echo "generated_at_utc=$createdAt"
  echo "hostname=`$(hostname)"
  echo "whoami=`$(whoami)"
  uptime
  echo "--- docker info ---"
  docker info --format 'docker={{.ServerVersion}} swarm={{.Swarm.LocalNodeState}}'
  echo "--- docker nodes ---"
  docker node ls --format '{{.Hostname}} {{.Status}} {{.Availability}} {{.ManagerStatus}}'
  echo "--- disk ---"
  df -h /
  echo "--- memory ---"
  free -h
} > "`$remote_dir/inventory/system.txt" 2>&1

docker service ls --format '{{json .}}' | sort > "`$remote_dir/inventory/services.jsonl"
docker stack ls --format '{{json .}}' | sort > "`$remote_dir/inventory/stacks.jsonl"
docker volume ls --format '{{.Name}}' | sort > "`$remote_dir/inventory/volumes.txt"
docker network ls --format '{{json .}}' | sort > "`$remote_dir/inventory/networks.jsonl"
docker ps --format '{{json .}}' | sort > "`$remote_dir/inventory/containers.jsonl"
ss -tuln > "`$remote_dir/inventory/listening-ports.txt" || true

if [ "`$include_databases" = "1" ]; then
  pgc=`$(docker ps --filter name=postgres_postgres --format '{{.Names}}' | head -1)
  if [ -n "`$pgc" ]; then
    if docker exec "`$pgc" sh -lc 'pg_dumpall -U postgres' | gzip -c > "`$remote_dir/databases/postgres_pg_dumpall.sql.gz"; then
      echo ok > "`$remote_dir/databases/postgres_pg_dumpall.ok"
    else
      rm -f "`$remote_dir/databases/postgres_pg_dumpall.sql.gz"
      echo failed > "`$remote_dir/errors/postgres_pg_dumpall.error"
    fi
  else
    echo missing_container > "`$remote_dir/errors/postgres_pg_dumpall.error"
  fi

  pgvc=`$(docker ps --filter name=pgvector_pgvector --format '{{.Names}}' | head -1)
  if [ -n "`$pgvc" ]; then
    if docker exec "`$pgvc" sh -lc 'pg_dumpall -U postgres' | gzip -c > "`$remote_dir/databases/pgvector_pg_dumpall.sql.gz"; then
      echo ok > "`$remote_dir/databases/pgvector_pg_dumpall.ok"
    else
      rm -f "`$remote_dir/databases/pgvector_pg_dumpall.sql.gz"
      echo failed > "`$remote_dir/errors/pgvector_pg_dumpall.error"
    fi
  else
    echo missing_container > "`$remote_dir/errors/pgvector_pg_dumpall.error"
  fi

  redisc=`$(docker ps --filter name=redis_redis --format '{{.Names}}' | head -1)
  if [ -n "`$redisc" ]; then
    docker exec "`$redisc" sh -lc 'redis-cli SAVE' >/dev/null 2>&1 || true
    if docker cp "`$redisc:/data/dump.rdb" "`$remote_dir/databases/redis_dump.rdb"; then
      gzip -f "`$remote_dir/databases/redis_dump.rdb"
      echo ok > "`$remote_dir/databases/redis_dump.ok"
    else
      echo failed > "`$remote_dir/errors/redis_dump.error"
    fi
  else
    echo missing_container > "`$remote_dir/errors/redis_dump.error"
  fi
fi

if [ "`$include_volumes" = "1" ]; then
  for vol in `$volume_names; do
    if docker volume inspect "`$vol" >/dev/null 2>&1; then
      data_path="/var/lib/docker/volumes/`$vol/_data"
      if [ -d "`$data_path" ]; then
        if tar -C "`$data_path" -czf "`$remote_dir/volumes/`$vol.tgz" .; then
          echo ok > "`$remote_dir/volumes/`$vol.ok"
        else
          rm -f "`$remote_dir/volumes/`$vol.tgz"
          echo failed > "`$remote_dir/errors/volume-`$vol.error"
        fi
      else
        echo missing_data_path > "`$remote_dir/errors/volume-`$vol.error"
      fi
    else
      echo missing_volume > "`$remote_dir/errors/volume-`$vol.error"
    fi
  done
fi

find "`$remote_dir" -type f -printf '%P\t%s\n' | sort > "`$remote_dir/inventory/remote-files.tsv"
"@

$tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "danlab-backup-$backupId.sh"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tempScript, ($remoteScript -replace "`r`n", "`n"), $utf8NoBom)

try {
    Invoke-DanlabNative -FilePath "scp" -ArgumentList @($tempScript, "$SshHost`:/tmp/danlab-backup-$backupId.sh") -ErrorMessage "Failed to copy remote backup script."
    Invoke-DanlabNative -FilePath "ssh" -ArgumentList @($SshHost, "bash /tmp/danlab-backup-$backupId.sh") -ErrorMessage "Remote backup script failed."
    Invoke-DanlabNative -FilePath "scp" -ArgumentList @("-r", "$SshHost`:$remoteDir/.", $rawDir) -ErrorMessage "Failed to pull remote backup payload."
    if (-not $KeepRemote) {
        Invoke-DanlabNative -FilePath "ssh" -ArgumentList @($SshHost, "rm -rf '$remoteDir' '/tmp/danlab-backup-$backupId.sh'") -ErrorMessage "Failed to remove remote temporary backup files."
    }
}
finally {
    if (Test-Path -LiteralPath $tempScript) {
        Remove-Item -LiteralPath $tempScript -Force
    }
}

$artifactRecords = @()
$dataFiles = Get-ChildItem -LiteralPath $rawDir -Recurse -File |
    Where-Object { $_.Name -match '\.(sql\.gz|rdb\.gz|tgz)$' }

foreach ($file in $dataFiles) {
    $relativePlain = Get-LocalRelativePath -BasePath $rawDir -TargetPath $file.FullName
    $plainHash = Get-DanlabFileSha256 -Path $file.FullName
    $plainSize = $file.Length
    $encryptedPath = "$($file.FullName).enc"
    Protect-DanlabBackupFile -InputPath $file.FullName -OutputPath $encryptedPath -KeyPath $KeyPath -DeleteInput | Out-Null
    $encryptedItem = Get-Item -LiteralPath $encryptedPath
    $artifactRecords += [ordered]@{
        source = $relativePlain
        encrypted = Get-LocalRelativePath -BasePath $rawDir -TargetPath $encryptedPath
        plaintextSha256 = $plainHash
        plaintextBytes = $plainSize
        encryptedSha256 = Get-DanlabFileSha256 -Path $encryptedPath
        encryptedBytes = $encryptedItem.Length
    }
}

$inventoryRecords = @(Get-ChildItem -LiteralPath (Join-Path $rawDir "inventory") -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
        path = Get-LocalRelativePath -BasePath $rawDir -TargetPath $_.FullName
        bytes = $_.Length
        sha256 = Get-DanlabFileSha256 -Path $_.FullName
    }
})

$errorRecords = @(Get-ChildItem -LiteralPath (Join-Path $rawDir "errors") -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
        path = Get-LocalRelativePath -BasePath $rawDir -TargetPath $_.FullName
        value = (Get-Content -Raw -LiteralPath $_.FullName).Trim()
    }
})

$manifest = [ordered]@{
    version = 1
    backupId = $backupId
    createdAtUtc = $createdAt
    source = [ordered]@{
        sshHost = $SshHost
        remoteDir = if ($KeepRemote) { $remoteDir } else { $null }
    }
    local = [ordered]@{
        backupSet = $setDir
        payload = $rawDir
        keyPath = $KeyPath
    }
    includes = [ordered]@{
        inventory = $true
        databases = -not [bool]$SkipDatabases
        volumes = [bool]$IncludeVolumes
        volumeNames = @($VolumeNames)
    }
    artifacts = @($artifactRecords)
    inventory = @($inventoryRecords)
    remoteErrors = @($errorRecords)
}

$manifestPath = Join-Path $setDir "manifest.json"
$repoManifestPath = Join-Path $manifestDir "$backupId.json"
$latestManifestPath = Join-Path $manifestDir "latest.json"
$repoInventoryPath = Join-Path $inventoryRoot $backupId
$latestInventoryPath = Join-Path $inventoryRoot "latest"
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $repoManifestPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $latestManifestPath -Encoding UTF8

if (Test-Path -LiteralPath (Join-Path $rawDir "inventory")) {
    if (Test-Path -LiteralPath $repoInventoryPath) {
        Remove-Item -LiteralPath $repoInventoryPath -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $rawDir "inventory") -Destination $repoInventoryPath -Recurse
    if (Test-Path -LiteralPath $latestInventoryPath) {
        Remove-Item -LiteralPath $latestInventoryPath -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $rawDir "inventory") -Destination $latestInventoryPath -Recurse
}

[pscustomobject]@{
    BackupId = $backupId
    BackupSet = $setDir
    Manifest = $manifestPath
    RepoManifest = $repoManifestPath
    EncryptedArtifacts = @($artifactRecords).Count
    RemoteErrors = @($errorRecords).Count
}
