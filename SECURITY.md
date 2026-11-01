# Security and safety

`cline-sentinel` is a local, per-user Windows notifier for Cline turns. This page states what it
accesses and what it deliberately does not do.

## What it accesses

- Opens the newest `%USERPROFILE%\.cline\data\db\hub-events-*.db` read-only.
- Runs one resident Python process and one scheduled guard.
- Writes `logs\state_notify.json`, `events_notify.jsonl`, `toast_notify.log`, and
  `heartbeat.json` under its own folder.
- Starts `powershell.exe` for a notification; `toast.ps1` uses the Windows toast API and may play a
  WAV file.
- The guard reads the Windows process table to restart the notifier if its heartbeat is stale.
- `install.ps1` creates or removes two per-user Task Scheduler entries.

No administrator rights are required. The tool does not open a network connection, call a model,
send telemetry, use a hook, keep model memory, or install a service or driver.

## What it does not do

- It does not modify the Cline event database or any Cline session data.
- It does not edit, delete, or submit files in a Cline workspace.
- It does not start, stop, or kill Cline itself.
- It does not change Windows notification settings, power settings, or the registry.
- It does not shut down, restart, or sleep the computer.

The guard may terminate only a `cline_notify.py` process whose heartbeat has been stale for more
than 600 seconds; it is not a general process killer.

## Safety statement

The code is a read-only event reader, a clock, and a notification caller. It contains no routine
that reboots or powers off the machine, terminates Cline, or changes system configuration. It is not
designed to crash the computer.

No software can promise that a machine will never fail. Windows, Python, Cline, the disk, and the
hardware can fail independently of this tool. This is not a substitute for Cline's own logs, task
validation, or backups.

## Operational limits

- The SQLite schema is a Cline implementation detail and may change between releases.
- A notification attempt can succeed while Windows suppresses the banner. Read
  `logs\toast_notify.log` and check `setting=` and `banner=`.
- If Cline stops or restarts before a run starts, there is no `run.started` event. An idle Cline and a
  failed hub are indistinguishable from this event stream, so no reliable toast can be produced
  without a separate hub heartbeat or process signal.
- If the event database becomes unreadable, the notifier logs `DB READ FAILED` but does not send a
  toast. If Cline switches to a different event database, restart `ClineNotify` to select the new
  path.
- `events_notify.jsonl` stores short turn excerpts. Treat `logs\` as private and do not attach it to
  a public issue.

## Reporting

Use GitHub Discussions or a minimal issue for defects. Do not attach the Cline database, credentials,
absolute workstation paths, or a complete `logs\` directory. If a report needs a private channel,
ask in the issue first and the maintainer will arrange one.
