[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BackupSet,
    [string]$ArtifactRelativePath = "payload\databases\postgres_pg_dumpall.sql.gz.enc",
    [string]$KeyPath = "$env:USERPROFILE\.danlab-backup\backup-key.dpapi",
    [string]$PostgresImage = "postgres:14",
    [switch]$KeepContainer
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) "lib\DanlabBackup.psm1"
Import-Module $modulePath -Force

$artifact = Join-Path $BackupSet $ArtifactRelativePath
if (-not (Test-Path -LiteralPath $artifact)) {
    throw "Artifact not found: $artifact"
}

$testId = "danlab-restore-$((Get-Date).ToString('yyyyMMddHHmmss'))"
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) $testId
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$plain = Join-Path $workDir "dump.sql.gz"
$password = [Guid]::NewGuid().ToString("N")

try {
    Unprotect-DanlabBackupFile -InputPath $artifact -OutputPath $plain -KeyPath $KeyPath | Out-Null
    Invoke-DanlabNative -FilePath "docker" -ArgumentList @(
        "run", "-d", "--name", $testId,
        "-e", "POSTGRES_PASSWORD=$password",
        $PostgresImage
    ) -ErrorMessage "Failed to start local restore-test Postgres container."

    Start-Sleep -Seconds 8
    Invoke-DanlabNative -FilePath "docker" -ArgumentList @("cp", $plain, "$testId`:/tmp/dump.sql.gz") -ErrorMessage "Failed to copy dump into restore-test container."
    Invoke-DanlabNative -FilePath "docker" -ArgumentList @(
        "exec", $testId, "sh", "-lc",
        "gunzip -c /tmp/dump.sql.gz | sed -E '/^CREATE ROLE postgres;$/d;/^ALTER ROLE postgres /d' | psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/tmp/restore.log"
    ) -ErrorMessage "Postgres restore smoke test failed."
    Invoke-DanlabNative -FilePath "docker" -ArgumentList @(
        "exec", $testId, "psql", "-U", "postgres", "-d", "postgres", "-Atqc", "select 1"
    ) -ErrorMessage "Postgres restore verification query failed."

    [pscustomobject]@{
        BackupSet = $BackupSet
        Artifact = $ArtifactRelativePath
        Container = $testId
        RestoreSmokeTest = "ok"
    }
}
finally {
    if (-not $KeepContainer) {
        & docker rm -f $testId *> $null
    }
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force
    }
}
