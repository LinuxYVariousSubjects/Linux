# Lesson: Syncing OneDrive to Ubuntu 24.04

**Goal:** Get a OneDrive folder synced to a local Ubuntu directory, bidirectionally, so Excel files can be edited in LibreOffice Calc and stay in sync with Excel Online.

**Account used:** Personal Microsoft account `korytko07@interia.pl` (not a work account).

## Final working solution

- Client: **rclone 1.73.3** (hand-installed `.deb`; Ubuntu 24.04 apt only offers 1.60.1, which lacks the safety flags below)
- Remote: `onedrive:` (configured via `rclone config`, browser OAuth)
- Local path: `~/OneDrive/Documents/`
- Sync mechanism: `rclone bisync` driven by a **systemd user timer** every 5 min

### Key files

| File | Purpose |
|---|---|
| `~/.config/rclone/rclone.conf` | rclone remote config (auth token lives here) |
| `~/.config/systemd/user/onedrive-bisync.service` | runs one bisync pass (copy in this repo: [`.config/systemd/user/`](.config/systemd/user/)) |
| `~/.config/systemd/user/onedrive-bisync.timer` | schedules the service every 5 min (copy in the same folder) |
| `~/.cache/rclone/bisync/` | bisync state: last listings (`*.lst`) and the lock file (`*.lck`) |
| `~/.local/state/rclone-bisync.log` | sync log, rotated at 5 MB; 3 old files kept as `rclone-bisync-<timestamp>.log` |
| `~/OneDrive/Documents/` | local synced folder |
| `onedrive-sync`, `/onedrive-sync` | on-demand sync with a summary, see [ClaudeCodeEnv/README.md](ClaudeCodeEnv/README.md#onedrive-sync-on-demand) |

### Useful commands

```bash
# Sync now and summarise: transferred files, conflict copies
onedrive-sync

# Sync now, raw
systemctl --user start onedrive-bisync.service

# Did the last run fail? ("failed" = yes)
systemctl --user status onedrive-bisync.service

# Watch live
tail -f ~/.local/state/rclone-bisync.log

# Check next scheduled run
systemctl --user list-timers onedrive-bisync.timer

# Disable auto-sync
systemctl --user disable --now onedrive-bisync.timer

# Re-enable
systemctl --user enable --now onedrive-bisync.timer
```

### Install on a new machine

The units are generic. They use the remote `onedrive:Documents` and the local folder `~/OneDrive/Documents`.

```bash
rclone config                                   # remote named "onedrive"
mkdir -p ~/OneDrive/Documents ~/.local/state ~/.config/systemd/user
cp ~/Linux/.config/systemd/user/onedrive-bisync.* ~/.config/systemd/user/   # full clone of this repo in ~/Linux
rclone bisync onedrive:Documents ~/OneDrive/Documents --resync   # one-time baseline
systemctl --user daemon-reload
systemctl --user enable --now onedrive-bisync.timer
```

---

## What failed first, and why

Before landing on rclone, I tried the `abraunegg/onedrive` client (the "obvious" choice for OneDrive on Linux). It failed at the auth step after a lot of effort. Documenting the rabbit hole so it's not repeated:

### Attempt 1 — onedrive 2.4.25 (Ubuntu default repo)
- Client is obsolete; Microsoft deprecated its old `oauth2/nativeclient` redirect URI.
- Browser landed on `login.microsoftonline.com/common/wrongplace` — "This is not the right page" error.
- **Lesson:** don't use the Ubuntu-packaged `onedrive` on 24.04; it's too old for current Microsoft OAuth.

### Attempt 2 — onedrive 2.5.10 (upstream OBS apt repo)
- Upgraded via `home:npreining:debian-ubuntu-onedrive` OBS repo.
- Same "wrong page" error with the default browser redirect flow.
- Switched to **device code flow** (`use_device_auth = "true"` in config): Microsoft rejected every code with "the code you entered has expired" — despite the code still being valid server-side.
- **Reason:** the onedrive client's default `application_id` (`d50ca740-…`) isn't authorized for device-code flow with personal Microsoft accounts.

### Attempt 3 — custom Azure AD app
- Registered a new app at https://entra.microsoft.com / https://portal.azure.com → App registrations.
- Settings: "Personal Microsoft accounts only" + "Allow public client flows" = Yes + Graph delegated perms (Files.ReadWrite, Files.ReadWrite.All, offline_access).
- Got a new `application_id`, put it into onedrive config.
- First try: 400 Bad Request — `AADSTS9002346: Application is configured for use by Microsoft Account users only. Please use the /consumers endpoint`.
- Fix: added `azure_tenant_id = "consumers"` to config.
- **Still** got "code expired" on the Microsoft sign-in page (https://www.microsoft.com/link).
- Likely cause: dual-identity on `@interia.pl` (also a guest in the Nokia AAD tenant), or app-propagation issues. Couldn't fully diagnose.

### Gotchas encountered
- **Dual-identity account**: `@interia.pl` was both a personal MSA *and* a guest in a corporate (Nokia) tenant. Azure portal kept routing to Nokia unless signed in through an incognito window with the personal account explicitly.
- **Browser session caching**: had to use incognito + sign out of all MS accounts to avoid cross-tenant confusion.
- **"Code expired" is a misleading error** — Microsoft returns it for various auth failures, not only actual expiry.

---

## Why rclone worked

- rclone uses its own pre-registered, multi-tenant Azure AD app that's properly authorized for personal accounts.
- Auth flow uses a **local callback server** (opens browser, receives redirect on `127.0.0.1:53682`), which is rock-solid for personal accounts.
- The whole `rclone config` → browser sign-in → done took under a minute.

---

## rclone bisync notes

Flags in the service, and why:

| Flag | Why |
|---|---|
| `--resilient --recover` | recover from interrupted or failed runs without a manual `--resync` |
| `--conflict-resolve path2` | the local copy wins conflicts. The workbook is edited only in LibreOffice, and Excel Online re-saves the file when it is opened, so the cloud copy looks "newer" |
| `--conflict-loser num --suffix-keep-extension` | the losing cloud copy is kept as `name.conflict1.xlsx` (still opens in Excel), never deleted |
| `--exclude ".~lock.*#"` | LibreOffice lock files change during the sync and failed with hash errors |
| `--max-lock 2m` | a lock left by a crashed run expires after 2 min |
| `--log-file-max-size 5M --log-file-max-backups 3` | log rotation (the log had grown to 21 MB) |

`ExecStartPre` deletes any empty `*.lck` in `~/.cache/rclone/bisync/`. A real lock always contains JSON. See the incident below.

- The first-ever run needs `--resync` to build the baseline.
- If bisync stops with "Must run --resync to recover", preview first:
  `rclone bisync onedrive:Documents ~/OneDrive/Documents --resync --resync-mode path2 --dry-run`.
  `--resync-mode path2` keeps the local version where both sides differ.
- History: the setup started on 1.60.1 (apt). bisync was beta there, and `--resilient` and `--conflict-resolve` only arrived in 1.66.

## Incident: sync silently dead for 38 days (2026-09-06 → 2026-10-14)

**Symptom:** OneDrive web showed an old version of `DAX JOURNAL MODEL - Pawel.xlsx`, yet with today's date.

**Root cause:** on 2026-09-06 the disk filled up. bisync could not write its lock file
(`cannot create lock file … no space left on device`) and left it empty (0 bytes).
rclone reads an empty lock as valid forever (`Valid lock file found. Expires at 0001-01-01 00:00:00 +0000 UTC`).
So every run after that stopped with `prior lock file found`: 4743 failed runs.
`--max-lock` does not help, because the expiry is read from the file and the empty file has none.
Nothing alerted; the unit just sat in `failed`.

**Why the web copy had today's date:** opening the workbook in Excel Online makes Excel Online save it.
The cloud copy got a fresh timestamp but kept the old content. A sheet added since then existed only locally.

**Danger in the old setup:** `--conflict-resolve newer --conflict-loser delete`. Once the lock was gone,
the newer side would win and the other would be deleted. The local copy was newer by 4 seconds.
One more look in Excel Online would have flipped that and deleted the local work, and a local delete by rclone cannot be undone.

**Diagnosis:**

```bash
systemctl --user status onedrive-bisync.service
grep -hE 'ERROR|NOTICE|CRITICAL' ~/.local/state/rclone-bisync*.log | cut -c21-140 | sort | uniq -c | sort -rn | head
ls -la ~/.cache/rclone/bisync/*.lck                                   # 0 bytes = stale lock
grep -m1 'prior lock file found' ~/.local/state/rclone-bisync*.log    # when it started
```

Which app saved a workbook: `unzip -p file.xlsx docProps/app.xml` shows `<Application>`.
It names `Microsoft Excel Online` or `LibreOffice/…`. For the cloud copy, download it first with
`rclone copyto onedrive:Documents/<file> /tmp/x.xlsx`.

**Fix:**

1. Back up both versions outside the synced folder.
2. Dry run with the new flags against a copy of the workdir, so the real lock stays in place.
   Copy `~/.cache/rclone/bisync/*.lst` to `/tmp/bisync-dry`, then run `rclone bisync … --dry-run --workdir /tmp/bisync-dry`.
3. Apply the new flags (table above) and the `ExecStartPre` cleanup of empty locks.
   One run then let the local copy win and kept the cloud copy as `*.conflict1.xlsx`.
4. Check: `rclone check` reports 0 differences, and a test file reaches the cloud and disappears there after a local delete.

Re-tested the same day: an empty lock created on purpose is removed and the sync runs.

**Lessons:**

- A sync that fails silently can stay broken for weeks. Look at `systemctl --user status onedrive-bisync.service` now and then.
- Never use `--conflict-loser delete` when one side can save on its own, as Excel Online does.
- A full disk can leave broken state files behind. Keep free space (`df -h ~`).

## Caveats for live editing

- **Don't open the same file locally AND in Excel Online at the same time.** Excel Online saves the file just by opening it and keeps it locked while it is open, so uploads fail with `423 Locked`. On the next conflict the local copy wins and the cloud copy is kept as `file.conflict1.xlsx`.
- **LibreOffice ≠ Excel**: complex formulas, pivots, Power Query, macros may render or save differently in LibreOffice Calc. For macro-heavy workbooks, edit in Excel Online.
- Sync cadence is every 5 min (timer). For urgent edits, trigger manually: `onedrive-sync`.
