# ClaudeCodeEnv

My Claude Code environment, ready to set up on a new machine without AI.

## Get only this folder (SSH)

```bash
git clone --filter=blob:none --no-checkout git@github.com:LinuxYVariousSubjects/Linux.git ~/Linux
cd ~/Linux
git sparse-checkout set --no-cone /ClaudeCodeEnv/
git checkout master
```

Only `ClaudeCodeEnv/` lands in the working tree; the rest of the repo stays out. Update later with `git -C ~/Linux pull`.

## Status line

Shows `user@host:[cwd]:` like the bash prompt, plus context usage measured against the auto-compact trigger,
e.g. `[ctx: 45% (115k/257k)]`: cyan below 70 %, yellow below 90 %, red from 90 %.

Requires `jq`.

### Install

```bash
mkdir -p ~/.claude

# 1. Link the script, so `git pull` keeps it up to date
ln -sf ~/Linux/ClaudeCodeEnv/statusline/statusline-command.sh ~/.claude/statusline-command.sh

# 2. Add the statusLine entry to your settings (all other keys stay)
jq -s '.[0] * .[1]' ~/.claude/settings.json ~/Linux/ClaudeCodeEnv/statusline/settings-snippet.json > /tmp/settings.json \
  && mv /tmp/settings.json ~/.claude/settings.json
```

No `~/.claude/settings.json` yet? Copy the snippet instead of step 2:
`cp ~/Linux/ClaudeCodeEnv/statusline/settings-snippet.json ~/.claude/settings.json`

The status line appears on the next prompt.

### How the bar is computed

- 100 % = the auto-compact trigger = auto-compact window − 33.5k tokens (reserve measured from real compactions).
- Window, first match wins: env `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `modelSettings[<model>].autoCompactWindow`,
  `autoCompactWindow` in settings, otherwise 200k.
- `CLAUDE_STATUSLINE_SETTINGS` points the script at a different settings file.

## OneDrive sync on demand

The `/onedrive-sync` skill (manual only) and the `onedrive-sync` terminal command run one pass of the
`onedrive-bisync.service` systemd user unit, with the same flags, lock and log as the 5-minute timer.
They then report the result: OK or failed, transferred files, and any `*.conflictN.*` copies. Messages are in Polish.

Requires the rclone bisync setup from [onedrive-sync-lesson.md](../onedrive-sync-lesson.md).

### Install

```bash
~/Linux/ClaudeCodeEnv/skills/onedrive-sync/install.sh
```

Links `~/.claude/skills/onedrive-sync` and `~/.local/bin/onedrive-sync` to this folder, so `git pull` keeps
them up to date. An existing file there that is not a link is first moved to
`~/.local/state/onedrive-sync-backup/<timestamp>/`. Keeping it out of `~/.claude/skills` stops it from loading as a second skill.

## Why plain files, not a plugin

Claude Code plugins cannot set `statusLine` (plugin settings accept only `agent` and `subagentStatusLine`).
Once this folder holds skills, agents or hooks, it can become a local plugin marketplace:
`/plugin marketplace add ~/Linux/ClaudeCodeEnv`.
