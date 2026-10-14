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

# Remember this pane so restore.ps1 can bring WSL back after a Herdr restart
# (Herdr restores panes as the default shell in the saved cwd).
Save-WslPaneRecord -PaneId $env:HERDR_PANE_ID -TabId $env:HERDR_TAB_ID -WorkspaceId $env:HERDR_WORKSPACE_ID -Distro $cfg.distro -Cd $cd

$rc = Invoke-NativeInherit (Get-WslExe) $argv
# A clean exit (user typed exit) means there is nothing to restore next time.
if ($rc -eq 0) { Remove-WslPaneRecord -PaneId $env:HERDR_PANE_ID }
exit $rc
