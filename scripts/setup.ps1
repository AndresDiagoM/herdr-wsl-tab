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
$r = Invoke-NativeCapture (Get-WslExe) $argv
($r.StdOut + $r.StdErr) -replace "`0", '' -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ }
exit $r.ExitCode
