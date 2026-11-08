# clipsync

**English** | [简体中文](README.zh-CN.md)

Cross-machine clipboard sync for Windows — **text, images, and files** — over an SMB share. No server, no agent, no cloud.

One shared folder acts as the rendezvous point. Every machine writes its own clipboard into it and reads everyone else's. Add a machine and nothing else needs reconfiguring.

```
Machine A ──┐
Machine B ──┼──►  \\HUBHOST\share\clipsync\   ◄──  one shared folder
Machine C ──┘        (all machines read/write here)
```

---

## Why this exists

The obvious approach — "I write into your share and read from your share" — is broken: each machine ends up reading the file it wrote itself. Another common trap is deriving the peer's clipboard filename from its IP address, which can never match the peer's actual `COMPUTERNAME`.

This project solves both by using **one rendezvous folder with dynamic peer discovery**, plus a content-addressed event model that survives clock skew and prevents infinite echo loops.

---

## Features

| | |
|---|---|
| **Text** | Plain text, UTF-8 over base64 — Chinese, accents, emoji all safe |
| **Images** | Published as PNG; receiver sets `Bitmap` + `PNG` + `FileDrop` so every app pastes natively |
| **Files** | Copied to a staging folder on the share, clipboard carries the **UNC path** so the peer can actually open it |
| **No server** | Uses an ordinary SMB share |
| **Self-healing** | Guard process restarts the worker with exponential backoff |
| **Autostart** | Optional `AtLogOn` scheduled task |
| **Bounded** | Size caps, stale-content guard, staging cleanup, log rotation |

---

## Quick start

### 1. Pick a hub

Any folder both machines can read **and write**. Example: `\\HUBHOST\share\clipsync`.

The hub host itself should use a **local path** (`D:\share\clipsync`) for speed; other machines use the UNC path. Both point at the same physical folder.

### 2. Install on each machine

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "\\HUBHOST\share\clipsync\deploy\install.ps1"
```

Place `install.ps1` next to the three worker scripts inside the hub (e.g. in `deploy\`). The installer derives the hub from its own location — run it from the share and it configures itself.

It will:

1. Elevate via UAC if needed
2. Resolve the hub (or accept `-Hub`)
3. Probe that the hub is **writable**
4. Verify byte length + SHA-256 against `checksums.txt`
5. Copy to `C:\clipsync`, restoring the UTF-8 BOM if lost
6. Syntax-check every script
7. Stop any running instance
8. Start with the resolved hub
9. Register the `AtLogOn` task
10. Print the log tail and verification steps

### 3. Done

Copy something on either machine, paste on the other. No further configuration.

---

## Manual install

```powershell
New-Item -ItemType Directory C:\clipsync -Force
Copy-Item .\*.ps1 C:\clipsync\ -Force

Set-ExecutionPolicy -Scope Process Bypass -Force
cd C:\clipsync
.\clipsync-ctl.ps1 -Action start -Hub '\\HUBHOST\share\clipsync'
.\clipsync-ctl.ps1 -Action autostart-on -Hub '\\HUBHOST\share\clipsync'
```

---

## Operations

```powershell
cd C:\clipsync

.\clipsync-ctl.ps1 -Action status  -Hub '<hub>'   # processes, logs, hub state files, task
.\clipsync-ctl.ps1 -Action log                    # tail both logs
.\clipsync-ctl.ps1 -Action stop
.\clipsync-ctl.ps1 -Action start   -Hub '<hub>'
.\clipsync-ctl.ps1 -Action selftest -Hub '<hub>'  # write a marker, verify it lands
.\clipsync-ctl.ps1 -Action autostart-on  -Hub '<hub>'
.\clipsync-ctl.ps1 -Action autostart-off
.\clipsync-ctl.ps1 -Action uninstall
```

Logs: `%LOCALAPPDATA%\clipsync\clipsync.log` and `guard.log`.

---

## How it works

### Hub layout

```
<hub>\
  <HOST>.clip      {"h":sha256,"id":"<run id>","ts":unix,"t":"base64 utf8 text"}
  <HOST>.seen      sha256 this machine last PUSHED
  <HOST>.recv      "<sha256>|<ts>" this machine last RECEIVED
  <HOST>.files     {"k":"files"|"img","h","id","ts","p":[UNC paths],"w","ht"}
  <HOST>.fseen
  <HOST>.frecv
  files\<batch>\   staging for files and images
```

Each machine only ever writes files named after itself. Reading means: scan the hub, take the newest file that is **not mine**.

### Echo protection

Four gates, any one of which drops the event:

1. `payload.id` equals my own run id — I wrote this
2. `payload.h` equals my `.seen` — I just pushed this
3. `payload.h` equals my `.recv` **and** `payload.ts` is not newer — already consumed
4. my current clipboard hash equals `.recv` — this content came from the peer

Gate 3 is what makes re-copying *the same text* a new event (new `ts`) while still ignoring genuine replays.

### Why `h|ts` and not just `h`

Two failure modes collide:

- **Clock rollback** makes an already-consumed file look newer again → duplicate delivery
- **Re-copying identical text** looks like "already seen" → lost delivery

Both present identically if you compare timestamps. Storing the *publisher's* `ts` alongside the hash separates them: same hash with a newer `ts` is a new event; same hash with an older `ts` is a replay.

### Why files use UNC paths

`CF_HDROP` stores **paths**, not bytes. A local path is meaningless on the peer. Because both machines see the same share, the payload carries the file's UNC path and the peer sets `FileDrop` to it — the target application opens it over SMB directly.

Images are stored as PNG and published the same way, but the receiver also sets `Bitmap` and `PNG` clipboard formats so chat apps and paint programs paste a real image rather than a file.

---

## Limits

| | |
|---|---|
| Text | 1 MiB (base64 payload guard) |
| Files | 100 MiB per batch |
| Images | 20 MiB after PNG encoding |
| Folders | **Not supported** — recursive copies are unbounded; logged and skipped |
| Latency | ~0.5 s (400 ms poll) |
| Session | Requires an interactive login; clipboard is unavailable in session 0 |
| Multi-machine | All machines share **one** clipboard — last write wins, not point-to-point |

All thresholds are parameters: `-MaxPublishBytes`, `-MaxFilesTotalBytes`, `-MaxImageBytes`, `-StagingKeepDays`, `-IntervalMs`, `-StaleMinutes`.

---

## Requirements

- Windows 10 / 11, PowerShell 5.1
- Administrator rights for install (scheduled task + `C:\` write)
- Read **and write** access to the hub for every machine

---

## Documents

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — design notes, protocol, and the pitfalls behind each decision
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — symptom → cause → fix
- [`CHANGELOG.md`](CHANGELOG.md) — the version history, including the bugs that shaped the design

Chinese: [`README.zh-CN.md`](README.zh-CN.md) · [`docs/ARCHITECTURE.zh-CN.md`](docs/ARCHITECTURE.zh-CN.md) · [`docs/TROUBLESHOOTING.zh-CN.md`](docs/TROUBLESHOOTING.zh-CN.md) · [`CHANGELOG.zh-CN.md`](CHANGELOG.zh-CN.md)

---

## License

MIT — see [LICENSE](LICENSE).
