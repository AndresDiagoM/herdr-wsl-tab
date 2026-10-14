# Shared helpers for the wsl-tab plugin. Windows PowerShell 5.1 compatible.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# HERDR_* variables that a session inside WSL needs to reach the Windows herdr server.
$script:DefaultWslEnv = @(
  'HERDR_ENV', 'HERDR_SOCKET_PATH', 'HERDR_BIN_PATH',
  'HERDR_WORKSPACE_ID', 'HERDR_TAB_ID', 'HERDR_PANE_ID'
)

function Get-WslTabConfig {
  # config.json lives in the plugin config dir (herdr plugin config-dir wsl-tab).
  $cfg = [ordered]@{ distro = ''; cwd = 'context'; wslenv = @(); args = @(); restore = 'all' }
  $dir = $env:HERDR_PLUGIN_CONFIG_DIR
  if (-not $dir) { return $cfg }
  $path = Join-Path $dir 'config.json'
  if (-not (Test-Path -LiteralPath $path)) { return $cfg }

  $raw = [string](Get-Content -LiteralPath $path -Raw -Encoding UTF8)
  if (-not $raw.Trim()) { return $cfg }
  $json = $raw | ConvertFrom-Json
  if ($null -eq $json -or $json -isnot [pscustomobject]) {
    throw "wsl-tab: $path must contain a JSON object"
  }
  foreach ($k in @('distro', 'cwd', 'restore')) {
    $prop = $json.PSObject.Properties[$k]
    if ($prop -and $null -ne $prop.Value) {
      if ($prop.Value -isnot [string]) { throw "wsl-tab: config.$k must be a string" }
      $cfg[$k] = $prop.Value
    }
  }
  if ($cfg.restore -notin @('all', 'plugin', 'off')) { throw "wsl-tab: config.restore must be 'all', 'plugin' or 'off'" }
  foreach ($k in @('wslenv', 'args')) {
    $prop = $json.PSObject.Properties[$k]
    if ($prop -and $null -ne $prop.Value) {
      if ($prop.Value -isnot [array]) { throw "wsl-tab: config.$k must be an array of strings" }
      foreach ($v in $prop.Value) {
        if ($null -eq $v -or $v -isnot [string]) { throw "wsl-tab: config.$k must be an array of strings" }
      }
      $cfg[$k] = @($prop.Value)
    }
  }
  return $cfg
}

function Get-HerdrContext {
  if (-not $env:HERDR_PLUGIN_CONTEXT_JSON) { return $null }
  try { return ($env:HERDR_PLUGIN_CONTEXT_JSON | ConvertFrom-Json) } catch { return $null }
}

function Test-PluginInstallPath([string] $path) {
  # A pane this plugin opened reports its launcher's directory (the plugin checkout), not
  # the directory WSL is in, until the shell inside reports one (OSC 9;9, see wsl/setup.sh).
  if (-not $path) { return $false }
  $p = $path.TrimEnd('\', '/')
  $roots = @()
  if ($env:HERDR_PLUGIN_ROOT) { $roots += $env:HERDR_PLUGIN_ROOT }
  if ($env:APPDATA) { $roots += (Join-Path $env:APPDATA 'herdr\plugins') }
  foreach ($root in $roots) {
    $r = $root.TrimEnd('\', '/')
    if ($p -ieq $r -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Get-ContextCwd {
  # Herdr 0.9.x context keys: focused_pane_cwd, focused_pane_id, workspace_cwd.
  # Order: the focused pane's directory; for a WSL pane that never reported one, the
  # directory this plugin opened it in; then the workspace's directory.
  $ctx = Get-HerdrContext
  if ($null -eq $ctx) { return $null }
  $get = { param($name) if ($ctx.PSObject.Properties[$name] -and $ctx.$name) { [string]$ctx.$name } }
  $paneCwd = & $get 'focused_pane_cwd'
  if (-not $paneCwd) { $paneCwd = & $get 'cwd' }
  if ($paneCwd -and -not (Test-PluginInstallPath $paneCwd)) { return $paneCwd }
  $paneId = & $get 'focused_pane_id'
  if ($paneId) {
    $record = (Get-WslPaneRecords)[$paneId]
    if ($record -and $record.cd -and -not (Test-PluginInstallPath $record.cd)) { return $record.cd }
  }
  $wsCwd = & $get 'workspace_cwd'
  if ($wsCwd -and -not (Test-PluginInstallPath $wsCwd)) { return $wsCwd }
  return $null
}

function ConvertTo-WslCd([string] $path) {
  # wsl.exe --cd accepts Windows drive paths, but rejects \\wsl.localhost\<distro>\... UNC
  # paths (what a pane that already lives in WSL reports). Turn those into the Linux path.
  # The distro part is dropped: the path is opened in the configured (or default) distro.
  if (-not $path) { return $path }
  $m = [regex]::Match($path, '^(\\\\|//|\\|/)(wsl\.localhost|wsl\$)[\\/][^\\/]+([\\/].*)?$', 'IgnoreCase')
  if ($m.Success) {
    $rest = $m.Groups[3].Value
    if (-not $rest) { return '/' }
    return ($rest -replace '\\', '/')
  }
  return $path
}

function Get-MergedWslEnv([string[]] $extra) {
  # Keep whatever WSLENV already holds (e.g. WT_SESSION), add the HERDR_* names once each,
  # as bare entries (Windows value passed as is), dropping any flagged variant (NAME/p, NAME/w).
  $tokens = @()
  if ($env:WSLENV) { $tokens += $env:WSLENV -split ':' }
  if ($extra) { $tokens += $extra }
  $tokens = @($tokens | Where-Object {
    $_ -and ($script:DefaultWslEnv -cnotcontains ($_ -split '/', 2)[0])
  })
  return ((($tokens + $script:DefaultWslEnv) | Select-Object -Unique) -join ':')
}

function Get-WslPaneStatePath {
  $dir = $env:HERDR_PLUGIN_STATE_DIR
  if (-not $dir) { return $null }
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return (Join-Path $dir 'panes.json')
}

function Get-WslPaneRecords {
  # Returns a hashtable pane_id -> @{ tab_id; workspace_id; distro; cd; saved_at }
  $records = @{}
  $path = Get-WslPaneStatePath
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $records }
  try {
    $raw = [string](Get-Content -LiteralPath $path -Raw -Encoding UTF8)
    if (-not $raw.Trim()) { return $records }
    $json = $raw | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) {
      $v = $p.Value
      $records[$p.Name] = @{
        tab_id = [string]$v.tab_id; workspace_id = [string]$v.workspace_id
        distro = [string]$v.distro; cd = [string]$v.cd; saved_at = [string]$v.saved_at
      }
    }
  } catch { }
  return $records
}

function Set-WslPaneRecords([hashtable] $records) {
  $path = Get-WslPaneStatePath
  if (-not $path) { return }
  $obj = [ordered]@{}
  foreach ($k in ($records.Keys | Sort-Object)) { $obj[$k] = $records[$k] }
  [IO.File]::WriteAllText($path, (ConvertTo-Json $obj -Depth 4), (New-Object Text.UTF8Encoding($false)))
}

function Save-WslPaneRecord([string] $PaneId, [string] $TabId, [string] $WorkspaceId, [string] $Distro, [string] $Cd) {
  if (-not $PaneId) { return }
  try {
    $r = Get-WslPaneRecords
    $r[$PaneId] = @{ tab_id = $TabId; workspace_id = $WorkspaceId; distro = $Distro; cd = $Cd; saved_at = [DateTime]::UtcNow.ToString('o') }
    Set-WslPaneRecords $r
  } catch { }
}

function Remove-WslPaneRecord([string] $PaneId) {
  if (-not $PaneId) { return }
  try {
    $r = Get-WslPaneRecords
    if ($r.ContainsKey($PaneId)) { $r.Remove($PaneId); Set-WslPaneRecords $r }
  } catch { }
}

function Get-WslExe {
  $sys = Join-Path $env:SystemRoot 'System32\wsl.exe'
  if (Test-Path -LiteralPath $sys) { return $sys }
  return 'wsl.exe'
}

function ConvertTo-NativeArgument([string] $value) {
  # Quote one argument per the MSVCRT rules so it survives as exactly one argv entry.
  # PowerShell 5.1's own native binder mangles trailing backslashes and embedded quotes.
  # Only quote when needed: wsl.exe does not recognise a quoted flag such as "-l".
  if ($value -match '^[^\s"]+$') { return $value }
  $escaped = ($value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1'
  return '"' + $escaped + '"'
}

function New-NativeStartInfo([string] $exe, [string[]] $arguments) {
  $si = New-Object System.Diagnostics.ProcessStartInfo
  $si.FileName = $exe
  $si.UseShellExecute = $false
  $si.Arguments = (@($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
  return $si
}

function Invoke-NativeInherit([string] $exe, [string[]] $arguments) {
  # Run with the console inherited (interactive child), return its exit code.
  $p = [System.Diagnostics.Process]::Start((New-NativeStartInfo $exe $arguments))
  $p.WaitForExit()
  return $p.ExitCode
}

function Invoke-NativeCapture([string] $exe, [string[]] $arguments) {
  # Run with stdout/stderr captured separately; returns @{ ExitCode; StdOut; StdErr }.
  $si = New-NativeStartInfo $exe $arguments
  $si.RedirectStandardOutput = $true
  $si.RedirectStandardError = $true
  $p = [System.Diagnostics.Process]::Start($si)
  $so = $p.StandardOutput.ReadToEndAsync()
  $se = $p.StandardError.ReadToEndAsync()
  $p.WaitForExit()
  return @{ ExitCode = $p.ExitCode; StdOut = $so.Result; StdErr = $se.Result }
}
