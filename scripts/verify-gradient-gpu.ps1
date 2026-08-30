[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) ("artifacts\windows-gradient-gpu-" + [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"))),
    [ValidateRange(3, 25)]
    [int]$Samples = 9
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw "Windows gradient GPU verification requires a Windows host with a D3D11 hardware adapter."
}

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class WeaverGradientWin32 {
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr parameter);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("dwmapi.dll")] public static extern int DwmFlush();

    public static IntPtr FindWindow(uint wantedPid, string wantedTitle) {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr ignored) {
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            if (pid != wantedPid) return true;
            StringBuilder title = new StringBuilder(256);
            GetWindowText(hwnd, title, title.Capacity);
            if (title.ToString() == wantedTitle) { result = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@

$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$NativeRoot = Join-Path $RepoRoot "runtime\native-sdk"
$Cli = Join-Path $RepoRoot "cli\dist\index.js"
$Example = Join-Path $RepoRoot "examples\gradient-stack"
$CaptureHelper = Join-Path $RepoRoot "renderer\zig-out\bin\weaver-window-capture.exe"
$StateRoot = Join-Path $OutputDirectory "state"
$ResultPath = Join-Path $OutputDirectory "results.json"
$ArchivePath = "$OutputDirectory.zip"
$DpiLogPath = Join-Path $OutputDirectory "windows-dpi.log"
$priorLocalAppData = [Environment]::GetEnvironmentVariable("LOCALAPPDATA", "Process")
$priorForceSoftware = [Environment]::GetEnvironmentVariable("WEAVER_FORCE_SOFTWARE", "Process")
$priorGradientBudget = [Environment]::GetEnvironmentVariable("NATIVE_SDK_D3D_GRADIENT_BUDGET_US", "Process")
$priorDpiLog = [Environment]::GetEnvironmentVariable("WEAVER_DPI_LOG", "Process")
$failure = $null
$widgetStarted = $false

$results = [ordered]@{
    schema = "weaver.windows-gradient-gpu.v2"
    status = "running"
    startedUtc = [DateTime]::UtcNow.ToString("o")
    finishedUtc = $null
    repository = $null
    machine = $null
    commands = @()
    checks = @()
    benchmark = $null
    live = $null
    failure = $null
}

function Restore-ProcessEnvironment([string]$name, [string]$value) {
    if ($null -eq $value) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable($name, $value, "Process") }
}

function Invoke-Git([string[]]$arguments, [string]$workingDirectory = $RepoRoot) {
    Push-Location $workingDirectory
    try {
        $value = & git @arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($arguments -join ' ') failed: $($value -join [Environment]::NewLine)" }
        return ($value -join "`n").Trim()
    } finally {
        Pop-Location
    }
}

function Invoke-Recorded([string]$name, [string]$workingDirectory, [string]$executable, [string[]]$arguments) {
    $started = [DateTime]::UtcNow
    Push-Location $workingDirectory
    try {
        $lines = @(& $executable @arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $finished = [DateTime]::UtcNow
    $logName = ($name -replace '[^A-Za-z0-9_.-]', '-') + ".log"
    $logPath = Join-Path $OutputDirectory $logName
    [IO.File]::WriteAllLines($logPath, $lines)
    foreach ($line in $lines) { Write-Host $line }
    $results.commands += [pscustomobject]@{
        name = $name
        command = "$executable $($arguments -join ' ')"
        workingDirectory = $workingDirectory
        exitCode = $exitCode
        durationMs = [Math]::Round(($finished - $started).TotalMilliseconds, 1)
        log = $logName
    }
    if ($exitCode -ne 0) { throw "$name failed with exit code $exitCode. See $logPath" }
    return [pscustomobject]@{ Lines = $lines; Log = $logName }
}

function Add-Check([string]$name, [bool]$passed, [string]$detail) {
    $results.checks += [pscustomobject]@{ name = $name; passed = $passed; detail = $detail }
    if (-not $passed) { throw "${name}: ${detail}" }
}

function Wait-Until([scriptblock]$condition, [string]$description, [int]$seconds = 30) {
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    do {
        if (& $condition) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $description"
}

function Read-Status {
    $path = Join-Path $StateRoot "weaver\status.json"
    if (-not (Test-Path $path)) { return $null }
    try { return Get-Content $path -Raw | ConvertFrom-Json } catch { return $null }
}

function Capture-Window([IntPtr]$hwnd, [string]$path, [string]$referencePath) {
    $rect = New-Object WeaverGradientWin32+RECT
    Add-Check "gradient-window-client-rect" ([WeaverGradientWin32]::GetClientRect($hwnd, [ref]$rect)) "hwnd=0x$('{0:x}' -f $hwnd.ToInt64())"
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    Add-Check "gradient-window-positive-size" ($width -gt 0 -and $height -gt 0) "${width}x${height}"
    $hwndTopmost = [IntPtr](-1)
    $hwndNotTopmost = [IntPtr](-2)
    $flags = 0x0001 -bor 0x0002 -bor 0x0010
    $bitmapPath = "$path.desktop-duplication.bmp"
    $bitmap = $null
    try {
        Add-Check "gradient-window-topmost" ([WeaverGradientWin32]::SetWindowPos($hwnd, $hwndTopmost, 0, 0, 0, 0, $flags)) "hwnd=0x$('{0:x}' -f $hwnd.ToInt64())"
        $flushResult = [WeaverGradientWin32]::DwmFlush()
        Add-Check "gradient-window-dwm-flush" ($flushResult -ge 0) "hresult=0x$('{0:x8}' -f ([uint32]$flushResult))"
        Invoke-Recorded "gradient-window-capture" $RepoRoot $CaptureHelper @("--hwnd", "0x$('{0:x}' -f $hwnd.ToInt64())", "--out", $bitmapPath) | Out-Null
    } finally {
        [WeaverGradientWin32]::SetWindowPos($hwnd, $hwndNotTopmost, 0, 0, 0, 0, $flags) | Out-Null
    }
    Add-Check "gradient-window-capture-bitmap" (Test-Path $bitmapPath) $bitmapPath
    $bitmap = [Drawing.Bitmap]::new($bitmapPath)
    Add-Check "gradient-window-capture-size" ($bitmap.Width -eq $width -and $bitmap.Height -eq $height) "helper=$($bitmap.Width)x$($bitmap.Height) client=${width}x${height}"
    $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    Add-Check "gradient-reference-image-exists" (Test-Path $referencePath) $referencePath
    $reference = [Drawing.Bitmap]::new($referencePath)
    $referenceWidth = $reference.Width
    $referenceHeight = $reference.Height
    $colors = [Collections.Generic.HashSet[int]]::new()
    $dimensionsMatch = $referenceWidth -eq $width -and $referenceHeight -eq $height
    $sampleCount = 0
    $closeSampleCount = 0
    [double]$absoluteChannelError = 0
    try {
        if ($dimensionsMatch) {
            for ($y = 0; $y -lt $height; $y += 4) {
                for ($x = 0; $x -lt $width; $x += 4) {
                    $actual = $bitmap.GetPixel($x, $y)
                    $expected = $reference.GetPixel($x, $y)
                    [void]$colors.Add($actual.ToArgb())
                    $redError = [Math]::Abs([int]$actual.R - [int]$expected.R)
                    $greenError = [Math]::Abs([int]$actual.G - [int]$expected.G)
                    $blueError = [Math]::Abs([int]$actual.B - [int]$expected.B)
                    $absoluteChannelError += $redError + $greenError + $blueError
                    if (($redError + $greenError + $blueError) -le 96) { $closeSampleCount++ }
                    $sampleCount++
                }
            }
        }
    } finally {
        $reference.Dispose()
        $bitmap.Dispose()
        Remove-Item -LiteralPath $bitmapPath -Force -ErrorAction SilentlyContinue
    }
    $meanAbsoluteChannelError = if ($sampleCount -eq 0) { [double]::PositiveInfinity } else { $absoluteChannelError / (3.0 * $sampleCount) }
    $closeSamplePercent = if ($sampleCount -eq 0) { 0.0 } else { 100.0 * $closeSampleCount / $sampleCount }
    Add-Check "gradient-capture-reference-dimensions" $dimensionsMatch "capture=${width}x${height} reference=${referenceWidth}x${referenceHeight}"
    Add-Check "gradient-window-nonuniform" ($colors.Count -ge 256) "sampledUniqueArgb=$($colors.Count)"
    Add-Check "gradient-capture-reference-similarity" ($meanAbsoluteChannelError -le 40.0 -and $closeSamplePercent -ge 55.0) "meanAbsoluteChannelError=$([Math]::Round($meanAbsoluteChannelError, 3)) closeSamplePercent=$([Math]::Round($closeSamplePercent, 3))"
    return [pscustomobject]@{
        widthPx = $width
        heightPx = $height
        sampledUniqueArgb = $colors.Count
        referenceSampleCount = $sampleCount
        meanAbsoluteChannelError = [Math]::Round($meanAbsoluteChannelError, 3)
        closeSamplePercent = [Math]::Round($closeSamplePercent, 3)
    }
}

function Sample-Processes([int]$widgetPid, [int]$rendererPid, [int]$seconds = 10) {
    $beforeWidget = Get-Process -Id $widgetPid
    $beforeRenderer = Get-Process -Id $rendererPid
    $widgetCpu = $beforeWidget.TotalProcessorTime.TotalMilliseconds
    $rendererCpu = $beforeRenderer.TotalProcessorTime.TotalMilliseconds
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $seconds
    $watch.Stop()
    $afterWidget = Get-Process -Id $widgetPid
    $afterRenderer = Get-Process -Id $rendererPid
    return [pscustomobject]@{
        seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 3)
        widgetCpuOneCorePercent = [Math]::Round(100.0 * ($afterWidget.TotalProcessorTime.TotalMilliseconds - $widgetCpu) / $watch.Elapsed.TotalMilliseconds, 3)
        rendererCpuOneCorePercent = [Math]::Round(100.0 * ($afterRenderer.TotalProcessorTime.TotalMilliseconds - $rendererCpu) / $watch.Elapsed.TotalMilliseconds, 3)
        widgetPrivateMiB = [Math]::Round($afterWidget.PrivateMemorySize64 / 1MB, 3)
        rendererPrivateMiB = [Math]::Round($afterRenderer.PrivateMemorySize64 / 1MB, 3)
    }
}

try {
    foreach ($tool in @("git", "node", "npm", "zig")) {
        Add-Check "tool-$tool" ($null -ne (Get-Command $tool -ErrorAction SilentlyContinue)) "$tool is on PATH"
    }
    $weaverCommit = Invoke-Git @("rev-parse", "HEAD")
    $expectedNativeCommit = Invoke-Git @("rev-parse", "HEAD:runtime/native-sdk")
    $actualNativeCommit = Invoke-Git @("rev-parse", "HEAD") $NativeRoot
    $trackedChanges = Invoke-Git @("status", "--porcelain", "--untracked-files=no")
    Add-Check "native-submodule-pin" ($expectedNativeCommit -eq $actualNativeCommit) "expected=$expectedNativeCommit actual=$actualNativeCommit"
    Add-Check "tracked-worktree-clean" ([string]::IsNullOrWhiteSpace($trackedChanges)) $trackedChanges
    $adapters = @(Get-CimInstance Win32_VideoController | ForEach-Object {
        [pscustomobject]@{
            name = $_.Name
            driverVersion = $_.DriverVersion
            adapterRamBytes = $(if ($null -eq $_.AdapterRAM) { $null } else { [uint64]$_.AdapterRAM })
            pnpDeviceId = $_.PNPDeviceID
        }
    })
    $results.repository = [pscustomobject]@{
        weaverCommit = $weaverCommit
        expectedNativeCommit = $expectedNativeCommit
        actualNativeCommit = $actualNativeCommit
    }
    $results.machine = [pscustomobject]@{
        computerName = $env:COMPUTERNAME
        os = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture)
        powershell = $PSVersionTable.PSVersion.ToString()
        zig = (& zig version).Trim()
        node = (& node --version).Trim()
        adapters = $adapters
    }

    Invoke-Recorded "npm-ci" $RepoRoot "npm" @("ci") | Out-Null
    Invoke-Recorded "npm-build" $RepoRoot "npm" @("run", "build") | Out-Null
    Invoke-Recorded "npm-test" $RepoRoot "npm" @("test") | Out-Null
    Invoke-Recorded "npm-typecheck" $RepoRoot "npm" @("run", "typecheck") | Out-Null
    Invoke-Recorded "release-audit" $RepoRoot "npm" @("run", "audit:release") | Out-Null
    Invoke-Recorded "native-gradient-semantics" $NativeRoot "zig" @("build", "test-canvas", "-Doptimize=ReleaseFast") | Out-Null
    Invoke-Recorded "native-d3d-decoder-shader" $NativeRoot "zig" @("build", "test-windows-d3d-presenter", "-Doptimize=ReleaseFast") | Out-Null
    Invoke-Recorded "runtime-build" (Join-Path $RepoRoot "runtime") "zig" @("build", "-Dcpu=baseline", "-Doptimize=ReleaseFast", "-Dweb-layer=exclude", "-Dtrace=off") | Out-Null
    Invoke-Recorded "host-build" (Join-Path $RepoRoot "host") "zig" @("build", "-Dcpu=baseline", "-Doptimize=ReleaseFast") | Out-Null
    Invoke-Recorded "renderer-build" (Join-Path $RepoRoot "renderer") "zig" @("build", "-Dcpu=baseline", "-Doptimize=ReleaseFast") | Out-Null
    Invoke-Recorded "renderer-capture-build" (Join-Path $RepoRoot "renderer") "zig" @("build", "window-capture", "-Dcpu=baseline", "-Doptimize=ReleaseFast") | Out-Null
    Add-Check "gradient-capture-helper" (Test-Path $CaptureHelper) $CaptureHelper

    Remove-Item Env:NATIVE_SDK_D3D_GRADIENT_BUDGET_US -ErrorAction SilentlyContinue
    $timings = @()
    $selectedAdapter = $null
    for ($sample = 1; $sample -le $Samples; $sample++) {
        $run = Invoke-Recorded "d3d-gradient-sample-$('{0:d2}' -f $sample)" $NativeRoot "zig" @("build", "bench-windows-d3d-gradient", "-Doptimize=ReleaseFast")
        $joined = $run.Lines -join "`n"
        Add-Check "d3d-clean-command-report-$sample" ($joined -notmatch '(?m)^failed command:') $joined
        $timingMatch = [regex]::Match($joined, 'mesh-gradient 512x512 16-patch Oklab GPU ([0-9]+(?:\.[0-9]+)?)us/draw')
        Add-Check "d3d-gradient-timestamp-$sample" $timingMatch.Success $joined
        $timings += [double]$timingMatch.Groups[1].Value
        $adapterMatch = [regex]::Match($joined, 'adapter vendor=(0x[0-9a-fA-F]+) device=(0x[0-9a-fA-F]+) dedicated=([0-9]+)MiB shared=([0-9]+)MiB')
        Add-Check "d3d-hardware-adapter-$sample" $adapterMatch.Success $joined
        $sampleAdapter = [pscustomobject]@{
            vendor = $adapterMatch.Groups[1].Value
            device = $adapterMatch.Groups[2].Value
            dedicatedMiB = [uint64]$adapterMatch.Groups[3].Value
            sharedMiB = [uint64]$adapterMatch.Groups[4].Value
        }
        if ($null -eq $selectedAdapter) { $selectedAdapter = $sampleAdapter }
        else { Add-Check "d3d-stable-adapter-$sample" (($selectedAdapter | ConvertTo-Json -Compress) -eq ($sampleAdapter | ConvertTo-Json -Compress)) ($sampleAdapter | ConvertTo-Json -Compress) }
    }
    $orderedTimings = @($timings | Sort-Object)
    $median = if (($orderedTimings.Count % 2) -eq 1) {
        $orderedTimings[[Math]::Floor($orderedTimings.Count / 2)]
    } else {
        ($orderedTimings[$orderedTimings.Count / 2 - 1] + $orderedTimings[$orderedTimings.Count / 2]) / 2.0
    }
    $p90 = $orderedTimings[[Math]::Ceiling(0.9 * $orderedTimings.Count) - 1]
    $results.benchmark = [pscustomobject]@{
        scenario = "512x512 16-patch Oklab mesh, 8 warmups, 64 timestamped draws per sample"
        selectedAdapter = $selectedAdapter
        samplesUsPerDraw = $timings
        medianUsPerDraw = [Math]::Round($median, 3)
        p90UsPerDraw = [Math]::Round($p90, 3)
        budgetUsPerDraw = $null
        note = "This establishes a machine baseline. No cross-GPU budget is assumed."
    }

    Invoke-Recorded "gradient-example-bundle" $RepoRoot "node" @($Cli, "bundle", $Example) | Out-Null
    $manifest = Get-Content (Join-Path $Example "dist\widget.json") -Raw | ConvertFrom-Json
    Add-Check "gradient-manifest-selects-gpu" ($manifest.renderBackend -eq "gpu") "renderBackend=$($manifest.renderBackend)"
    $referenceName = "gradient-stack-reference.png"
    Invoke-Recorded "gradient-reference-capture" $RepoRoot "node" @($Cli, "capture", $Example, "--out", (Join-Path $OutputDirectory $referenceName)) | Out-Null
    [IO.Directory]::CreateDirectory($StateRoot) | Out-Null
    $env:LOCALAPPDATA = $StateRoot
    $env:WEAVER_DPI_LOG = $DpiLogPath
    Remove-Item Env:WEAVER_FORCE_SOFTWARE -ErrorAction SilentlyContinue
    Invoke-Recorded "gradient-example-install" $RepoRoot "node" @($Cli, "install", $Example) | Out-Null
    $widgetStarted = $true
    Wait-Until {
        $status = Read-Status
        if ($null -eq $status) { return $false }
        $widget = @($status.widgets | Where-Object { $_.name -eq "Gradient Stack" }) | Select-Object -First 1
        if ($null -eq $widget -or $widget.pid -le 0 -or $widget.state -ne "running" -or $widget.backend -ne "gpu" -or -not (Test-Path $DpiLogPath)) { return $false }
        $dpiLog = Get-Content $DpiLogPath -Raw
        return $dpiLog -match "renderer-surface .* widget=$([int]$widget.pid) .* action=(created|resized-recreated|resized-reused|geometry-reused)"
    } "Gradient Stack completing a shared D3D11 presentation"
    $status = Read-Status
    $widget = @($status.widgets | Where-Object { $_.name -eq "Gradient Stack" }) | Select-Object -First 1
    $renderer = @($status.widgets | Where-Object { $_.name -eq "renderer" }) | Select-Object -First 1
    Add-Check "gradient-live-backend" ($widget.backend -eq "gpu") "pid=$($widget.pid) backend=$($widget.backend)"
    $dpiEvidence = Get-Content $DpiLogPath -Raw
    Add-Check "gradient-live-d3d-completion" ($dpiEvidence -match "renderer-surface .* widget=$([int]$widget.pid) .* action=(created|resized-recreated|resized-reused|geometry-reused)") "windows-dpi.log contains the widget's completed shared surface"
    $rendererPid = if ($null -eq $renderer) { 0 } else { [int]$renderer.pid }
    Add-Check "gradient-shared-renderer" ($rendererPid -gt 0) "rendererPid=$rendererPid"
    $hwnd = [WeaverGradientWin32]::FindWindow([uint32]$widget.pid, "Gradient Stack")
    Add-Check "gradient-live-window" ($hwnd -ne [IntPtr]::Zero -and [WeaverGradientWin32]::IsWindow($hwnd)) "hwnd=0x$('{0:x}' -f $hwnd.ToInt64())"
    $screenshotName = "gradient-stack-gpu.png"
    $capture = Capture-Window $hwnd (Join-Path $OutputDirectory $screenshotName) (Join-Path $OutputDirectory $referenceName)
    $processSample = Sample-Processes ([int]$widget.pid) $rendererPid
    $results.live = [pscustomobject]@{
        widgetPid = [int]$widget.pid
        rendererPid = $rendererPid
        backend = $widget.backend
        reference = $referenceName
        screenshot = $screenshotName
        capture = $capture
        dpiLog = "windows-dpi.log"
        idleProcessSample = $processSample
        status = $status
    }
    $results.status = "passed"
} catch {
    $failure = $_
    $results.status = "failed"
    $results.failure = [pscustomobject]@{
        message = $_.Exception.Message
        scriptStackTrace = $_.ScriptStackTrace
    }
} finally {
    if ($widgetStarted -and (Test-Path $Cli)) {
        try {
            $cleanup = @(& node $Cli down 2>&1 | ForEach-Object { $_.ToString() })
            [IO.File]::WriteAllLines((Join-Path $OutputDirectory "cleanup.log"), $cleanup)
        } catch {
            [IO.File]::WriteAllText((Join-Path $OutputDirectory "cleanup-error.log"), $_.Exception.Message)
        }
    }
    Restore-ProcessEnvironment "LOCALAPPDATA" $priorLocalAppData
    Restore-ProcessEnvironment "WEAVER_FORCE_SOFTWARE" $priorForceSoftware
    Restore-ProcessEnvironment "NATIVE_SDK_D3D_GRADIENT_BUDGET_US" $priorGradientBudget
    Restore-ProcessEnvironment "WEAVER_DPI_LOG" $priorDpiLog
    $results.finishedUtc = [DateTime]::UtcNow.ToString("o")
    [IO.File]::WriteAllText($ResultPath, ($results | ConvertTo-Json -Depth 12))
    if (Test-Path $ArchivePath) { Remove-Item -LiteralPath $ArchivePath -Force }
    Compress-Archive -Path (Join-Path $OutputDirectory "*") -DestinationPath $ArchivePath
    Write-Host "Windows gradient GPU evidence: $ArchivePath"
}

if ($null -ne $failure) { throw $failure }
Write-Host "Windows gradient GPU verification passed. Return the ZIP above without unpacking it."
