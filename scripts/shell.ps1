# Pane entrypoint: run wsl.exe as this pane's process, with HERDR_* passed through.
. (Join-Path $PSScriptRoot 'common.ps1')

$cfg = Get-WslTabConfig

# Where to start inside WSL, from config "cwd":
#   "context"  -> the focused pane's directory (WSL_TAB_CD from open.ps1, else the plugin context)
#   "" or "~"  -> Linux home
#   anything else is passed to --cd as is (Linux or Windows path)
$cd = $null
switch ($cfg.cwd) {
  'context' {
    $cd = $env:WSL_TAB_CD
    if (-not $cd) { $cd = Get-ContextCwd }
  }
  ''      { $cd = '~' }
  default { $cd = $cfg.cwd }
}
if (-not $cd) { $cd = '~' }
$cd = ConvertTo-WslCd $cd

$env:WSLENV = Get-MergedWslEnv $cfg.wslenv

$argv = @()
if ($cfg.distro) { $argv += @('-d', $cfg.distro) }
$argv += @('--cd', $cd)
if ($cfg.args) { $argv += $cfg.args }

exit (Invoke-NativeInherit (Get-WslExe) $argv)
