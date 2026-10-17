param([int]$Widgets = 10, [int]$Trials = 3, [int]$Warmup = 25, [string]$Layer = 'normal')
# Weaver side of the A/B: N tiled copies of examples/m4b-synthetic, installed
# into a scratch LOCALAPPDATA so the real registry is never touched. Run from a
# checkout whose runtime, host and renderer are built with ReleaseFast.
# Everything it creates is named for this run and removed afterwards; it
# refuses to start if any of those paths already exist, or if any weaverd is
# running: the daemon is a per-user singleton (a fixed named mutex), so a
# scratch LOCALAPPDATA would not isolate it and `weaver down` would stop the
# user's own Widgets.
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$run = "gpui-ab-$PID"
$scratch = Join-Path $PSScriptRoot ".scratch-$run"
$cli = Join-Path $repo 'cli\bin\weaver.js'
$source = Get-Content (Join-Path $repo 'examples\m4b-synthetic\widget.tsx') -Raw
$dirs = 0..($Widgets - 1) | ForEach-Object { Join-Path $repo "examples\$run-$_" }
if (Get-Process -Name weaverd -ErrorAction SilentlyContinue) {
  throw 'refusing to run: weaverd is already running. Stop it with "weaver down" first.'
}
foreach ($path in @($scratch) + $dirs) {
  if (Test-Path -LiteralPath $path) { throw "refusing to run: $path already exists" }
}
$made = @()
$savedAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $scratch
try {
  for ($i = 0; $i -lt $Widgets; $i++) {
    $dir = $dirs[$i]
    New-Item -ItemType Directory $dir | Out-Null; $made += $dir
    Copy-Item (Join-Path $repo 'examples\m4b-synthetic\tsconfig.json') $dir
    # Same gapless 480x320 tiling as the GPUI spike's --slot layout.
    $x = ($i % 4) * 480; $y = [math]::Floor($i / 4) * 320
    $source.Replace('name: "M4b Mixed Synthetic"', "name: `"Synth $i`"").
      Replace('offset: [24, 24]', "offset: [$x, $y]").
      Replace('layer: "desktop"', "layer: `"$Layer`"") | Set-Content (Join-Path $dir 'widget.tsx') -NoNewline
  }
  node $cli up | Out-Null
  foreach ($dir in $made) { node $cli install $dir | Out-Null }
  Start-Sleep -Seconds $Warmup
  node $cli status
  for ($t = 1; $t -le $Trials; $t++) {
    "=== weaver, $Widgets widgets, trial $t"
    & (Join-Path $PSScriptRoot 'measure-names.ps1') -ExpectWidgets $Widgets
  }
  for ($i = 0; $i -lt $Widgets; $i++) {
    ((node $cli logs "Synth $i" 2>&1 | Select-String 'widget present' | Select-Object -Last 1).Line)
  }
} finally {
  node $cli down | Out-Null
  $env:LOCALAPPDATA = $savedAppData
  foreach ($dir in $made) { Remove-Item -LiteralPath $dir -Recurse -Force }
  if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
