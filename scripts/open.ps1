# Action: open the "shell" pane entrypoint as a tab (default) or split.
param([string] $Placement = 'tab')
. (Join-Path $PSScriptRoot 'common.ps1')

$herdr = $env:HERDR_BIN_PATH
if (-not $herdr) { $herdr = 'herdr' }

$argv = @('plugin', 'pane', 'open', '--plugin', $env:HERDR_PLUGIN_ID, '--entrypoint', 'shell', '--placement', $Placement, '--focus')
if ($env:HERDR_WORKSPACE_ID) { $argv += @('--workspace', $env:HERDR_WORKSPACE_ID) }
if ($Placement -eq 'split' -and $env:HERDR_PANE_ID) { $argv += @('--target-pane', $env:HERDR_PANE_ID) }

# Hand the focused pane's directory to the launcher so WSL starts there (used only when
# config "cwd" is "context", which is the default).
$cwd = Get-ContextCwd
if ($cwd) { $argv += @('--env', "WSL_TAB_CD=$cwd") }

$r = Invoke-NativeCapture $herdr $argv
if ($r.StdErr) { [Console]::Error.Write($r.StdErr) }
if ($r.StdOut) { Write-Output $r.StdOut.TrimEnd() }
if ($r.ExitCode -ne 0) { exit $r.ExitCode }

# Label the new tab; the shell's title would otherwise leave it as a bare number.
if ($Placement -eq 'tab') {
  try {
    $tabId = ($r.StdOut | ConvertFrom-Json).result.plugin_pane.pane.tab_id
    if ($tabId) { Invoke-NativeCapture $herdr @('tab', 'rename', $tabId, 'WSL') | Out-Null }
  } catch { }
}
exit 0
