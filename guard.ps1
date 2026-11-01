# guard.ps1 -- restart cline_notify.py when its heartbeat is stale or blind.
# Runs from Task Scheduler every 5 minutes. Healthy => no log line.
# "Blind" means the heartbeat reports consecutive DB read failures (db_fail).
# It is independent by default; an optional peer task can be enabled explicitly.
$ErrorActionPreference = 'SilentlyContinue'
$dir   = $PSScriptRoot
$logs  = Join-Path $dir 'logs'
$hb    = Join-Path $logs 'heartbeat.json'
$log   = Join-Path $logs 'guard.log'
$main  = Join-Path $dir 'cline_notify.py'
$maxAge = 600
$maxDbFail = 3        # consecutive DB-read failures before treating the watcher as sick
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

# --- optional peer sentinel: keep ONE task-based sentinel healthy -------------------------------
# Default target is the simulation sentinel (Sim_Sentinel_1min); when that task is absent this is
# a no-op.  Set CLINE_GUARD_PEER_TASK to another task name to override, or to '-' to disable.
# This runs BEFORE the early exits below, because a sick peer must be fixed even when the watcher
# itself is perfectly healthy.
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
$dbFail = 0
if ($hasHb) {
    $age = ((Get-Date) - (Get-Item $hb).LastWriteTime).TotalSeconds
    # A fresh heartbeat only proves the process is alive.  The payload says
    # whether it can actually SEE the hub DB; a silent DB failure must be a
    # restart reason, not a healthy result.
    try {
        $hbObj = Get-Content -LiteralPath $hb -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($null -ne $hbObj.db_fail) { $dbFail = [int]$hbObj.db_fail }
    } catch {
        Note "heartbeat unreadable: $($_.Exception.Message)"
    }
}

if (-not $hasHb) {
    # At logon the guard may start before the main task writes its first heartbeat.
    if ((Find-Watchers).Count -eq 0) {
        Note 'no heartbeat and no watcher -> restart'
    } else {
        exit 0
    }
} elseif ($age -le $maxAge -and $dbFail -lt $maxDbFail) {
    exit 0
} else {
    $procs = Find-Watchers
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force }
    if ($procs.Count -gt 0) {
        Note ("watcher unhealthy: age={0:N0}s db_fail={1} -> killed {2} instances" -f $age, $dbFail, $procs.Count)
    } else {
        Note ("watcher unhealthy: age={0:N0}s db_fail={1}, no process -> restart" -f $age, $dbFail)
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
