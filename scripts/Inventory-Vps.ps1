[CmdletBinding()]
param(
    [string]$SshHost = "danlab-vps",
    [string]$BackupRoot = "C:\Backups\danlab-vps"
)

$ErrorActionPreference = "Stop"
$scriptPath = Join-Path $PSScriptRoot "Backup-Vps.ps1"
& $scriptPath -SshHost $SshHost -BackupRoot $BackupRoot -SkipDatabases
