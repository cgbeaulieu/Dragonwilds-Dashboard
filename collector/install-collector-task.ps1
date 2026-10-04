<#
  One-click installer for the 406 Dragonwilds Dashboard collector.
  Registers a Windows scheduled task that runs collect.ps1 every 5 minutes.

  Run it once:  right-click this file -> "Run with PowerShell"
  (or:  powershell -ExecutionPolicy Bypass -File install-collector-task.ps1)

  Re-run any time to update the schedule. Uses ABSOLUTE paths and sets
  "Start in", so it never hits the 0xFFFD0000 "can't find the script"
  problem the ARK collector task had.
#>
$ErrorActionPreference = "Stop"
$TaskName  = "406 Dragonwilds Dashboard Collector"
$collector = Join-Path $PSScriptRoot "collect.ps1"
$repo      = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $collector)) { throw "collect.ps1 not found next to this script ($collector)." }

$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
             -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$collector`"" `
             -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
             -ExecutionTimeLimit (New-TimeSpan -Minutes 4)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host ""
Write-Host "Installed scheduled task '$TaskName' - runs every 5 minutes (pushes every ~10)." -ForegroundColor Green
Write-Host "Check it:   (Get-ScheduledTaskInfo -TaskName '$TaskName').LastTaskResult   # 0 = good"
Write-Host "Remove it:  Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
