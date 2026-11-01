# guard.ps1 -- restart cline_notify.py when its heartbeat is stale.
# Runs from Task Scheduler every 5 minutes. Healthy => no log line.
# It does not depend on any other sentinel or scheduled task.
$ErrorActionPreference = 'SilentlyContinue'
$dir   = $PSScriptRoot
$logs  = Join-Path $dir 'logs'
$hb    = Join-Path $logs 'heartbeat.json'
$log   = Join-Path $logs 'guard.log'
$main  = Join-Path $dir 'cline_notify.py'
$maxAge = 600
New-Item -ItemType Directory -Path $logs -Force | Out-Null

function Note([string]$m) {
    ("{0}`t{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) |
        Add-Content -Path $log -Encoding UTF8
}

function Find-Python {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return @{ Path = $cmd.Source; Prefix = @() } }
    $cmd = Get-Command py -ErrorAction SilentlyContinue
    if ($cmd) { return @{ Path = $cmd.Source; Prefix = @('-3') } }
    return $null
}

function Find-Watchers {
    # Match python.exe AND pythonw.exe: either can host the watcher, and a guard that only sees
    # python.exe would leave a hung pythonw instance running (two watchers on one DB).
    @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" `
        -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -match 'cline_notify\.py' })
}

# --- optional peer sentinel: keep a SECOND, task-based sentinel healthy --------------------------
# Default target is the simulation sentinel (sim-sentinel's Sim_Sentinel_1min).  Everything here is
# a NO-OP when that task does not exist, so users who only run the notifier are unaffected.
# This runs BEFORE the early exits below, because a sick peer must be fixed even when the watcher
# itself is perfectly healthy.  Override with CLINE_GUARD_PEER_TASK; set it to '-' to disable.
$peerTask = if ($env:CLINE_GUARD_PEER_TASK) { $env:CLINE_GUARD_PEER_TASK } else { 'Sim_Sentinel_1min' }
if ($peerTask -eq '-') { $peerTask = '' }
$peer = if ($peerTask) { Get-ScheduledTask -TaskName $peerTask -ErrorAction SilentlyContinue } else { $null }
if ($peer) {
    $info = Get-ScheduledTaskInfo -TaskName $peerTask
    if ($peer.State -eq 'Disabled') {
        Enable-ScheduledTask -TaskName $peerTask | Out-Null
        Start-ScheduledTask  -TaskName $peerTask
        Note "peer task '$peerTask' was Disabled -> enabled + triggered"
    } elseif ($info.LastTaskResult -ne 0) {
        # 267009 (0x41301) means an instance is STILL RUNNING; a bare Start-ScheduledTask is a
        # no-op under MultipleInstances=IgnoreNew, so stop it first (observed 2026-11-01 17:22).
        Stop-ScheduledTask  -TaskName $peerTask
        Start-Sleep -Seconds 1
        Start-ScheduledTask -TaskName $peerTask
        Note ("peer task '{0}' rc={1} -> stopped + re-triggered" -f $peerTask, $info.LastTaskResult)
    } elseif (((Get-Date) - $info.LastRunTime).TotalMinutes -gt 5) {
        Start-ScheduledTask -TaskName $peerTask
        Note ("peer task '{0}' last run {1:N0} min ago -> triggered" -f $peerTask,
              ((Get-Date) - $info.LastRunTime).TotalMinutes)
    }
}

if (-not (Test-Path $main)) {
    Note "cline_notify.py MISSING: $main"
    exit 1
}

$hasHb = Test-Path $hb
$age = 99999
if ($hasHb) { $age = ((Get-Date) - (Get-Item $hb).LastWriteTime).TotalSeconds }

if (-not $hasHb) {
    # At logon the guard may start before the main task writes its first heartbeat.
    if ((Find-Watchers).Count -eq 0) {
        Note 'no heartbeat and no watcher -> restart'
    } else {
        exit 0
    }
} elseif ($age -le $maxAge) {
    exit 0
} else {
    $procs = Find-Watchers
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force }
    if ($procs.Count -gt 0) {
        Note ("watcher heartbeat stale {0:N0}s -> killed {1} instance(s)" -f $age, $procs.Count)
    } else {
        Note ("watcher heartbeat stale {0:N0}s, no process -> restart" -f $age)
    }
}

$py = Find-Python
if (-not $py) {
    Note 'python not found on PATH; watcher not restarted'
    exit 1
}
$argList = @($py.Prefix) + @('"' + $main + '"', '--follow')
Start-Process -FilePath $py.Path -ArgumentList $argList `
    -WorkingDirectory $dir `
    -RedirectStandardOutput (Join-Path $logs 'notify_stdout.txt') `
    -RedirectStandardError  (Join-Path $logs 'notify_err.txt') `
    -WindowStyle Hidden
Note 'watcher started'
exit 0
