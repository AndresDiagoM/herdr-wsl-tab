# >>> herdr-wsl-tab cwd >>>
# Report the shell's directory to Herdr at every prompt (OSC 9;9 with the Windows view of
# $PWD, the sequence Herdr's own PowerShell integration uses). Without it Herdr only knows
# the WSL launcher's directory, so new tabs and splits opened from this pane, and the
# pane after a Herdr restart, start in the plugin's folder instead of here.
# Metrics (README "Metrics", off with HERDR_WSLTAB_METRICS=0): time to the first prompt of a
# pane the plugin opened, and whether Herdr got the directory (checked on 1 send in 25).
if [ -n "${HERDR_ENV:-}" ] && command -v wslpath >/dev/null 2>&1; then
  __herdr_wsl_tab_metric() {
    [ "${HERDR_WSLTAB_METRICS:-1}" = 0 ] && return 0
    local dir="${XDG_CACHE_HOME:-$HOME/.cache}/herdr-wsl-tab"
    mkdir -p "$dir" 2>/dev/null && printf '{"ts":"%s","event":"%s"%s}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-}" >> "$dir/metrics.jsonl" 2>/dev/null
    return 0
  }
  __herdr_wsl_tab_cwd_check() {  # $1 = send counter, $2 = the path that was sent
    local got want="${2%\\}" match=null
    sleep 0.5  # let Herdr apply the sequence before asking
    got="$(herdr pane get "$HERDR_PANE_ID" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"].get("cwd") or "")' 2>/dev/null)"
    got="${got%\\}"
    if [ -n "$got" ]; then [ "$got" = "$want" ] && match=true || match=false; fi
    __herdr_wsl_tab_metric cwd ",\"sent\":$1,\"match\":$match"
  }
  __herdr_wsl_tab_measure() {  # $1 = the path just sent
    local t0="${HERDR_WSLTAB_T0:-}" distro="${WSL_DISTRO_NAME:-}" place="${HERDR_WSLTAB_PLACEMENT:-}"
    distro="${distro//[^A-Za-z0-9._-]/_}" place="${place//[^a-z]/}"
    unset HERDR_WSLTAB_T0 HERDR_WSLTAB_PLACEMENT  # first prompt only
    [ "${HERDR_WSLTAB_METRICS:-1}" = 0 ] && return 0
    case "$t0" in ''|*[!0-9]*) ;; *)
      __herdr_wsl_tab_metric open ",\"ms\":$(( $(date +%s%3N) - t0 )),\"distro\":\"$distro\",\"placement\":\"${place:-unknown}\"" ;;
    esac
    __herdr_wsl_tab_sent=$(( ${__herdr_wsl_tab_sent:-0} + 1 ))
    if [ -n "${HERDR_PANE_ID:-}" ] && { [ "$__herdr_wsl_tab_sent" = 1 ] || [ $(( __herdr_wsl_tab_sent % 25 )) = 0 ]; } \
       && command -v herdr >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
      ( __herdr_wsl_tab_cwd_check "$__herdr_wsl_tab_sent" "$1" </dev/null >/dev/null 2>&1 & )
    fi
    return 0
  }
  __herdr_wsl_tab_cwd() {
    local win
    win="$(wslpath -w "$PWD" 2>/dev/null)" || return 0
    printf '\033]9;9;%s\033\\' "$win"
    __herdr_wsl_tab_measure "$win"
  }
  case ";${PROMPT_COMMAND:-};" in
    *";__herdr_wsl_tab_cwd;"*) ;;
    *) PROMPT_COMMAND="__herdr_wsl_tab_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
  esac
fi
# <<< herdr-wsl-tab cwd <<<
