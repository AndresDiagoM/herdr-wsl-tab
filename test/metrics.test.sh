#!/usr/bin/env bash
# Metrics checks for the bash side (README "Metrics"). Runs in Git Bash or inside WSL:
#   bash test/metrics.test.sh
# HOME points at a temp dir and `herdr` / `wslpath` are stubs, so nothing real is touched.
# The ok=true/false and cwd match checks need python3 (the hook's own dependency); without it
# they are skipped and the null case is checked instead.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="$here/wsl/claude-herdr-agent-state.sh"
rc="$here/wsl/bashrc-cwd.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
results="$tmp/results"; : > "$results"   # checks run in subshells, so tally in a file
check() { # name, command...
  local name="$1"; shift
  if "$@"; then echo ok >> "$results"; echo "  ok   $name"; else echo fail >> "$results"; echo "  FAIL $name"; fi
}
have_py=0; command -v python3 >/dev/null 2>&1 && have_py=1

# stub herdr: `pane get` answers with $FAKE_AGENT and $FAKE_CWD_JSON, notification calls are counted
mkdir -p "$tmp/bin"
cat > "$tmp/bin/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pane get") printf '{"result":{"pane":{"agent":"%s","cwd":"%s"}}}\n' "${FAKE_AGENT:-}" "${FAKE_CWD_JSON:-}" ;;
  "notification show") echo x >> "$HOME/notified" ;;
esac
exit 0
STUB
chmod +x "$tmp/bin/herdr"

fresh() { export HOME="$tmp/home$1"; rm -rf "$HOME"; mkdir -p "$HOME"; metrics="$HOME/.cache/herdr-wsl-tab/metrics.jsonl"; }
base_env() {
  unset XDG_CACHE_HOME HERDR_WSLTAB_METRICS HERDR_WSLTAB_T0 HERDR_WSLTAB_PLACEMENT
  export PATH="$tmp/bin:$PATH" HERDR_ENV=1 HERDR_PANE_ID=w1:p2 WSL_DISTRO_NAME=Ubuntu
}
lines() { [ -f "$metrics" ] && wc -l < "$metrics" | tr -d ' ' || echo 0; }
has() { grep -q -- "$1" "$metrics" 2>/dev/null; }
lacks() { ! has "$1"; }
hook_run() { printf '{"session_id":"abc-1"}' | bash "$hook" "$1"; }

echo "hook: one line per report"
(
  fresh 1; base_env
  FAKE_AGENT=claude hook_run idle
  check "report line written" has '"event":"report"'
  check "kind, pane, distro present" has '"kind":"idle","pane":"w1:p2","distro":"Ubuntu"'
  check "line has an ISO timestamp" grep -Eq '^\{"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z","event":"report"' "$metrics"
  if [ "$have_py" = 1 ]; then check "agent seen -> ok true" has '"ok":true'; else check "no python3 -> ok null" has '"ok":null'; fi
  hook_run working
  check "working is not checked -> ok null" has '"kind":"working".*"ok":null'
  check "two reports, two lines" test "$(lines)" = 2
)
if [ "$have_py" = 1 ]; then
echo "hook: Herdr ignores the report (issue 4755 path unchanged)"
(
  fresh 2; base_env
  FAKE_AGENT= hook_run idle; FAKE_AGENT= hook_run blocked
  check "ok false logged" has '"ok":false'
  check "ignored on every report" test "$(grep -c '"ok":false' "$metrics")" = 2
  check "hook.log line only once per pane+session" test "$(wc -l < "$HOME/.cache/herdr-wsl-tab/hook.log" | tr -d ' ')" = 1
  check "notification only once" test "$(wc -l < "$HOME/notified" | tr -d ' ')" = 1
)
fi
echo "hook: opt-out and failing writes"
(
  fresh 3; base_env
  HERDR_WSLTAB_METRICS=0 FAKE_AGENT=claude hook_run idle
  check "HERDR_WSLTAB_METRICS=0 writes nothing" test ! -e "$metrics"
  fresh 4; base_env
  mkdir -p "$HOME/.cache"; : > "$HOME/.cache/herdr-wsl-tab"   # a file where the directory should be
  FAKE_AGENT=claude hook_run idle; rc_hook=$?
  check "unwritable metrics dir does not fail the hook" test "$rc_hook" = 0
  fresh 5; base_env
  printf '{}' | bash "$hook" bogus
  check "unknown event logs nothing" test ! -e "$metrics"
)

# ---- bashrc block -------------------------------------------------------------------------
# shellcheck disable=SC2329
wslpath() { printf '%s\n' '\\wsl.localhost\Ubuntu\tmp'; }
load_block() { PROMPT_COMMAND=; unset -f __herdr_wsl_tab_cwd; unset __herdr_wsl_tab_sent; . "$rc"; }
WIN='\\wsl.localhost\Ubuntu\tmp'
send() { local i; for ((i = 0; i < $1; i++)); do __herdr_wsl_tab_cwd; done >/dev/null; }

echo "bashrc block: open latency fires once"
(
  fresh 6; base_env; load_block
  export HERDR_WSLTAB_T0=$(( $(date +%s%3N) - 250 )) HERDR_WSLTAB_PLACEMENT=split
  send 3
  check "one open line" test "$(grep -c '"event":"open"' "$metrics")" = 1
  check "placement and distro recorded" has '"distro":"Ubuntu","placement":"split"'
  ms="$(sed -n 's/.*"event":"open","ms":\([-0-9]*\),.*/\1/p' "$metrics")"
  check "ms is now - T0 (250..5000)" test "${ms:-0}" -ge 250 -a "${ms:-0}" -lt 5000
  check "T0 is unset after the first prompt" test -z "${HERDR_WSLTAB_T0:-}${HERDR_WSLTAB_PLACEMENT:-}"
)
(
  fresh 7; base_env; load_block
  send 2
  check "no T0 -> no open line" lacks '"event":"open"'
)

echo "bashrc block: cwd sampling at 1 and 25"
if [ "$have_py" = 1 ]; then
(
  fresh 8; base_env; load_block
  export FAKE_AGENT=claude FAKE_CWD_JSON="${WIN//\\/\\\\}"
  send 1; sleep 1.5
  check "send 1 is checked" has '"event":"cwd","sent":1,"match":true'
  send 23; sleep 1.5
  check "sends 2..24 are not" test "$(grep -c '"event":"cwd"' "$metrics")" = 1
  send 1; sleep 1.5
  check "send 25 is checked" has '"sent":25,"match":true'
  send 1; sleep 1
  check "send 26 is not" test "$(grep -c '"event":"cwd"' "$metrics")" = 2
  export FAKE_CWD_JSON='C:\\elsewhere'
  send 24; sleep 1.5   # sends 27..50
  check "send 50 with a different Herdr cwd -> match false" has '"sent":50,"match":false'
)
else
(
  fresh 8; base_env; load_block
  send 1; sleep 1
  check "no python3 -> no cwd query" test ! -e "$metrics"
)
fi
echo "bashrc block: opt-out"
(
  fresh 9; base_env; load_block
  export HERDR_WSLTAB_METRICS=0 HERDR_WSLTAB_T0=$(( $(date +%s%3N) - 100 ))
  send 3; sleep 1
  check "HERDR_WSLTAB_METRICS=0 writes nothing" test ! -e "$metrics"
  check "T0 is still consumed" test -z "${HERDR_WSLTAB_T0:-}"
)

pass="$(grep -c '^ok' "$results")"; fail="$(grep -c '^fail' "$results")"
echo
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
