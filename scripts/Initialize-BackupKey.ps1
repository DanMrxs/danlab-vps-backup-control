[CmdletBinding()]
param(
    [string]$KeyPath = "$env:USERPROFILE\.danlab-backup\backup-key.dpapi",
    [switch]$Rotate
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) "lib\DanlabBackup.psm1"
Import-Module $modulePath -Force

$keyFile = Initialize-DanlabBackupKey -KeyPath $KeyPath -Rotate:$Rotate
[pscustomobject]@{
    KeyPath = $keyFile.FullName
    Exists = $true
    Scope = "Windows DPAPI CurrentUser"
    Rotated = [bool]$Rotate
}
