# Lesson: Syncing OneDrive to Ubuntu 24.04

**Goal:** Get a OneDrive folder synced to a local Ubuntu directory, bidirectionally, so Excel files can be edited in LibreOffice Calc and stay in sync with Excel Online.

**Account used:** Personal Microsoft account `korytko07@interia.pl` (not a work account).

## Final working solution

- Client: **rclone 1.60.1** (from Ubuntu 24.04 apt)
- Remote: `onedrive:` (configured via `rclone config`, browser OAuth)
- Local path: `~/OneDrive/Documents/`
- Sync mechanism: `rclone bisync` driven by a **systemd user timer** every 5 min

### Key files

| File | Purpose |
|---|---|
| `~/.config/rclone/rclone.conf` | rclone remote config (auth token lives here) |
| `~/.config/systemd/user/onedrive-bisync.service` | runs one bisync pass |
| `~/.config/systemd/user/onedrive-bisync.timer` | schedules the service every 5 min |
| `~/.local/state/rclone-bisync.log` | sync log |
| `~/OneDrive/Documents/` | local synced folder |

### Useful commands

```bash
# Force sync now
systemctl --user start onedrive-bisync.service

# Watch live
tail -f ~/.local/state/rclone-bisync.log

# Check next scheduled run
systemctl --user list-timers onedrive-bisync.timer

# Disable auto-sync
systemctl --user disable --now onedrive-bisync.timer

# Re-enable
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

## rclone bisync notes (1.60.1)

- bisync is **beta** in 1.60.1. Works, but lacks safety features added later:
  - `--resilient` (added in 1.66) — auto-recovery from interrupted runs
  - `--conflict-resolve` (added in 1.66) — automatic conflict handling
- Supported flags in 1.60.1 that we used: `--log-file`, `--log-level`. Kept the command minimal.
- First-ever run required `--resync` to establish baseline.
- If a sync gets stuck in "go bisync again with --resync" state, run once manually with `--resync` to reset.
- Upgrading rclone later (`sudo apt` → newer version from rclone.org repo) is worth doing if you ever hit flakiness.

## Caveats for live editing

- **Don't open the same file locally AND in Excel Online at the same time.** bisync will produce a conflict copy (`file.xlsx` + `file.xlsx.conflict1`).
- **LibreOffice ≠ Excel**: complex formulas, pivots, Power Query, macros may render or save differently in LibreOffice Calc. For macro-heavy workbooks, edit in Excel Online.
- Sync cadence is every 5 min (timer). For urgent edits, trigger manually: `systemctl --user start onedrive-bisync.service`.
