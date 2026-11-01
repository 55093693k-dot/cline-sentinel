<#
  install.ps1 -- register the notifier and its guard for the current user.

  Usage
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Preview
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -NoStart   # do not start it now
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Remove    # unregister + stop

  Task names
    ClineNotify        starts cline_notify.py --follow at logon
    ClineNotifyGuard   checks the heartbeat every 5 minutes

  The guard starts two minutes after installation and repeats every five minutes,
  so it cannot race the notifier at logon. The schedule survives a reboot.
#>
param(
    [switch]$Preview,
    [switch]$Remove,
    [switch]$NoStart,
    [string]$NotifyTask = 'ClineNotify',
    [string]$GuardTask  = 'ClineNotifyGuard'
)

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$main = Join-Path $dir 'cline_notify.py'
$guard = Join-Path $dir 'guard.ps1'
$launchDir = Join-Path $dir 'launch'
$notifyVbs = Join-Path $launchDir 'notify.vbs'
$guardVbs = Join-Path $launchDir 'guard.vbs'
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
if (-not (Test-Path $main)) { throw "cline_notify.py not found in $dir" }
if (-not (Test-Path $guard)) { throw "guard.ps1 not found in $dir" }
if (-not (Test-Path $notifyVbs)) { throw "notify.vbs not found in $launchDir" }
if (-not (Test-Path $guardVbs)) { throw "guard.vbs not found in $launchDir" }
if (-not (Test-Path $wscript)) { throw "wscript.exe not found: $wscript" }

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
    # Removing the tasks does NOT stop the watcher that is already running: it would keep reading the
    # hub DB until the next reboot, with no guard left to supervise it.  Stop it here.
    $left = @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" `
                -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -match 'cline_notify\.py' })
    if ($left.Count -eq 0) {
        "no watcher process was running"
    }
    foreach ($p in $left) {
        if ($Preview) {
            "would stop process: {0} (pid {1})" -f $p.Name, $p.ProcessId
        } else {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            "stopped process: {0} (pid {1})" -f $p.Name, $p.ProcessId
        }
    }
    exit 0
}

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command py -ErrorAction SilentlyContinue }
if (-not $python) { throw 'Python 3 was not found on PATH' }

$notifyAction = New-ScheduledTaskAction -Execute $wscript `
    -Argument ('"' + $notifyVbs + '"') -WorkingDirectory $dir
$notifyTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$notifySettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden

$guardAction = New-ScheduledTaskAction -Execute $wscript `
    -Argument ('"' + $guardVbs + '"') -WorkingDirectory $dir
$guardTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$guardSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -Hidden

if ($Preview) {
    "notify task : $NotifyTask"
    "action      : $wscript `"$notifyVbs`" (hidden wrapper)"
    "trigger     : at logon ($env:USERDOMAIN\$env:USERNAME)"
    "settings    : hidden, battery=allow, IgnoreNew, no time limit, restart 999x / 1 min"
    "guard task  : $GuardTask"
    "guard       : $wscript `"$guardVbs`" (hidden wrapper)"
    "guard when  : +2 min after installation, then every 5 min"
    "nothing was registered (-Preview)"
    exit 0
}

Register-ScheduledTask -TaskName $NotifyTask -Action $notifyAction `
    -Trigger $notifyTrigger -Settings $notifySettings -Force | Out-Null
Register-ScheduledTask -TaskName $GuardTask -Action $guardAction `
    -Trigger $guardTrigger -Settings $guardSettings -Force | Out-Null

"registered: $NotifyTask, $GuardTask"

# The notify task triggers at logon, so right after installation nothing is running and the tool
# looks broken (LastTaskResult 267011 = never ran).  Start it now so the first banner needs no
# logout; -NoStart keeps the old behaviour (wait for the next logon).
if ($NoStart) {
    "not started (-NoStart); it will start at the next logon"
} else {
    Start-ScheduledTask -TaskName $NotifyTask
    Start-Sleep -Milliseconds 1500
    $state = (Get-ScheduledTask -TaskName $NotifyTask).State
    $live = @(Get-CimInstance Win32_Process `
                -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -match 'cline_notify\.py' }).Count
    "started: $NotifyTask (state=$state, watcher processes=$live)"
}
"run one check now: python .\cline_notify.py --once"
"remove both:      .\install.ps1 -Remove"
