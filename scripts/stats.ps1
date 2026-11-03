# Action: summarise the metrics files (README "Metrics"): the one inside the distro (Claude hook
# reports, open latency, cwd delivery) and the Windows-side one (restores). Plain text.
# -WindowsFile / -WslFile read those files directly instead (tests, copies from another machine).
param([string] $WindowsFile, [string] $WslFile)
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Continue'

$cfg = Get-WslTabConfig
if (-not $WindowsFile -and $env:LOCALAPPDATA) { $WindowsFile = Join-Path $env:LOCALAPPDATA 'herdr-wsl-tab\metrics.jsonl' }

function ConvertFrom-MetricLines([string[]] $lines) {
  $events = @()
  foreach ($l in $lines) {
    if (-not $l -or -not $l.Trim()) { continue }
    try { $o = $l | ConvertFrom-Json } catch { continue }
    if ($o -is [pscustomobject] -and $o.PSObject.Properties['event']) { $events += $o }
  }
  return ,$events
}

function Get-Field($o, [string] $name) {
  $p = $o.PSObject.Properties[$name]
  if ($p) { return $p.Value }
  return $null
}

function Format-Rate([int] $n, [int] $total) {
  if ($total -eq 0) { return '-' }
  return ([math]::Round(100.0 * $n / $total, 1)).ToString([Globalization.CultureInfo]::InvariantCulture) + '%'
}

function Get-Percentile([double[]] $sorted, [double] $p) {
  # Nearest rank on an ascending array.
  $i = [int][math]::Ceiling($p * $sorted.Count) - 1
  return $sorted[[math]::Max(0, [math]::Min($i, $sorted.Count - 1))]
}

function Get-Median([double[]] $sorted) {
  $n = $sorted.Count
  if ($n % 2) { return $sorted[($n - 1) / 2] }
  return ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2
}

function Format-Ms([double] $ms) { return ('{0} ms' -f [math]::Round($ms)) }

# ---- read -------------------------------------------------------------------------------
$wslLines = @()
$wslSource = $WslFile
if ($WslFile) {
  if (Test-Path -LiteralPath $WslFile) { $wslLines = @(Get-Content -LiteralPath $WslFile -Encoding UTF8) }
} else {
  $argv = @()
  if ($cfg.distro) { $argv += @('-d', $cfg.distro) }
  $argv += @('--exec', 'sh', '-c', 'cat "${XDG_CACHE_HOME:-$HOME/.cache}/herdr-wsl-tab/metrics.jsonl" 2>/dev/null')
  $r = Invoke-NativeCapture (Get-WslExe) $argv
  $wslLines = @(($r.StdOut -replace "`0", '') -split "`r?`n")
  $wslSource = "$(if ($cfg.distro) { $cfg.distro } else { 'default distro' }):~/.cache/herdr-wsl-tab/metrics.jsonl"
}
$winLines = @()
if ($WindowsFile -and (Test-Path -LiteralPath $WindowsFile)) { $winLines = @(Get-Content -LiteralPath $WindowsFile -Encoding UTF8) }

$wslEvents = ConvertFrom-MetricLines $wslLines
$winEvents = ConvertFrom-MetricLines $winLines
$all = @($wslEvents) + @($winEvents)
$byEvent = @{}
foreach ($o in $all) { $k = [string]$o.event; if (-not $byEvent.ContainsKey($k)) { $byEvent[$k] = @() }; $byEvent[$k] += $o }
function Get-Events([string] $name) { if ($byEvent.ContainsKey($name)) { return @($byEvent[$name]) } else { return @() } }

Write-Output "wsl-tab stats"
Write-Output "  WSL side    : $wslSource ($(@($wslEvents).Count) events)"
Write-Output "  Windows side: $WindowsFile ($(@($winEvents).Count) events)"
if ($all.Count -eq 0) { Write-Output "  no metrics yet (or HERDR_WSLTAB_METRICS=0)"; exit 0 }

# ---- Claude hook reports ----------------------------------------------------------------
# ok=false is "Herdr shows no agent after the report" (issue #4755); ok=null = not checked.
$reports = @(Get-Events 'report')
Write-Output ""
Write-Output "Claude hook reports ($($reports.Count))"
$fmt = '  {0,-14} {1,8} {2,8} {3,8} {4,9}'
Write-Output ($fmt -f 'kind', 'reports', 'checked', 'ignored', 'ignored%')
foreach ($kind in @('session', 'working', 'idle', 'blocked')) {
  $rows = @($reports | Where-Object { (Get-Field $_ 'kind') -eq $kind })
  $checked = @($rows | Where-Object { $null -ne (Get-Field $_ 'ok') }).Count
  $ignored = @($rows | Where-Object { (Get-Field $_ 'ok') -eq $false }).Count
  Write-Output ($fmt -f $kind, $rows.Count, $checked, $ignored, (Format-Rate $ignored $checked))
}
foreach ($dim in @(@('distro', 'distro'), @('pane', 'pane'))) {
  $groups = @{}
  foreach ($o in $reports) {
    $ok = Get-Field $o 'ok'
    if ($null -eq $ok) { continue }
    $key = [string](Get-Field $o $dim[0])
    if (-not $groups.ContainsKey($key)) { $groups[$key] = @(0, 0) }
    $groups[$key][0]++
    if ($ok -eq $false) { $groups[$key][1]++ }
  }
  Write-Output ""
  if ($dim[0] -eq 'pane') {
    $bad = @($groups.Keys | Where-Object { $groups[$_][1] -gt 0 } | Sort-Object { -$groups[$_][1] }, { $_ })
    Write-Output "  by pane: $($groups.Count) checked, $($bad.Count) with ignored reports"
    foreach ($k in ($bad | Select-Object -First 10)) { Write-Output ($fmt -f $k, '', $groups[$k][0], $groups[$k][1], (Format-Rate $groups[$k][1] $groups[$k][0])) }
  } else {
    Write-Output "  by distro:"
    foreach ($k in ($groups.Keys | Sort-Object)) { Write-Output ($fmt -f $k, '', $groups[$k][0], $groups[$k][1], (Format-Rate $groups[$k][1] $groups[$k][0])) }
  }
}

# ---- open latency ------------------------------------------------------------------------
$opens = @(Get-Events 'open')
Write-Output ""
Write-Output "Open latency (action start to first prompt)"
$ms = @($opens | ForEach-Object { Get-Field $_ 'ms' } | Where-Object { $null -ne $_ -and $_ -ge 0 } | ForEach-Object { [double]$_ } | Sort-Object)
$skew = $opens.Count - $ms.Count
if ($ms.Count -eq 0) { Write-Output "  count 0" }
else {
  Write-Output ("  count {0}   median {1}   p95 {2}" -f $ms.Count, (Format-Ms (Get-Median $ms)), (Format-Ms (Get-Percentile $ms 0.95)))
  foreach ($place in @($opens | ForEach-Object { [string](Get-Field $_ 'placement') } | Sort-Object -Unique)) {
    $v = @($opens | Where-Object { (Get-Field $_ 'placement') -eq $place -and (Get-Field $_ 'ms') -ge 0 } | ForEach-Object { [double](Get-Field $_ 'ms') } | Sort-Object)
    if ($v.Count) { Write-Output ("  {0,-8} count {1}   median {2}   p95 {3}" -f $place, $v.Count, (Format-Ms (Get-Median $v)), (Format-Ms (Get-Percentile $v 0.95))) }
  }
}
if ($skew -gt 0) { Write-Output "  $skew open line(s) with a negative ms (clock difference between Windows and WSL), left out" }

# ---- restore -----------------------------------------------------------------------------
$restores = @(Get-Events 'restore')
Write-Output ""
Write-Output "Restore after a Herdr restart"
$scanned = 0; $relaunched = 0
foreach ($o in $restores) { $scanned += [int](Get-Field $o 'scanned'); $relaunched += [int](Get-Field $o 'relaunched') }
Write-Output "  runs $($restores.Count)   panes checked $scanned   relaunched $relaunched"

# ---- cwd delivery ------------------------------------------------------------------------
$cwds = @(Get-Events 'cwd')
Write-Output ""
Write-Output "cwd report (OSC 9;9), sampled on 1 send in 25"
$yes = @($cwds | Where-Object { (Get-Field $_ 'match') -eq $true }).Count
$no = @($cwds | Where-Object { (Get-Field $_ 'match') -eq $false }).Count
$unknown = $cwds.Count - $yes - $no
Write-Output "  checks $($cwds.Count)   match $yes   mismatch $no   unknown $unknown   match rate $(Format-Rate $yes ($yes + $no))"
exit 0
