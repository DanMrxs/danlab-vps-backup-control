[CmdletBinding()]
param(
    [string]$TaskPath = "\Danlab\",
    [string]$DailyTime = "03:15",
    [string]$WeeklyTime = "04:15",
    [string]$WeeklyDay = "Sunday"
)

$ErrorActionPreference = "Stop"

$runner = Join-Path $PSScriptRoot "Run-ScheduledBackup.ps1"
if (-not (Test-Path -LiteralPath $runner)) {
    throw "Scheduled backup runner not found: $runner"
}

$powerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$userId = "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 8)

function Register-DanlabTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)]$Trigger,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $Arguments
    Register-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskPath `
        -Action $action `
        -Trigger $Trigger `
        -Principal $principal `
        -Settings $settings `
        -Description $Description `
        -Force | Out-Null

    Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName |
        Select-Object TaskPath, TaskName, State
}

$dailyTrigger = New-ScheduledTaskTrigger -Daily -At ([DateTime]::Parse($DailyTime))
$weeklyTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $WeeklyDay -At ([DateTime]::Parse($WeeklyTime))

$common = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`""
$dailyArgs = "$common -Mode Database"
$weeklyArgs = "$common -Mode Full -RestoreSmokeTest"

$created = @()
$created += Register-DanlabTask `
    -TaskName "Danlab VPS Database Backup" `
    -Trigger $dailyTrigger `
    -Arguments $dailyArgs `
    -Description "Daily encrypted danlab VPS database/Redis backup plus sanitized inventory and manifest push."

$created += Register-DanlabTask `
    -TaskName "Danlab VPS Weekly Full Backup" `
    -Trigger $weeklyTrigger `
    -Arguments $weeklyArgs `
    -Description "Weekly encrypted danlab VPS full selected-volume backup plus restore smoke test and manifest push."

$created
