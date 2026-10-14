# >>> herdr-wsl-tab cwd >>>
# Report the shell's directory to Herdr at every prompt (OSC 9;9 with the Windows view of
# $PWD, the sequence Herdr's own PowerShell integration uses). Without it Herdr only knows
# the WSL launcher's directory, so new tabs and splits opened from this pane, and the
# pane after a Herdr restart, start in the plugin's folder instead of here.
if [ -n "${HERDR_ENV:-}" ] && command -v wslpath >/dev/null 2>&1; then
  __herdr_wsl_tab_cwd() {
    local win
    win="$(wslpath -w "$PWD" 2>/dev/null)" && printf '\033]9;9;%s\033\\' "$win"
  }
  case ";${PROMPT_COMMAND:-};" in
    *";__herdr_wsl_tab_cwd;"*) ;;
    *) PROMPT_COMMAND="__herdr_wsl_tab_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
  esac
fi
# <<< herdr-wsl-tab cwd <<<
