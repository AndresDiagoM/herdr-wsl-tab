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

# Herdr answers `report-agent` with success even when it drops the report. It drops every
# hook report for `claude` in a pane where it once saw a native claude process exit (e.g.
# a pre-0.3.0 resume argv ran Windows claude after a restart), and it never clears that
# for WSL. The pane then stays `unknown` and plugins such as telegram-agents treat the
# agent as gone. Check the pane after reporting and say so once per pane and session.
verify() {
  local out agent sid key log_dir
  out="$(herdr pane get "$HERDR_PANE_ID" 2>/dev/null)" || return 0
  # pane.agent, not agent_session.agent: a session report can land while state reports don't.
  agent="$(printf '%s' "$out" | python3 -c 'import json,sys; p=json.load(sys.stdin)["result"]["pane"]; print(p.get("agent") or "")' 2>/dev/null)" || return 0
  sid="$(field session_id)"
  log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/herdr-wsl-tab"
  key="$log_dir/ignored-$(printf '%s' "$HERDR_PANE_ID-$sid" | tr -c 'A-Za-z0-9_-' '_')"
  if [ "$agent" = claude ]; then rm -f "$key" 2>/dev/null; return 0; fi
  [ -e "$key" ] && return 0
  mkdir -p "$log_dir" 2>/dev/null && : > "$key"
  printf '%s pane=%s session=%s event=%s: herdr ignored the claude report; open Claude in a new wsl-tab pane (claude --resume %s)\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$HERDR_PANE_ID" "${sid:-?}" "$event" "${sid:-<id>}" >> "$log_dir/hook.log" 2>/dev/null
  herdr notification show "WSL Claude not tracked in $HERDR_PANE_ID" \
    --body "Herdr ignores this pane's Claude hooks, so it shows no agent here. Run claude --resume ${sid:-<id>} in a new wsl-tab pane." \
    >/dev/null 2>&1
}

case "$event" in
  session)
    sid="$(field session_id)"
    [ -n "$sid" ] || exit 0
    args=(pane report-agent-session "$HERDR_PANE_ID" --source "$src" --agent claude --seq "$seq" --agent-session-id "$sid")
    tp="$(field transcript_path)"; [ -n "$tp" ] && args+=(--agent-session-path "$tp")
    herdr "${args[@]}" >/dev/null 2>&1
    # Resume command for Herdr's session restore. Herdr runs it on WINDOWS as the pane's process,
    # so it must re-enter this distro; `bash -lc` gives it the login PATH (where claude lives).
    cwd="$(field cwd)"; [ -n "$cwd" ] || cwd="$PWD"
    distro="${WSL_DISTRO_NAME:-}"
    resume=(wsl.exe)
    [ -n "$distro" ] && resume+=(-d "$distro")
    resume+=(--cd "$cwd" -- bash -lc "exec claude --resume $sid")
    herdr pane report-agent "$HERDR_PANE_ID" --source "$src" --agent claude --state idle --seq "$seq" \
      -- "${resume[@]}" >/dev/null 2>&1
    verify
    ;;
  working|idle|blocked)
    herdr pane report-agent "$HERDR_PANE_ID" --source "$src" --agent claude --state "$event" --seq "$seq" >/dev/null 2>&1
    # PostToolUse fires `working` after every tool call; checking on the other events is enough.
    [ "$event" = working ] || verify
    ;;
esac
exit 0
