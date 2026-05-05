[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [string]$OutputPath,
    [string]$KeyPath = "$env:USERPROFILE\.danlab-backup\backup-key.dpapi"
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) "lib\DanlabBackup.psm1"
Import-Module $modulePath -Force

if (-not $OutputPath) {
    if ($InputPath.EndsWith(".enc")) {
        $OutputPath = $InputPath.Substring(0, $InputPath.Length - 4)
    }
    else {
        throw "OutputPath is required when InputPath does not end with .enc."
    }
}

$item = Unprotect-DanlabBackupFile -InputPath $InputPath -OutputPath $OutputPath -KeyPath $KeyPath
[pscustomobject]@{
    OutputPath = $item.FullName
    Bytes = $item.Length
    Sha256 = Get-DanlabFileSha256 -Path $item.FullName
}
