param(
  [string]$Mode = 'clock',
  [int]$Windows = 1,
  [int]$Processes = 1,
  [int]$Warmup = 10,
  [int]$Window = 15,
  [string[]]$Extra = @()
)
# Same counters as docs/m4a-results.md: private WS from
# Win32_PerfFormattedData_PerfProc_Process.WorkingSetPrivate, private bytes from
# PrivateMemorySize64, CPU = TotalProcessorTime delta as % of one logical core.
$exe = Join-Path $PSScriptRoot 'target\release\gpui-spike.exe'
$procs = @()
# Every process this run starts is stopped in finally, even if sampling fails
# or is interrupted, so stray windows never load the next comparison.
try {
  for ($p = 0; $p -lt $Processes; $p++) {
    $log = Join-Path $PSScriptRoot "run-$Mode-$Windows-$p.log"
    Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
    $spikeArgs = @('--mode', $Mode, '--windows', $Windows, '--slot', ($p * $Windows)) + $Extra
    $procs += Start-Process -FilePath $exe -ArgumentList $spikeArgs -RedirectStandardOutput $log -PassThru
  }
  Start-Sleep -Seconds $Warmup
  $t0 = @{}; foreach ($pr in $procs) { $pr.Refresh(); $t0[$pr.Id] = $pr.TotalProcessorTime.TotalMilliseconds }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  Start-Sleep -Seconds $Window
  # Read every CPU endpoint and the clock together before any slow counter query,
  # so CIM latency is neither billed to the processes nor left out of the window.
  $t1 = @{}; foreach ($pr in $procs) { $pr.Refresh(); $t1[$pr.Id] = $pr.TotalProcessorTime.TotalMilliseconds }
  $elapsed = $sw.Elapsed.TotalMilliseconds
  $rows = foreach ($pr in $procs) {
    $perf = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter "IDProcess=$($pr.Id)"
    [pscustomobject]@{
      pid        = $pr.Id
      cpu_pct    = [math]::Round(100 * ($t1[$pr.Id] - $t0[$pr.Id]) / $elapsed, 2)
      priv_ws_mb = [math]::Round($perf.WorkingSetPrivate / 1MB, 2)
      priv_mb    = [math]::Round($pr.PrivateMemorySize64 / 1MB, 2)
      threads    = $pr.Threads.Count
    }
  }
} finally {
  foreach ($pr in $procs) { Stop-Process -Id $pr.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 500
}
$rows | Format-Table -AutoSize | Out-String | Write-Output
"TOTAL cpu=$([math]::Round(($rows | Measure-Object cpu_pct -Sum).Sum,2))% priv_ws=$([math]::Round(($rows | Measure-Object priv_ws_mb -Sum).Sum,2))MiB priv=$([math]::Round(($rows | Measure-Object priv_mb -Sum).Sum,2))MiB threads=$(($rows | Measure-Object threads -Sum).Sum)"
for ($p = 0; $p -lt $Processes; $p++) {
  "log[$p]: " + ((Get-Content (Join-Path $PSScriptRoot "run-$Mode-$Windows-$p.log") -ErrorAction SilentlyContinue) -join ' | ')
}
