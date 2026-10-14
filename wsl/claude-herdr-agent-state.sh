#!/usr/bin/env bash
# Claude Code hook -> herdr pane state, for Claude running INSIDE WSL in a herdr pane.
# herdr cannot see the Linux process behind wsl.exe (herdr discussion #3347), so this
# reports the agent label, state and session through `herdr pane report-agent*`.
# Requires: WSLENV passing HERDR_ENV/HERDR_PANE_ID/HERDR_BIN_PATH (the wsl-tab plugin or a
# user-level WSLENV does that) and the ~/.local/bin/herdr wrapper on PATH.
# Usage (from ~/.claude/settings.json hooks): herdr-agent-state.sh <event>
#   event: session | working | idle | blocked

event="${1:-}"
[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null)"
seq="$(date +%s%3N)"
src="hooks:claude-wsl"

field() { printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print(v if isinstance(v,str) else "")' "$1" 2>/dev/null; }

case "$event" in
  session)
    sid="$(field session_id)"
    [ -n "$sid" ] || exit 0
    args=(pane report-agent-session "$HERDR_PANE_ID" --source "$src" --agent claude --seq "$seq" --agent-session-id "$sid")
    tp="$(field transcript_path)"; [ -n "$tp" ] && args+=(--agent-session-path "$tp")
    herdr "${args[@]}" >/dev/null 2>&1
    herdr pane report-agent "$HERDR_PANE_ID" --source "$src" --agent claude --state idle --seq "$seq" \
      -- claude --resume "$sid" >/dev/null 2>&1
    ;;
  working|idle|blocked)
    herdr pane report-agent "$HERDR_PANE_ID" --source "$src" --agent claude --state "$event" --seq "$seq" >/dev/null 2>&1
    ;;
esac
exit 0
