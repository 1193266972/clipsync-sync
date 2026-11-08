# Changelog

Versions reflect a real deployment, built and debugged across two machines. Each entry lists what broke and why the fix looks the way it does.

---

## v2.5 — 2026-11-08

**Images.**

- New channel payload `{"k":"img","h","id","ts","p":[UNC png],"w","ht"}`, reusing the file channel and its staging.
- Receiver sets `Bitmap` + `PNG` + `FileDrop` simultaneously so chat apps paste an image and Explorer pastes a file.
- Echo protection for images cannot use hashes alone: re-encoding a `Bitmap` to PNG does not reproduce identical bytes. After receiving, the receiver re-encodes with its own encoder and stores that hash in `last_img.sig` (persisted, covers restarts).
- Clipboard change detection switched to `GetClipboardSequenceNumber()`. Previously every 400 ms re-read and re-hashed the clipboard; with PNG encoding that became expensive. Idle cost is now one integer read.
- New: `last_files.sig`, same persistence idea for the file channel.

---

## v2.4 — 2026-11-08

**Files.**

- `CF_HDROP` stores paths, not content, so a local path is useless on the peer. Files are copied into `<hub>\files\<batch>\` and the payload carries the **UNC path**; the peer's Explorer opens it directly over SMB.
- Batch hash is `sha256(sort(name|size))` — deliberately **without** mtime, because two machines can observe different mtime precision over SMB, which would diverge the hash and cause an infinite loop.
- Folders are refused with an explicit log line rather than attempting an unbounded recursive copy.
- Size cap before publishing: a half-written multi-megabyte file makes the peer log `unreadable/incomplete, retry` in a tight loop.

---

## v2.3 — 2026-11-08

**Repeated identical text now syncs.**

- v2.2 deduped on content hash alone, which silently swallowed "copy the same text again".
- `.recv` changed from `<hash>` to `<hash>|<publisher ts>`.
- Rule: different hash → new; same hash with newer `ts` → new; same hash with older `ts` → replay.
- Backward compatible: readers take `split('|')[0]`, so a plain hash from an older peer still parses.
- Added large-text publish guard (1 MiB default).

---

## v2.2 — 2026-11-08

**Two edge cases closed, one robustness bug fixed.**

- Dedupe switched from an mtime threshold to hash comparison. Clock rollback previously made a consumed file look newer, causing duplicate delivery that clobbered the user's clipboard.
- Staleness now prefers `payload.ts`, falling back to file mtime. `ts` is stamped by the publisher, so SMB timestamp precision and receiver clock skew stop mattering.
- `Stop-Process` on an already-dead PID is a terminating error under `$ErrorActionPreference = 'Stop'` and was aborting the control script mid-way. Added an existence check.
- Clipboard set failures now set a retry flag instead of marking that version as handled.

---

## v2.1 — 2026-11-08

- Path arguments are quoted when passed to `Start-Process -ArgumentList`. The array is space-joined; a leading `\\` loses one backslash in CRT parsing, turning a UNC path into `\host\share`. The child then runs, logs normally, and syncs nothing.
- Staleness guard added (`-StaleMinutes`, default 5) so a fresh start cannot adopt historical peer content.

---

## v2.0 — 2026-11-08

**Protocol rewrite.**

- Peer discovery became a directory scan (newest file not named after me). The previous version derived the peer filename from the first octet of its IP, which can never match the peer's actual `COMPUTERNAME` — with IP addressing, the pair silently never synchronized.
- Introduced `.recv`-based echo suppression.
- Files are written with a UTF-8 BOM; without it PowerShell 5.1 decodes them as the ANSI codepage.

---

## v1.0 — 2026-11-08

**First working version.**

- Each machine writes `<HOST>.clip` into the peer's share, containing `{"h","id","t"}` with base64 UTF-8 text.
- `.seen` / `.recv` for loop protection.
- Known fatal flaw: peer filename derived from IP. Only ever worked when the peer's name happened to be cosmetically supplied by hand.
