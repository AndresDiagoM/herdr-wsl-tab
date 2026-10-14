# Startup hook / action: after a Herdr restart, relaunch WSL in the panes that were WSL panes.
# Herdr restores every pane as the default shell in the saved cwd. Two sources tell us which
# panes to bring back:
#   1. records written by shell.ps1 (panes this plugin opened), in HERDR_PLUGIN_STATE_DIR/panes.json
#   2. with config "restore": "all" (default), any pane whose cwd is \\wsl.localhost\<distro>\...
#      i.e. a pane where someone had typed `wsl` by hand.
# A pane is only touched when it is an idle shell (no agent, foreground process is the shell).
param([switch] $Quiet)
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Continue'

$cfg = Get-WslTabConfig
$mode = 'all'
if ($env:WSL_TAB_RESTORE) { $mode = $env:WSL_TAB_RESTORE }
elseif ($cfg.Contains('restore') -and $cfg.restore) { $mode = $cfg.restore }
if ($mode -eq 'off') { if (-not $Quiet) { Write-Output "wsl-tab restore: off" }; exit 0 }

$herdr = $env:HERDR_BIN_PATH
if (-not $herdr) { $herdr = 'herdr' }

function Invoke-Herdr([string[]] $arguments) {
  $r = Invoke-NativeCapture $herdr $arguments
  if ($r.ExitCode -ne 0 -or -not $r.StdOut) { return $null }
  try { return ($r.StdOut | ConvertFrom-Json) } catch { return $null }
}

function Get-ShellName([object] $pi) {
  if ($null -eq $pi -or -not $pi.foreground_processes -or @($pi.foreground_processes).Count -ne 1) { return $null }
  $exe = [IO.Path]::GetFileName([string]$pi.foreground_processes[0].argv0).ToLowerInvariant()
  if ($exe -in @('pwsh.exe', 'powershell.exe', 'cmd.exe')) { return $exe }
  return $null
}

function Wait-IdleShell([string] $paneId, [int] $seconds) {
  $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
  do {
    $pi = Invoke-Herdr @('pane', 'process-info', '--pane', $paneId)
    if ($pi -and $pi.result -and $pi.result.process_info) {
      $shell = Get-ShellName $pi.result.process_info
      if ($shell) {
        # Herdr reports the Windows shell even when wsl.exe is already running inside it, so
        # also require that the screen is not already at a Linux prompt.
        $screen = Invoke-NativeCapture $herdr @('pane', 'read', $paneId, '--lines', '3')
        $last = @(($screen.StdOut -split "`r?`n") | Where-Object { $_.Trim() }) | Select-Object -Last 1
        if ($last -and $last -match '^\S+@\S+:.*[$#]\s*$') { return 'wsl' }
        if ($last) { return $shell }
      }
    }
    Start-Sleep -Seconds 2
  } while ([DateTime]::UtcNow -lt $deadline)
  return $null
}

$list = Invoke-Herdr @('pane', 'list')
if (-not $list -or -not $list.result) { Write-Output "wsl-tab restore: cannot list panes"; exit 1 }
$live = @{}
foreach ($p in $list.result.panes) { $live[[string]$p.pane_id] = $p }

$records = Get-WslPaneRecords
$targets = @{}
foreach ($id in @($records.Keys)) {
  if ($live.ContainsKey($id)) { $targets[$id] = $records[$id] }
  else { $records.Remove($id) }   # pane is gone; forget it
}
if ($mode -eq 'all') {
  foreach ($id in $live.Keys) {
    if ($targets.ContainsKey($id)) { continue }
    $cwd = [string]$live[$id].cwd
    $m = [regex]::Match($cwd, '^(\\\\|//)(wsl\.localhost|wsl\$)[\\/]([^\\/]+)([\\/].*)?$', 'IgnoreCase')
    if ($m.Success) {
      $distro = $m.Groups[3].Value
      if ($cfg.distro) { $distro = $cfg.distro }
      $targets[$id] = @{ distro = $distro; cd = (ConvertTo-WslCd $cwd); tab_id = [string]$live[$id].tab_id; workspace_id = [string]$live[$id].workspace_id }
    }
  }
}
Set-WslPaneRecords $records

if ($targets.Count -eq 0) { if (-not $Quiet) { Write-Output "wsl-tab restore: nothing to restore" }; exit 0 }
Write-Output "wsl-tab restore: $($targets.Count) pane(s) to check"

$wslenv = Get-MergedWslEnv $cfg.wslenv
$done = 0
foreach ($id in ($targets.Keys | Sort-Object)) {
  $t = $targets[$id]
  $pane = $live[$id]
  if ($pane.agent_status -and $pane.agent_status -ne 'unknown') { Write-Output "  $id : has an agent ($($pane.agent_status)), skipped"; continue }
  $shell = Wait-IdleShell $id 30
  if ($shell -eq 'wsl') { Write-Output "  $id : already at a Linux prompt, skipped"; continue }
  if (-not $shell) { Write-Output "  $id : not an idle shell, skipped"; continue }
  # Prefer the directory the WSL shell last reported (OSC 9;9 from wsl/setup.sh's bashrc
  # block, saved by Herdr as a \\wsl.localhost\... cwd) over the one the pane started in.
  $cd = $t.cd
  $liveCwd = [string]$pane.cwd
  if ($liveCwd -match '^(\\\\|//)(wsl\.localhost|wsl\$)[\\/]') { $cd = ConvertTo-WslCd $liveCwd }
  elseif (Test-PluginInstallPath $cd) { $cd = $null }
  if (-not $cd) { $cd = '~' }
  $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
  $cmd = "`$env:WSLENV=" + (& $q $wslenv) + "; & wsl.exe"
  if ($t.distro) { $cmd += " -d " + (& $q $t.distro) }
  $cmd += " --cd " + (& $q $cd)
  if ($cfg.args) { $cmd += ' ' + (($cfg.args | ForEach-Object { & $q $_ }) -join ' ') }
  if ($shell -eq 'cmd.exe') { $cmd = "set WSLENV=$wslenv&& wsl.exe" + $(if ($t.distro) { " -d `"$($t.distro)`"" }) + " --cd `"$cd`"" }
  $r = Invoke-NativeCapture $herdr @('pane', 'run', $id, $cmd)
  if ($r.ExitCode -ne 0) { Write-Output "  $id : pane run failed: $($r.StdErr.Trim())"; continue }
  # Herdr cannot see wsl.exe behind the shell (that is the whole point of this plugin), so check
  # the screen: a Linux prompt (user@host:path$) on the last non-empty line means WSL is up.
  $ok = $false
  for ($i = 0; $i -lt 10 -and -not $ok; $i++) {
    Start-Sleep -Seconds 2
    $screen = Invoke-NativeCapture $herdr @('pane', 'read', $id, '--lines', '3')
    $last = @(($screen.StdOut -split "`r?`n") | Where-Object { $_.Trim() }) | Select-Object -Last 1
    if ($last -and $last -match '^\S+@\S+:.*[$#]\s*$') { $ok = $true }
  }
  if ($ok) { Write-Output "  $id : WSL back in $cd"; $done++ }
  else { Write-Output "  $id : typed the command, but no Linux prompt seen yet" }
}
Write-Output "wsl-tab restore: $done restored"
exit 0
