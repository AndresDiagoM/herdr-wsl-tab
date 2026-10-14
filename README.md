# herdr-wsl-tab

A [Herdr](https://herdr.dev) plugin for Windows that opens a tab (or split) whose process is
`wsl.exe`, so the pane *is* an Ubuntu (or any WSL distro) shell from its first prompt. It also
passes the `HERDR_*` variables through to Linux, so a coding agent or orchestrator started inside
that tab can drive Herdr with the Windows `herdr.exe`.

Herdr has one global `[terminal] default_shell`; there is no per-tab profile like Windows
Terminal's "Ubuntu" entry ([#4180](https://github.com/herdrdev/herdr/discussions/4180)). This
plugin is that missing entry.

## What you get

| Entry | Kind | What it does |
|---|---|---|
| `wsl-tab.open` | action | New tab running WSL, starting in the focused pane's directory |
| `wsl-tab.open-split` | action | Same, as a split next to the focused pane |
| `wsl-tab.doctor` | action | Prints distros, config, `WSLENV`, and whether `herdr` answers from inside WSL |
| `shell` | pane entrypoint | The WSL pane itself (`herdr plugin pane open --plugin wsl-tab --entrypoint shell`) |

If the focused pane already lives in WSL (cwd `\\wsl.localhost\<distro>\...`), the new tab starts
at that Linux path, opened in the configured (or default) distro; the source distro is not
selected automatically. Drive paths (`C:\...`) are handed to `wsl.exe --cd`, which maps them to
WSL's drive mounts (`/mnt/c/...`). Other network shares need a suitable mount on the Linux side.

## Install

```sh
herdr plugin install AndresDiagoM/herdr-wsl-tab
```

Requirements: Windows 10/11 with WSL 2 and at least one distro (`wsl -l -v`), Herdr 0.9.0 or
newer. Nothing to build; the plugin is three PowerShell scripts run with the Windows PowerShell
that ships with Windows.

Bind a key in `%APPDATA%\herdr\config.toml`:

```toml
[[keys.command]]
key = "prefix+shift+u"
type = "plugin_action"
command = "wsl-tab.open"
description = "open WSL tab"

[[keys.command]]
key = "prefix+shift+y"
type = "plugin_action"
command = "wsl-tab.open-split"
description = "open WSL split"
```

Or run it from the CLI: `herdr plugin action invoke wsl-tab.open`.

## Configure

Optional `config.json` in the plugin config directory (`herdr plugin config-dir wsl-tab`):

```json
{
  "distro": "Ubuntu",
  "cwd": "context",
  "wslenv": ["MY_EXTRA_VAR"],
  "args": []
}
```

| Key | Default | Meaning |
|---|---|---|
| `distro` | `""` (WSL default distro) | Passed as `wsl.exe -d <distro>` |
| `cwd` | `"context"` | `"context"` = focused pane's directory; `"~"` or `""` = Linux home; any other string (Linux or Windows path) is passed to `--cd` as is |
| `wslenv` | `[]` | Extra variable names to add to `WSLENV` for this pane (the `HERDR_*` set is always included) |
| `args` | `[]` | Extra arguments appended to `wsl.exe` (for example `["--", "fish"]`) |

See `config.example.json`.

## Driving Herdr from inside the WSL tab

The pane process receives `HERDR_ENV`, `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_WORKSPACE_ID`,
`HERDR_TAB_ID` and `HERDR_PANE_ID` because the launcher adds them to `WSLENV` for that process
only; your global `WSLENV` is untouched. The values are Windows paths on purpose: `herdr.exe` is
the one that reads them.

Inside the distro there is no `herdr` on `PATH` (the server you want is the Windows one, not a
Linux install), so save this wrapper as `~/.local/bin/herdr`; it runs `herdr.exe` through WSL
interop:

```sh
#!/usr/bin/env bash
exe=""
if [ -n "${HERDR_BIN_PATH:-}" ]; then
  exe=$(wslpath -u "$HERDR_BIN_PATH" 2>/dev/null)
fi
if [ -z "$exe" ] || [ ! -x "$exe" ]; then
  exe=$(ls -d /mnt/c/Users/*/.herdr/packages/standalone/releases/*/herdr.exe 2>/dev/null | sort -V | tail -1)
fi
[ -x "$exe" ] || { echo "herdr: herdr.exe not found" >&2; exit 127; }
exec "$exe" "$@"
```

Then make it executable and reachable:

```sh
chmod +x ~/.local/bin/herdr
export PATH="$HOME/.local/bin:$PATH"   # Ubuntu's default ~/.profile already does this when the dir exists
```

Then `herdr status` inside the tab reports the Windows server, and a Claude Code / Codex /
opencode session started there sees `HERDR_PANE_ID` and can use Herdr's agent skill. `wsl-tab.doctor`
checks all of this and prints what is missing.

## How it works

`[[panes]] shell` runs `powershell.exe -File scripts/shell.ps1`, which reads `config.json`, picks
the start directory (`WSL_TAB_CD` from the action, else the plugin context, else `~`), converts a
`\\wsl.localhost\<distro>\path` into `/path`, extends `WSLENV`, and runs
`wsl.exe [-d distro] --cd <dir> [args]`. The actions call `herdr plugin pane open` with the right
placement and hand the focused pane's directory over with `--env WSL_TAB_CD=...`.

Tested on Windows 11, Herdr 0.9.4, WSL 2 with Ubuntu, Windows PowerShell 5.1.

## License

MIT
