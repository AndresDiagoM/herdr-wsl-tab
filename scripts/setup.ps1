# Action: install the Linux-side pieces (herdr wrapper + Claude Code hooks) in the configured distro.
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Continue'

$cfg = Get-WslTabConfig
$root = $env:HERDR_PLUGIN_ROOT
if (-not $root) { $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }

$env:WSLENV = Get-MergedWslEnv $cfg.wslenv
$argv = @()
if ($cfg.distro) { $argv += @('-d', $cfg.distro) }
$argv += @('--cd', $root, '--', 'bash', 'wsl/setup.sh')

Write-Output "wsl-tab setup (distro: $(if ($cfg.distro) { $cfg.distro } else { 'default' }))"

# Windows side: list the HERDR_* names in the user-level WSLENV, so that `wsl` typed in any pane
# and the resume commands Herdr runs after a restart also pass them through (the launcher sets
# WSLENV for its own process, but those two paths do not go through the launcher).
try {
  $userEnv = [Environment]::GetEnvironmentVariable('WSLENV', 'User')
  $saved = $env:WSLENV; $env:WSLENV = $userEnv
  $merged = Get-MergedWslEnv $cfg.wslenv
  $env:WSLENV = $saved
  if ($merged -ne $userEnv) {
    [Environment]::SetEnvironmentVariable('WSLENV', $merged, 'User')
    Write-Output "  [ok] user WSLENV now: $merged (new Herdr windows pick it up)"
  } else {
    Write-Output "  [--] user WSLENV already lists the HERDR_* names"
  }
} catch { Write-Output "  [!!] could not update user WSLENV: $($_.Exception.Message)" }
$r = Invoke-NativeCapture (Get-WslExe) $argv
($r.StdOut + $r.StdErr) -replace "`0", '' -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ }
exit $r.ExitCode
