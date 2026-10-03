#!/bin/bash
# Converted from PS1 in ~/.bashrc (line 10, previously commented out):
#   PS1="\[\e[01;37m\]\u\[\e[0m\]\[\e[00;37m\]@\h:[\[\e[0m\]\[\e[00;33m\]\w\[\e[0m\]\[\e[00;37m\]]: \[\e[0m\]"

input=$(cat)

user=$(whoami)
host=$(hostname -s)
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
transcript=$(echo "$input" | jq -r '.transcript_path // empty')
model_id=$(echo "$input" | jq -r '.model.id // empty')

# Auto-compact fires at (autoCompactWindow - RESERVE) tokens of context, not at the window itself.
# Measured 2026-10-03 from compactMetadata.preTokens of auto compactions in ~/.claude/projects:
#   window 290k -> floor 256.2k, median 257.7k (n=478);  window 200k -> floor 166.5k  => reserve ~33.5k.
# 100% of the bar = that trigger point. Docs say the stdin context_window_size is the model window, so unused.
RESERVE=33500
SETTINGS="${CLAUDE_STATUSLINE_SETTINGS:-$HOME/.claude/settings.json}"

# window: env > modelSettings[model].autoCompactWindow > autoCompactWindow > 200k (non-numeric, e.g. "auto", falls through)
win="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}"
if [ -z "$win" ] && [ -f "$SETTINGS" ]; then
  win=$(jq -r --arg m "$model_id" '(.modelSettings[$m].autoCompactWindow // .autoCompactWindow // empty)' "$SETTINGS" 2>/dev/null)
fi
case "$win" in ''|*[!0-9]*) win=200000 ;; esac
max=$((win - RESERVE))

# context usage: last "usage" record in transcript (input + cache tokens of the latest request);
# if a compact_boundary is newer than any usage record, show its postTokens instead of the stale pre-compact value.
ctx=""
if [ -n "$transcript" ] && [ -f "$transcript" ] && [ "$max" -gt 0 ]; then
  tot=$(tac "$transcript" 2>/dev/null | grep -m1 -E '"usage":|"subtype":"compact_boundary"' | jq -r '
    if .subtype == "compact_boundary" then (.compactMetadata.postTokens // empty)
    else (.message.usage // .usage) as $u
      | (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0))
    end' 2>/dev/null)
  case "$tot" in ''|*[!0-9]*) tot=0 ;; esac
  if [ "$tot" -gt 0 ]; then
    pct=$((tot * 100 / max))
    if   [ "$pct" -ge 90 ]; then color='01;31'
    elif [ "$pct" -ge 70 ]; then color='00;33'
    else                         color='00;36'; fi
    ctx=$(printf '\033[%sm[ctx: %s%% (%sk/%sk)]\033[0m ' "$color" "$pct" "$((tot / 1000))" "$(((max + 500) / 1000))")
  fi
fi

# bold-white user @ white host:[ yellow cwd ] :
printf '\033[01;37m%s\033[0m\033[00;37m@%s:[\033[0m\033[00;33m%s\033[0m\033[00;37m]:\033[0m ' "$user" "$host" "$cwd"
[ -n "$ctx" ] && printf '%s' "$ctx"
