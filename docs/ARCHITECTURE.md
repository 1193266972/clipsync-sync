# Architecture notes

Design decisions and the failures that forced them. Most of this was learned the hard way.

---

## 1. One rendezvous folder, not peer-to-peer paths

**Broken pattern:**

```
A writes  ->  \\B\share\clipsync\A.clip
A reads   <-  \\B\share\clipsync\<peer>.clip
```

A reads the folder it just wrote into. Even with perfect naming, the read path and the write path disagree about whose clipboard lives where.

**Working pattern:**

```
everyone reads and writes  <hub>
<hub> = D:\share\clipsync        (on the hub host, local path)
      = \\HUBHOST\share\clipsync (everywhere else)
```

No one needs to know anyone's name. The hub host gets local I/O; the rest pay SMB latency.

---

## 2. Never derive a peer filename from an IP

The original version did:

```powershell
$PeerHost = ($Peer -split '\.')[0].ToUpper()   # "192.168.31.246" -> "192"
$PeerClip = "\\$Peer\share\clipsync\$PeerHost.clip"   # -> 192.clip
```

The peer publishes under its `COMPUTERNAME`, e.g. `WIN-TH6V83705F4.clip`. `192.clip` never matches. Called with an IP, the pair silently never syncs — processes run, logs stay quiet, nothing moves.

**Fix:** scan the hub, exclude my own name, take the newest.

```powershell
Get-ChildItem $Hub -Filter '*.clip' -File |
  Where-Object { $_.BaseName.ToUpper() -ne $LocalName } |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
```

Then confirm with `payload.id != my id`.

---

## 3. mtime is a change detector, never an event identity

Using `if ($file.LastWriteTimeUtc -gt $peerMTime)` as the "is this new?" test fails three ways:

| Failure | Effect |
|---|---|
| Fresh start (`$peerMTime = MinValue`) | Every historical file looks new — the user's clipboard gets replaced by something from hours ago |
| Clock rollback (NTP correction) | A consumed file looks newer again — duplicate delivery, clipboard clobbered |
| SMB 1-second timestamp granularity | Two writes in the same second compare equal — the second is missed |

So mtime is used only as a cheap "worth re-reading?" trigger:

```powershell
$key = "{0}|{1}" -f $pf.LastWriteTimeUtc.Ticks, $pf.Length
if ($key -ne $handledSig -or $retryPending) { ... re-read ... }
```

Identity comes from content.

---

## 4. Hash-only dedupe silently eats repeated copies

Hashing alone is not enough:

```
user copies A  ->  peer receives A       (.recv = H(A))
user copies B  ->  peer receives B
user copies A again  ->  hash == .recv   ->  "already have it"  ->  lost
```

Re-copying the same text is a real, frequent user action.

**Fix:** `.recv` stores `"<hash>|<publisher ts>"`.

```
different hash                          -> new event
same hash, ts newer than recorded       -> new event (re-copy)
same hash, ts not newer                 -> replay, drop
```

The `ts` is stamped by the **publisher** at write time, so the receiver's clock and the filesystem's timestamp precision stop mattering.

Backward compatible by design: read `"<hash>|<ts>"` as `split('|')[0]`, so a plain hash from an older version still parses.

---

## 5. Staleness guard

Even with the above, the first poll after start can adopt very old peer content. Guarded:

```powershell
if ($ph -ne $recvState.h -and $StaleMinutes -gt 0 -and $ageMin -gt $StaleMinutes) {
    # skip, mark handled
}
```

Only applies to **unknown** content. A re-copy (same hash, newer `ts`) is fresh by definition and bypasses the guard.

Default 5 minutes. Set `-StaleMinutes 0` to disable.

---

## 6. Files: the clipboard holds a path, not a file

`CF_HDROP` contains path strings. Copying a local path to the peer is useless — the peer has no such drive.

Because both machines share the hub, the flow is:

1. Copy the file into `<hub>\files\<batch>\<name>`
2. Publish `{"k":"files","h":<batch hash>,"p":[UNC paths]}`
3. Receiver checks each path with `Test-Path`, then sets `FileDrop`

The peer's Explorer opens the UNC path directly over SMB.

### Batch hash uses name + size only

```powershell
sha256( sort( "<lowercase name>|<bytes>" ) )
```

Deliberately **no mtime**: two machines viewing the same file over SMB can report different mtime precision or timezone treatment. The hashes would diverge and the pair would ping-pong forever.

---

## 7. Images: encode once, and remember your own encoder

Images have no path, so the PNG is written to staging and the payload marks `k:"img"`.

The receiver sets three clipboard formats at once:

| Format | Who uses it |
|---|---|
| `Bitmap` | Paint, Word, most chat clients |
| `PNG` | Browsers, Electron apps |
| `FileDrop` | Explorer (pastes as a .png file) |

**The echo trap:** re-encoding a `Bitmap` to PNG does not reproduce identical bytes — encoder version, compression settings, and alpha handling all vary. So:

```
my encoding    -> H1
peer payload.h -> H0
H1 != H0  ->  "new image!"  ->  push back  ->  ping-pong
```

**Fix:** after setting the clipboard from a received PNG, immediately re-encode it with **my own** encoder and store that hash as `$imgSig`, persisted to `%LOCALAPPDATA%\clipsync\last_img.sig`.

Next poll computes the same hash for the same bitmap and skips it. Persistence covers restarts, where the clipboard may still hold the received image.

Files get the same treatment via `last_files.sig`.

---

## 8. Polling cost: use the clipboard sequence number

Encoding a 4K screenshot to PNG every 400 ms is wasteful. Windows exposes `GetClipboardSequenceNumber()` — a counter incremented on every clipboard change.

```csharp
[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
```

```powershell
$seq = [ClipSeq]::GetClipboardSequenceNumber()
if ($seq -ne $lastSeq) { ... read, hash, publish ... }
```

After our own `SetDataObject`, `$lastSeq` is refreshed so we do not trigger on ourselves. Idle cost drops to one integer read per tick.

---

## 9. Large payloads cause retry storms, not just slowness

Writing a 50 MB base64 blob over SMB may be observed half-written by the peer. JSON parsing fails, the peer logs `unreadable/incomplete, retry`, and both sides hammer the share for seconds.

Hence hard caps before publishing: text 1 MiB, files 100 MiB, images 20 MiB. Exceeding a cap logs once and does not publish.

---

## 10. Process hygiene

**Single instance** — a named mutex, `Local\clipsync_instance_<HOST>`:

```powershell
try   { $has = $mutex.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $has = $true }
```

`Local\` rather than `Global\` avoids extra privilege. Handling `AbandonedMutexException` is mandatory: a force-killed predecessor leaves the mutex abandoned, and refusing to take it over means the service never starts again.

**Guard** — `clipsync-guard.ps1` supervises the worker:

- restart after exit, backoff 2 s → 30 s, reset to 2 s after 60 s of stable uptime
- exit code `240` means "clean stop requested" — do not restart
- log rotation at 2 MB

**Never let logging kill the loop:**

```powershell
try { [System.IO.File]::AppendAllText($LogFile, $line, $Utf8NoBom) } catch { }
```

---

## 11. PowerShell specifics that cost real time

| Trap | Symptom | Fix |
|---|---|---|
| Missing UTF-8 BOM | PS 5.1 decodes the file as the ANSI codepage; Chinese comments become mojibake, sometimes a syntax error | Write with `New-Object System.Text.UTF8Encoding $true` |
| `gl` is a built-in alias | A function named `GL` resolves to `Get-Location`; `GL "text"` throws "positional parameter cannot be found" | Avoid alias names (`gl`, `ls`, `cd`, `sc`); use `Write-GuardLog` |
| `$args` is automatic | Assignments silently misbehave | Rename to `$childArgs` |
| `-ArgumentList` array is space-joined, unquoted | A path's leading `\\` loses a backslash in CRT parsing; UNC becomes `\server\share` and the child silently idles | `'-Hub',('"{0}"' -f $Hub)` |
| Chinese literals on the command line | Converted through the ANSI codepage before PowerShell sees it; non-cmd hosts also mangle backslashes | Build in-script: `[string]([char]0x5171 + [char]0x4EAB)` |
| Clipboard on a non-STA thread | `SetDataObject` throws from `Start-Job` / runspaces | Run as a `-File` process (STA by default) |
| `Stop-Process` on a dead PID | Terminating error under `$ErrorActionPreference = 'Stop'`, kills the control script | `if (Get-Process -Id $p -ErrorAction SilentlyContinue) { ... }` |
| `"---"` inside a string | Parsed as the decrement operator → "must provide a value expression after '- '" | Use `===` |
| `if ($Fn($x))` | Not valid call syntax | `if (My-Function $x)` |
| `GetText()` | Marshals through ANSI; emoji and rare CJK become `?` | `GetData([DataFormats]::UnicodeText)` / `SetDataObject` with a `DataObject` |

---

## 12. What this pattern is good for

The transport is generic: **a shared folder as a serverless rendezvous, with content hashing for idempotence and a publisher timestamp for event identity.**

Directly reusable for:

- cross-machine drop folders for small files
- config distribution (change one file, peers poll it)
- small state broadcast among N machines (one file per machine)
- lightweight messaging where no broker is available

Poorly suited to: large files, high throughput, strict ordering, or anything needing sub-100 ms latency.
