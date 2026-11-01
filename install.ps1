<#
  install.ps1 -- register the notifier and its guard for the current user.

  Usage
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Preview
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Remove

  Task names
    ClineNotify        starts cline_notify.py --follow at logon
    ClineNotifyGuard   checks the heartbeat every 5 minutes

  The guard starts two minutes after installation and repeats every five minutes,
  so it cannot race the notifier at logon. The schedule survives a reboot.
#>
param(
    [switch]$Preview,
    [switch]$Remove,
    [string]$NotifyTask = 'ClineNotify',
    [string]$GuardTask  = 'ClineNotifyGuard'
)

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$main = Join-Path $dir 'cline_notify.py'
$guard = Join-Path $dir 'guard.ps1'
if (-not (Test-Path $main)) { throw "cline_notify.py not found in $dir" }
if (-not (Test-Path $guard)) { throw "guard.ps1 not found in $dir" }

if ($Remove) {
    foreach ($name in @($NotifyTask, $GuardTask)) {
        if ($Preview) {
            "would unregister: $name"
        } elseif (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            "removed: $name"
        } else {
            "not installed: $name"
        }
    }
    exit 0
}

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    $pyExe = $python.Source
    $pyPrefix = ''
} else {
    $python = Get-Command py -ErrorAction SilentlyContinue
    if (-not $python) { throw 'Python 3 was not found on PATH' }
    $pyExe = $python.Source
    $pyPrefix = '-3 '
}

$notifyAction = New-ScheduledTaskAction -Execute $pyExe `
    -Argument ($pyPrefix + '"' + $main + '" --follow') -WorkingDirectory $dir
$notifyTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$notifySettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

$psExe = Join-Path $PSHOME 'powershell.exe'
$guardAction = New-ScheduledTaskAction -Execute $psExe `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $guard + '"') `
    -WorkingDirectory $dir
$guardTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$guardSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

if ($Preview) {
    "notify task : $NotifyTask"
    "action      : $pyExe $pyPrefix`"$main`" --follow"
    "trigger     : at logon ($env:USERDOMAIN\$env:USERNAME)"
    "settings    : battery=allow, IgnoreNew, no time limit, restart 999x / 1 min"
    "guard task  : $GuardTask"
    "guard       : $psExe -File `"$guard`""
    "guard when  : +2 min after installation, then every 5 min"
    "nothing was registered (-Preview)"
    exit 0
}

Register-ScheduledTask -TaskName $NotifyTask -Action $notifyAction `
    -Trigger $notifyTrigger -Settings $notifySettings -Force | Out-Null
Register-ScheduledTask -TaskName $GuardTask -Action $guardAction `
    -Trigger $guardTrigger -Settings $guardSettings -Force | Out-Null

"registered: $NotifyTask, $GuardTask"
"run one check now: python .\cline_notify.py --once"
"remove both:      .\install.ps1 -Remove"
