#!/usr/bin/env bash
# Run inside the WSL distro from the plugin root (wsl-tab.setup action does this):
#   bash wsl/setup.sh
# Installs, idempotently:
#   ~/.local/bin/herdr                       wrapper that execs the Windows herdr.exe
#   ~/.claude/hooks/herdr-agent-state.sh     Claude Code hooks -> herdr pane report-agent
#   ~/.claude/settings.json                  hooks entries merged in (backup kept beside it)
#   ~/.bashrc                                block reporting the shell's directory to Herdr
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ok() { echo "  [ok] $*"; }
skip() { echo "  [--] $*"; }

mkdir -p "$HOME/.local/bin" "$HOME/.claude/hooks"

strip_cr() { sed 's/\r$//' "$1" > "$2"; }

# 1. wrapper
if [ -f "$HOME/.local/bin/herdr" ] && ! grep -q 'Linux-side wrapper' "$HOME/.local/bin/herdr"; then
  skip "~/.local/bin/herdr exists and is not ours; left untouched"
else
  strip_cr "$here/herdr" "$HOME/.local/bin/herdr" && chmod +x "$HOME/.local/bin/herdr" && ok "~/.local/bin/herdr"
fi
# A wsl-tab pane is a login shell; check PATH the way that shell will see it.
if ! bash -lc 'command -v herdr' >/dev/null 2>&1; then
  echo "  [!!] ~/.local/bin is not on the login-shell PATH; add it in ~/.profile or ~/.bashrc"
fi

# 2. hook script
strip_cr "$here/claude-herdr-agent-state.sh" "$HOME/.claude/hooks/herdr-agent-state.sh" \
  && chmod +x "$HOME/.claude/hooks/herdr-agent-state.sh" && ok "~/.claude/hooks/herdr-agent-state.sh"

# 3. ~/.bashrc block that reports the shell's directory to Herdr (replaced in place on update)
bashrc="$HOME/.bashrc"
block="$(sed 's/\r$//' "$here/bashrc-cwd.sh")"
if [ -f "$bashrc" ] && grep -q '^# >>> herdr-wsl-tab cwd >>>' "$bashrc"; then
  current="$(sed -n '/^# >>> herdr-wsl-tab cwd >>>/,/^# <<< herdr-wsl-tab cwd <<</p' "$bashrc")"
  if [ "$current" = "$block" ]; then
    skip "~/.bashrc already reports the directory to Herdr"
  else
    tmp="$(mktemp)"
    awk -v blockfile="$here/bashrc-cwd.sh" '
      /^# >>> herdr-wsl-tab cwd >>>/ { while ((getline l < blockfile) > 0) { sub(/\r$/, "", l); print l }; skipping = 1; next }
      /^# <<< herdr-wsl-tab cwd <<</ { skipping = 0; next }
      !skipping { print }' "$bashrc" > "$tmp" && cat "$tmp" > "$bashrc" && rm -f "$tmp" \
      && ok "~/.bashrc: herdr directory block updated"
  fi
else
  printf '\n%s\n' "$block" >> "$bashrc" && ok "~/.bashrc: reports the shell's directory to Herdr (new shells)"
fi

# 4. settings.json merge
if ! command -v python3 >/dev/null 2>&1; then
  echo "  [!!] python3 not found; merge wsl/claude-settings-hooks.json into ~/.claude/settings.json by hand"
  exit 0
fi
python3 - "$here/claude-settings-hooks.json" "$HOME/.claude/settings.json" <<'PY'
import json, os, shutil, sys, time
src, dst = sys.argv[1], sys.argv[2]
want = json.load(open(src))["hooks"]
cur = {}
if os.path.exists(dst):
    try:
        cur = json.load(open(dst))
    except Exception as e:
        print(f"  [!!] {dst} is not valid JSON ({e}); not touched"); sys.exit(0)
hooks = cur.setdefault("hooks", {})
changed = False
for ev, entries in want.items():
    lst = hooks.setdefault(ev, [])
    for e in entries:
        tag = e["hooks"][0]["command"]
        if any(h.get("command") == tag for x in lst for h in x.get("hooks", [])):
            continue
        lst.append(e); changed = True
if changed:
    if os.path.exists(dst):
        shutil.copy(dst, dst + ".bak-before-herdr-hooks-" + time.strftime("%Y%m%d%H%M%S"))
    with open(dst, "w") as f:
        json.dump(cur, f, indent=2); f.write("\n")
    print("  [ok] ~/.claude/settings.json: herdr hooks added (backup beside it)")
else:
    print("  [--] ~/.claude/settings.json already has the herdr hooks")
PY

# 5. check
if command -v herdr >/dev/null 2>&1 && [ "${HERDR_ENV:-}" = "1" ]; then
  if herdr status >/dev/null 2>&1; then ok "herdr status answers from inside WSL"; else echo "  [!!] herdr status failed from inside WSL"; fi
else
  skip "herdr reachability not checked (run this from a wsl-tab pane to check)"
fi
echo "Done. New Claude Code sessions in a wsl-tab pane will report their state to Herdr, and new WSL shells their directory."
