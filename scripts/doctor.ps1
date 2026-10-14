# Action: print what the plugin sees, and check herdr is reachable from inside WSL.
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Continue'

$cfg = Get-WslTabConfig
Write-Output "wsl-tab doctor"
Write-Output "  plugin root     : $env:HERDR_PLUGIN_ROOT"
Write-Output "  config dir      : $env:HERDR_PLUGIN_CONFIG_DIR"
Write-Output "  config          : distro='$($cfg.distro)' cwd='$($cfg.cwd)' wslenv=[$($cfg.wslenv -join ',')] args=[$($cfg.args -join ' ')]"
Write-Output "  context cwd     : $(Get-ContextCwd)"
Write-Output "  WSLENV (current): $env:WSLENV"
Write-Output "  WSLENV (merged) : $(Get-MergedWslEnv $cfg.wslenv)"
Write-Output "  HERDR_BIN_PATH  : $env:HERDR_BIN_PATH"
Write-Output "  HERDR_SOCKET    : $env:HERDR_SOCKET_PATH"
Write-Output "  context json    : $env:HERDR_PLUGIN_CONTEXT_JSON"
Write-Output ""
Write-Output "WSL distros:"
$list = Invoke-NativeCapture (Get-WslExe) @('-l', '-v')
($list.StdOut + $list.StdErr) -replace "`0", '' -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { "  $_" }
Write-Output ""

$env:WSLENV = Get-MergedWslEnv $cfg.wslenv
$argv = @()
if ($cfg.distro) { $argv += @('-d', $cfg.distro) }
$probe = 'echo "  HERDR_ENV=$HERDR_ENV"; echo "  HERDR_BIN_PATH=$HERDR_BIN_PATH"; if command -v herdr >/dev/null 2>&1; then echo "  herdr wrapper: $(command -v herdr)"; herdr status 2>&1 | head -5 | sed "s/^/    /"; else echo "  herdr wrapper: NOT FOUND in PATH (see README: ~/.local/bin/herdr)"; fi'
$argv += @('--', 'bash', '-lc', $probe)
Write-Output "Inside WSL:"
$r = Invoke-NativeCapture (Get-WslExe) $argv
($r.StdOut + $r.StdErr) -replace "`0", '' -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ }
