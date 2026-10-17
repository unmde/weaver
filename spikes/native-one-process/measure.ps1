param(
  [ValidateSet('processes', 'one')][string]$Topology = 'one',
  [int]$Widgets = 10,
  [int]$Trials = 3,
  [int]$Warmup = 25,
  [int]$Window = 15,
  [ValidateSet('normal', 'desktop')][string]$Layer = 'normal',
  [switch]$Regions,
  [string]$CaptureDir
)
# ADR 0019 open question 1: N tiled copies of examples/m4b-synthetic on the
# Native stack, either as today (one weaver-widget process per Widget) or as
# threads of one weaver-widget process (--multi). Both run against one
# weaver-renderer started here, without weaverd: this script uses its own
# renderer pipe and a scratch LOCALAPPDATA, never touches a running daemon or
# the user's registry, samples only processes it started, and stops and
# deletes everything it made in finally. Run from a checkout whose runtime
# and renderer are built with -Doptimize=ReleaseFast.
$ErrorActionPreference = 'Stop'
# Each Widget logs a frame checkpoint every 300 presents, about 5 s at 60 fps;
# the warm-up and every trial must span at least two of them.
if ($Warmup -lt 10 -or $Window -lt 10) { throw "-Warmup and -Window must each be at least 10 seconds" }
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$run = "native-1p-$PID"
$scratch = Join-Path $PSScriptRoot ".scratch-$run"
$cli = Join-Path $repo 'cli\bin\weaver.js'
$widgetExe = Join-Path $repo 'runtime\zig-out\bin\weaver-widget.exe'
$rendererExe = Join-Path $repo 'renderer\zig-out\bin\weaver-renderer.exe'
$source = Get-Content (Join-Path $repo 'examples\m4b-synthetic\widget.tsx') -Raw
$dirs = 0..($Widgets - 1) | ForEach-Object { Join-Path $repo "examples\$run-$_" }
foreach ($path in @($scratch) + $dirs) {
  if (Test-Path -LiteralPath $path) { throw "refusing to run: $path already exists" }
}
$made = @()
$procs = @()
# weaver-widget is a console program; start it the way weaverd does
# (CREATE_NO_WINDOW, no show-window override) so no console windows appear.
function Start-Hidden([string]$File, [string]$Arguments) {
  $info = [Diagnostics.ProcessStartInfo]::new($File, $Arguments)
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  [Diagnostics.Process]::Start($info)
}
function Get-Presents {
  $counts = @{}
  Get-ChildItem -LiteralPath (Join-Path $scratch 'weaver\logs') -Filter '*.log' -ErrorAction SilentlyContinue | ForEach-Object {
    $line = (Select-String -LiteralPath $_.FullName -Pattern 'widget present' | Select-Object -Last 1).Line
    if ($line -match '^\[([^\]]+)\].* (\d+) rendered frames in (\d+) ms') {
      $counts[$_.BaseName] = @{ at = [datetime]::Parse($Matches[1]).ToUniversalTime(); frames = [double]$Matches[2]; ms = [double]$Matches[3] }
    }
  }
  $counts
}
$saved = @{ LOCALAPPDATA = $env:LOCALAPPDATA; WEAVER_RENDERER_PIPE = $env:WEAVER_RENDERER_PIPE; WEAVER_RENDERER_LOG = $env:WEAVER_RENDERER_LOG }
try {
  New-Item -ItemType Directory $scratch | Out-Null
  for ($i = 0; $i -lt $Widgets; $i++) {
    $dir = $dirs[$i]
    New-Item -ItemType Directory $dir | Out-Null; $made += $dir
    Copy-Item (Join-Path $repo 'examples\m4b-synthetic\tsconfig.json') $dir
    # Same gapless 480x320 tiling as spikes/gpui-host.
    $x = ($i % 4) * 480; $y = [math]::Floor($i / 4) * 320
    $source.Replace('name: "M4b Mixed Synthetic"', "name: `"Synth $i`"").
      Replace('offset: [24, 24]', "offset: [$x, $y]").
      Replace('layer: "desktop"', "layer: `"$Layer`"") | Set-Content (Join-Path $dir 'widget.tsx') -NoNewline
    node $cli bundle $dir | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "weaver bundle failed for $dir" }
  }
  $env:LOCALAPPDATA = $scratch
  $env:WEAVER_RENDERER_PIPE = "\\.\pipe\weaver-spike-renderer-$PID"
  $env:WEAVER_RENDERER_LOG = Join-Path $scratch 'renderer.log'
  $procs += Start-Hidden $rendererExe ''
  Start-Sleep -Milliseconds 500
  $dists = $made | ForEach-Object { '"' + (Join-Path $_ 'dist') + '"' }
  if ($Topology -eq 'one') {
    $procs += Start-Hidden $widgetExe ('--multi ' + ($dists -join ' '))
  } else {
    foreach ($dist in $dists) { $procs += Start-Hidden $widgetExe $dist }
  }
  Start-Sleep -Seconds $Warmup
  $before = Get-Presents
  if ($before.Count -ne $Widgets) { throw "expected $Widgets Widgets presenting after warm-up, found $($before.Count)" }
  for ($t = 1; $t -le $Trials; $t++) {
    $live = @($procs | Where-Object { -not $_.HasExited })
    if ($live.Count -ne $procs.Count) { throw "$($procs.Count - $live.Count) started process(es) exited early" }
    $p0 = Get-Presents
    $t0 = @{}; foreach ($pr in $procs) { $pr.Refresh(); $t0[$pr.Id] = $pr.TotalProcessorTime.TotalMilliseconds }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $Window
    # Read every CPU endpoint and the clock together before any slow counter
    # query, so CIM latency is neither billed to the processes nor left out.
    $t1 = @{}; foreach ($pr in $procs) { $pr.Refresh(); $t1[$pr.Id] = $pr.TotalProcessorTime.TotalMilliseconds }
    $elapsed = $sw.Elapsed.TotalMilliseconds
    # Every requested Widget must have presented during this trial and still
    # be presenting at its end: a checkpoint is logged every 300 presents
    # (5 s at 60 fps), so the newest one must be under 10 s old. A Widget
    # thread that stops inside a shared process cannot shrink the sample.
    $p1 = Get-Presents
    $now = [datetime]::UtcNow
    $rates = foreach ($name in $before.Keys) {
      $a = $p1[$name]; $b = $p0[$name]
      if (-not $a -or $a.frames -le $b.frames) { throw "$name made no frame progress in trial $t" }
      if (($now - $a.at).TotalSeconds -gt 10) { throw "$name stopped presenting during trial $t (last checkpoint $([math]::Round(($now - $a.at).TotalSeconds)) s ago)" }
      '{0} {1:N1}' -f $name, (1000 * ($a.frames - $b.frames) / ($a.ms - $b.ms))
    }
    $rows = foreach ($pr in $procs) {
      $perf = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter "IDProcess=$($pr.Id)"
      [pscustomobject]@{
        name       = $pr.ProcessName
        pid        = $pr.Id
        cpu_pct    = [math]::Round(100 * ($t1[$pr.Id] - $t0[$pr.Id]) / $elapsed, 2)
        priv_ws_mb = [math]::Round($perf.WorkingSetPrivate / 1MB, 2)
        priv_mb    = [math]::Round($pr.PrivateMemorySize64 / 1MB, 2)
        threads    = $pr.Threads.Count
      }
    }
    "=== $Topology, $Widgets widgets, layer $Layer, trial $t"
    $rows | Sort-Object name | Format-Table -AutoSize | Out-String | Write-Output
    "fps this trial (between 300-present checkpoints): $($rates -join ', ')"
    "TOTAL cpu=$([math]::Round(($rows | Measure-Object cpu_pct -Sum).Sum,2))% priv_ws=$([math]::Round(($rows | Measure-Object priv_ws_mb -Sum).Sum,2))MiB priv=$([math]::Round(($rows | Measure-Object priv_mb -Sum).Sum,2))MiB threads=$(($rows | Measure-Object threads -Sum).Sum)"
  }
  if ($CaptureDir) {
    # Window-only captures (Windows Graphics Capture of each Widget's HWND,
    # never the desktop behind it), converted to PNG and named by tile.
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class SpikeWindows {
  delegate bool EnumProc(IntPtr hwnd, IntPtr lparam);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr lparam);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  public static List<IntPtr> For(int[] pids) {
    var set = new HashSet<uint>(); foreach (var p in pids) set.Add((uint)p);
    var found = new List<IntPtr>();
    EnumWindows((h, l) => { uint pid; GetWindowThreadProcessId(h, out pid); if (set.Contains(pid) && IsWindowVisible(h)) found.Add(h); return true; }, IntPtr.Zero);
    return found;
  }
}
'@
    Add-Type -AssemblyName System.Drawing
    $captureExe = Join-Path $repo 'renderer\zig-out\bin\weaver-window-capture.exe'
    New-Item -ItemType Directory -Force $CaptureDir | Out-Null
    foreach ($hwnd in [SpikeWindows]::For([int[]]($procs | ForEach-Object Id))) {
      $rect = New-Object SpikeWindows+RECT
      [SpikeWindows]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
      $tile = [math]::Round($rect.Top / 320) * 4 + [math]::Round($rect.Left / 480)
      $bmp = Join-Path $CaptureDir "tile-$tile.bmp"
      & $captureExe --hwnd ('0x{0:x}' -f $hwnd.ToInt64()) --out $bmp
      if (-not (Test-Path -LiteralPath $bmp)) { "capture failed for tile $tile"; continue }
      $image = [Drawing.Image]::FromFile($bmp)
      $image.Save([IO.Path]::ChangeExtension($bmp, '.png'), [Drawing.Imaging.ImageFormat]::Png); $image.Dispose()
      Remove-Item -LiteralPath $bmp
    }
  }
  if ($Regions) {
    foreach ($pr in ($procs | Select-Object -First 2)) { "--- regions $($pr.ProcessName) $($pr.Id)"; & (Join-Path $PSScriptRoot 'regions.ps1') -ProcessId $pr.Id -Top 12 -Runs }
  }
  Get-ChildItem -LiteralPath (Join-Path $scratch 'weaver\logs') -Filter '*.log' | ForEach-Object {
    (Select-String -LiteralPath $_.FullName -Pattern 'memory receipt|spike layout').Line
  }
} finally {
  foreach ($pr in $procs) { Stop-Process -Id $pr.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 500
  foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
  foreach ($dir in $made) { Remove-Item -LiteralPath $dir -Recurse -Force }
  if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
