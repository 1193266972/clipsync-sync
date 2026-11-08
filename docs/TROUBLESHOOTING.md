# Troubleshooting

Symptom → cause → fix. Check `%LOCALAPPDATA%\clipsync\clipsync.log` and `guard.log` first.

---

## Install

**`Hub 不可访问` / hub not accessible**

The share is not reachable or the path is wrong. Verify first:

```powershell
Test-Path '\\HUBHOST\share\clipsync'
```

If false, the share itself is the problem — not clipsync.

**`Hub 可写: False` / hub not writable**

Read access without write access. The machines must be able to create the `files\` staging directory. Fix the share permissions.

**Checksum mismatch**

Someone edited the scripts, or the copy is corrupt. If the source is trusted, rerun with `-Force`. Otherwise re-copy from the hub.

**`syntax errors in …`**

A script lost its BOM or was truncated. Re-copy; the installer restores BOM automatically.

---

## Nothing syncs, processes are running

**Log shows one `=== start` line and then nothing**

Check the actual command line of the child:

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match 'clipsync' } |
  Select-Object ProcessId, CommandLine
```

If `-Hub` reads `\HUBHOST\share\clipsync` (single backslash), the UNC path was mangled by unquoted argument joining. Restart through `clipsync-ctl.ps1`, which quotes path arguments.

**`peer identified` never appears**

The hub contains no `*.clip` file other than your own. The other machine either is not running or is pointed at a different folder. Compare:

```powershell
Get-ChildItem '<hub>' -Filter '*.clip'
```

---

## Content does not arrive

**`PULL skip stale <name> (age N min > 5 min)`**

Working as intended: the peer's file is older than `-StaleMinutes`, so it is not adopted at startup. Once the peer copies something new, syncing resumes. To disable: start with `-StaleMinutes 0`.

**`clipboard <- peer (...) [echo suppressed]`**

You pasted content that originally came from the peer. Correctly not echoed back.

**Text arrives, images/files do not**

The peer is on an older version without those channels. Compare `.files` existence in the hub, or check the log for `file channel enabled` / `image channel enabled` on the peer.

**Repeated identical text does not sync**

Only possible if one side still runs a pre-2.3 build (hash-only dedupe). Upgrade both sides; up-to-date builds treat a newer `ts` as a new event.

---

## Errors in the log

**`PUSH FAILED #n: …`**

Hub write failure — permissions, network drop, or the share went away. Verify `Test-Path '<hub>'` and that it is writable.

**`PULL: <name> unreadable/incomplete, retry`**

The peer is mid-write, or published something huge. Retries are automatic. Persistent occurrence means the peer is publishing without the size guard — check its version.

**`SET CLIPBOARD FAILED (locked, will retry)`**

Another program holds the clipboard. Retries automatically. If chronic, look for a clipboard manager or an app polling the clipboard aggressively.

**`PUSH skipped: text too large (N bytes > 1048576)`**

Working as intended. Raise `-MaxPublishBytes` if you really need it.

**`files skipped: folder not supported`**

Folders are intentionally unsupported. Copy the files inside instead.

**`files skipped: total N MiB > 100 MiB`**

Batch cap. Split it, or raise `-MaxFilesTotalBytes`.

**`IMAGE PUSH skipped: N MiB > 20 MiB`**

Image cap after PNG encoding. Raise `-MaxImageBytes`.

**`FILE PULL skipped: N path(s) unreachable`**

Staging was cleaned up (2-day default), or the share is unreachable from this machine. Ask the sender to copy again, or raise `-StagingKeepDays`.

---

## After a reboot

**Nothing runs**

The task is `AtLogOn`, so it starts when a user logs in — not at boot. Check:

```powershell
Get-ScheduledTask -TaskName 'clipsync-guard'
```

`Ready` means it will run at next logon. `Disabled` means it was switched off.

**Task exists but never starts**

The trigger account does not match the account that actually logs in. Re-register while logged in as the right user:

```powershell
cd C:\clipsync
.\clipsync-ctl.ps1 -Action autostart-off
.\clipsync-ctl.ps1 -Action autostart-on -Hub '<hub>'
```

**Clipboard sync is unavailable over RDP / as a service**

By design. Clipboard belongs to an interactive session; session 0 has none. This cannot be worked around in userspace.

---

## Health check

```powershell
cd C:\clipsync

# processes + hub state + task
.\clipsync-ctl.ps1 -Action status -Hub '<hub>'

# end-to-end: writes a marker, verifies it reached the hub
.\clipsync-ctl.ps1 -Action selftest -Hub '<hub>'
```

`status` should show one `GUARD` and one `CHILD`. A missing `CHILD` means the guard is restarting it — read `guard.log`.

---

## Reading the logs

```
15:14:58.596 === start local=MACHINE-A id=76d1... hub=D:\share\clipsync stale=5min maxpub=1048576B
15:14:58.660 peer identified: MACHINE-B
15:14:58.682 hub -> clipboard (1846 chars) from MACHINE-B     ← pulled
15:15:21.150 local -> hub (29 chars)                           ← pushed
15:49:59.423 local -> hub image: 1280x720, 0.1 MiB, 25 ms
15:50:18.618 hub -> clipboard image: 1280x720 0.1 MiB from MACHINE-B
15:46:56.794 local -> hub files: 1 item(s), 20.0 MiB, 5 ms
15:46:37.223 hub -> clipboard files: 1 item(s) from MACHINE-B
```

Pushes are `local -> hub`, pulls are `hub -> clipboard`. If you only ever see one direction, the other machine is not running or is misconfigured.
