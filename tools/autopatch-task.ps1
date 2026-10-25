#Requires -Version 5.1
<#
.SYNOPSIS
  Registers (or with -Remove, deletes) the scheduled task that runs tools\autopatch.ps1 once at
  logon. The main trigger is the player script scripts\stremio-autopatch.lua, which starts
  autopatch.ps1 with Stremio and lets it wait for Stremio to end; this logon check catches an update
  that happened while no patched Stremio was running.

.DESCRIPTION
  The task runs as you, without admin rights, with no window and at low priority, with no time limit
  because it may have to wait for an unpatched Stremio to be quit. The check takes about 0.3 s and
  nothing stays running unless Stremio needs the patch again while it's open. It
  points at this copy of the repo: if you move the folder, run install.cmd again from the new place.
  install.ps1 registers it; restore.ps1 deletes it.

.PARAMETER Remove  Delete the task
.PARAMETER Status  Print whether the task exists, its last result and its next run
#>
param([switch]$Remove, [switch]$Status)
$ErrorActionPreference = 'Stop'
$TaskName = 'StremioMPV Relay autopatch'

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($Status) {
    if (-not $existing) { Write-Output 'not registered'; return }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    $last = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'never' }
    $script = ($existing.Actions | Select-Object -First 1).Arguments -replace '^.*-File\s+"([^"]+)".*$', '$1'
    # conhost --headless always reports 0, so the result says little; the script's own log says more
    Write-Output ("{0}; at logon; last run {1}; runs {2}{3}" -f $existing.State, $last, $script,
        $(if (Test-Path -LiteralPath $script) { '' } else { ' (MISSING: run install.cmd again)' }))
    return
}
if ($Remove) {
    if ($existing) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Output "Scheduled task '$TaskName' removed." }
    return
}

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script = Join-Path $PSScriptRoot 'autopatch.ps1'
$psArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"'
# conhost --headless runs a console program with no window at all (windows 10 1809 and later);
# -WindowStyle Hidden alone still flashes a window for a moment
$conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
$action = if ([Environment]::OSVersion.Version.Build -ge 17763 -and (Test-Path -LiteralPath $conhost)) {
    New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "' + $ps + '" ' + $psArgs)
} else {
    New-ScheduledTaskAction -Execute $ps -Argument $psArgs
}
$user = "$env:USERDOMAIN\$env:USERNAME"
$logon = New-ScheduledTaskTrigger -AtLogOn -User $user
$logon.Delay = 'PT1M'
# priority 7 is below normal, for cpu and disk: the check never competes with playback
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority 7
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$desc = 'At logon, checks once that Stremio still has the StremioMPV Relay patch and puts it back after an update (only while Stremio is closed). Remove it with restore.cmd or tools\autopatch-task.ps1 -Remove.'
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $logon -Settings $settings -Principal $principal -Description $desc -Force | Out-Null
Write-Output "Scheduled task '$TaskName' registered: one check at logon."
