[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) "docs\dpi-evidence")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class WeaverDpiWin32 {
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr parameter);
    public delegate bool EnumMonitorsProc(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr parameter);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, EnumMonitorsProc callback, IntPtr parameter);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
    [DllImport("dwmapi.dll")] public static extern int DwmFlush();

    public static IntPtr FindWindowForPid(uint wantedPid) {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr ignored) {
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            if (pid != wantedPid) return true;
            StringBuilder title = new StringBuilder(256);
            GetWindowText(hwnd, title, title.Capacity);
            if (title.ToString() == "DPI Diagnostic") { result = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static IntPtr FindGpuChild(IntPtr parent) {
        IntPtr result = IntPtr.Zero;
        EnumChildWindows(parent, delegate(IntPtr hwnd, IntPtr ignored) {
            StringBuilder name = new StringBuilder(256);
            GetClassName(hwnd, name, name.Capacity);
            if (name.ToString().Contains("GpuSurface")) { result = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static IntPtr[] HideOtherWindows(IntPtr keep) {
        List<IntPtr> hidden = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hwnd, IntPtr ignored) {
            if (hwnd == keep || !IsWindowVisible(hwnd) || IsIconic(hwnd)) return true;
            StringBuilder title = new StringBuilder(256);
            GetWindowText(hwnd, title, title.Capacity);
            if (title.Length == 0) return true;
            StringBuilder name = new StringBuilder(256);
            GetClassName(hwnd, name, name.Capacity);
            string cls = name.ToString();
            if (cls == "Shell_TrayWnd" || cls == "Progman" || cls == "WorkerW") return true;
            RECT rect;
            if (!GetWindowRect(hwnd, out rect) || rect.Right <= rect.Left || rect.Bottom <= rect.Top) return true;
            if (ShowWindow(hwnd, 0)) hidden.Add(hwnd);
            return true;
        }, IntPtr.Zero);
        return hidden.ToArray();
    }

    public static void RestoreWindows(IntPtr[] windows) {
        if (windows == null) return;
        foreach (IntPtr hwnd in windows) if (IsWindow(hwnd)) ShowWindow(hwnd, 5);
    }

    public static long MakeLParam(int x, int y) {
        return (long)((y & 0xffff) << 16 | (x & 0xffff));
    }

    public static string[] MonitorDpis() {
        List<string> values = new List<string>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
            delegate(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr ignored) {
                uint x, y;
                int hr = GetDpiForMonitor(monitor, 0, out x, out y);
                values.Add(String.Format("{0},{1},{2},{3};dpi={4};hr={5}",
                    rect.Left, rect.Top, rect.Right, rect.Bottom, y, hr));
                return true;
            }, IntPtr.Zero);
        return values.ToArray();
    }
}
'@

$DpiMessage = 0x8000 + 0x3D1
$WmLeftButtonDown = 0x0201
$WmLeftButtonUp = 0x0202
$SwpNoSize = 0x0001
$SwpNoMove = 0x0002
$SwpNoActivate = 0x0010
$HwndTopmost = [IntPtr](-1)
$HwndNoTopmost = [IntPtr](-2)
$matrix = @(
    [pscustomobject]@{ Dpi = 96;  Percent = 100; Width = 480; Height = 320; Seam = 420; Y230 = 230; X100 = 100 },
    [pscustomobject]@{ Dpi = 120; Percent = 125; Width = 600; Height = 400; Seam = 525; Y230 = 288; X100 = 125 },
    [pscustomobject]@{ Dpi = 144; Percent = 150; Width = 720; Height = 480; Seam = 630; Y230 = 345; X100 = 150 },
    [pscustomobject]@{ Dpi = 168; Percent = 175; Width = 840; Height = 560; Seam = 735; Y230 = 403; X100 = 175 },
    [pscustomobject]@{ Dpi = 192; Percent = 200; Width = 960; Height = 640; Seam = 840; Y230 = 460; X100 = 200 }
)

$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$cli = Join-Path $RepoRoot "cli\dist\index.js"
$fixture = Join-Path $RepoRoot "test\fixtures\dpi-diagnostic"
$results = [ordered]@{
    startedUtc = [DateTime]::UtcNow.ToString("o")
    repoRoot = $RepoRoot
    outputDirectory = $OutputDirectory
    monitors = @([WeaverDpiWin32]::MonitorDpis())
    commands = @()
    gpu = @()
    software = @()
    currentMonitor = $null
    checks = @()
}

function Add-Check([string]$name, [bool]$passed, [string]$detail) {
    $results.checks += [pscustomobject]@{ name = $name; passed = $passed; detail = $detail }
    if (-not $passed) { throw "${name}: ${detail}" }
}

function Invoke-Recorded([string]$name, [string[]]$arguments) {
    $commandOutput = & $arguments[0] $arguments[1..($arguments.Count - 1)]
    $code = $LASTEXITCODE
    foreach ($line in $commandOutput) { Write-Host $line }
    $results.commands += [pscustomobject]@{ name = $name; command = ($arguments -join " "); exitCode = $code }
    if ($code -ne 0) { throw "Command failed (${code}): $($arguments -join ' ')" }
}

function Wait-Until([scriptblock]$condition, [string]$description, [int]$seconds = 15) {
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    do {
        if (& $condition) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for ${description}"
}

function Read-Status([string]$localData) {
    $path = Join-Path $localData "weaver\status.json"
    if (-not (Test-Path $path)) { return $null }
    try { return Get-Content $path -Raw | ConvertFrom-Json } catch { return $null }
}

function Start-Run([string]$name, [bool]$forceSoftware, [bool]$diagnostic) {
    $localData = Join-Path $OutputDirectory "state-$name"
    [IO.Directory]::CreateDirectory($localData) | Out-Null
    $env:LOCALAPPDATA = $localData
    $env:WEAVER_DPI_LOG = Join-Path $OutputDirectory "$name-dpi-events.txt"
    if ($diagnostic) {
        $env:WEAVER_DPI_DIAGNOSTIC = "1"
        $env:WEAVER_DPI_TEST_DPI = "96"
    } else {
        Remove-Item Env:WEAVER_DPI_DIAGNOSTIC -ErrorAction SilentlyContinue
        Remove-Item Env:WEAVER_DPI_TEST_DPI -ErrorAction SilentlyContinue
    }
    if ($forceSoftware) { $env:WEAVER_FORCE_SOFTWARE = "1" }
    else { Remove-Item Env:WEAVER_FORCE_SOFTWARE -ErrorAction SilentlyContinue }
    try {
        Invoke-Recorded "$name-install" @("node", $cli, "install", $fixture)
        Wait-Until {
            $status = Read-Status $localData
            if (-not $status) { return $false }
            $widget = $status.widgets | Where-Object name -eq "DPI Diagnostic"
            return ($widget -and $widget.state -eq "running" -and $widget.pid -gt 0)
        } "$name widget startup"
        $status = Read-Status $localData
        $widget = $status.widgets | Where-Object name -eq "DPI Diagnostic"
        $expectedBackend = if ($forceSoftware) { "software" } else { "gpu" }
        Wait-Until {
            $fresh = Read-Status $localData
            if (-not $fresh) { return $false }
            $live = $fresh.widgets | Where-Object name -eq "DPI Diagnostic"
            return ($live -and $live.backend -eq $expectedBackend)
        } "$name backend $expectedBackend"
        $status = Read-Status $localData
        $widget = $status.widgets | Where-Object name -eq "DPI Diagnostic"
        $hwnd = [WeaverDpiWin32]::FindWindowForPid([uint32]$widget.pid)
        Add-Check "$name-window" ($hwnd -ne [IntPtr]::Zero) "pid=$($widget.pid) hwnd=0x$('{0:x}' -f $hwnd.ToInt64())"
        $raised = [WeaverDpiWin32]::SetWindowPos($hwnd, $HwndTopmost, 0, 0, 0, 0,
            $SwpNoMove -bor $SwpNoSize -bor $SwpNoActivate)
        Add-Check "$name-raise" $raised "SetWindowPos(HWND_TOPMOST)"
        $hidden = [WeaverDpiWin32]::HideOtherWindows($hwnd)
        return [pscustomobject]@{ Name = $name; LocalData = $localData; Pid = [int]$widget.pid; Hwnd = $hwnd; Backend = $expectedBackend; HiddenWindows = $hidden }
    } catch {
        & node $cli down 2>$null | Out-Null
        throw
    }
}

function Stop-Run($run) {
    if (-not $run) { return }
    $env:LOCALAPPDATA = $run.LocalData
    [WeaverDpiWin32]::SetWindowPos($run.Hwnd, $HwndNoTopmost, 0, 0, 0, 0,
        $SwpNoMove -bor $SwpNoSize -bor $SwpNoActivate) | Out-Null
    Invoke-Recorded "$($run.Name)-down" @("node", $cli, "down")
    Wait-Until { -not [WeaverDpiWin32]::IsWindow($run.Hwnd) } "$($run.Name) window shutdown"
    [WeaverDpiWin32]::RestoreWindows($run.HiddenWindows)
}

function Get-ClientGeometry([IntPtr]$hwnd) {
    $rect = New-Object WeaverDpiWin32+RECT
    if (-not [WeaverDpiWin32]::GetClientRect($hwnd, [ref]$rect)) { throw "GetClientRect failed" }
    $point = New-Object WeaverDpiWin32+POINT
    $point.X = 0; $point.Y = 0
    if (-not [WeaverDpiWin32]::ClientToScreen($hwnd, [ref]$point)) { throw "ClientToScreen failed" }
    [pscustomobject]@{ X = $point.X; Y = $point.Y; Width = $rect.Right - $rect.Left; Height = $rect.Bottom - $rect.Top }
}

function Set-DiagnosticDpi($run, $row) {
    $reply = [WeaverDpiWin32]::SendMessage($run.Hwnd, [uint32]$DpiMessage,
        [UIntPtr]([uint32]$row.Dpi), [IntPtr]::Zero)
    Add-Check "$($run.Name)-message-$($row.Percent)" ($reply -ne [IntPtr]::Zero) "dpi=$($row.Dpi)"
    Wait-Until {
        $geometry = Get-ClientGeometry $run.Hwnd
        $geometry.Width -eq $row.Width -and $geometry.Height -eq $row.Height
    } "$($run.Name) $($row.Percent)% geometry"
    [WeaverDpiWin32]::DwmFlush() | Out-Null
    Start-Sleep -Milliseconds 250
}

function Capture-Client([IntPtr]$hwnd, [string]$path) {
    $geometry = Get-ClientGeometry $hwnd
    $bitmap = [Drawing.Bitmap]::new($geometry.Width, $geometry.Height,
        [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($geometry.X, $geometry.Y, 0, 0,
            ([Drawing.Size]::new($geometry.Width, $geometry.Height)),
            [Drawing.CopyPixelOperation]::SourceCopy)
    } finally { $graphics.Dispose() }
    $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    return $bitmap
}

function Assert-Color($bitmap, [int]$x, [int]$y, [string]$hex, [string]$label, [int]$tolerance = 12) {
    $expected = [Drawing.ColorTranslator]::FromHtml($hex)
    $actual = $bitmap.GetPixel($x, $y)
    $distance = [Math]::Max([Math]::Abs([int]$actual.R - [int]$expected.R),
        [Math]::Max([Math]::Abs([int]$actual.G - [int]$expected.G),
            [Math]::Abs([int]$actual.B - [int]$expected.B)))
    Add-Check $label ($distance -le $tolerance) "at=($x,$y) actual=#$('{0:X2}{1:X2}{2:X2}' -f $actual.R,$actual.G,$actual.B) expected=$hex tolerance=$tolerance"
}

function Assert-Occupied($bitmap, [int]$x, [int]$y, [string]$label) {
    $actual = $bitmap.GetPixel($x, $y)
    $peak = [Math]::Max([int]$actual.R, [Math]::Max([int]$actual.G, [int]$actual.B))
    Add-Check $label ($peak -ge 50) "at=($x,$y) actual=#$('{0:X2}{1:X2}{2:X2}' -f $actual.R,$actual.G,$actual.B) minimumPeak=50"
}

function Verify-BasePixels($bitmap, $row, [string]$prefix) {
    Assert-Color $bitmap 5 5 "#FF0055" "$prefix-top-left" 64
    Assert-Color $bitmap ([int]($row.Width / 2)) 0 "#FF0055" "$prefix-top-edge" 64
    Assert-Color $bitmap 0 $row.X100 "#00FF66" "$prefix-left-edge" 64
    Assert-Color $bitmap ($row.Width - 1) $row.X100 "#00A0FF" "$prefix-right-edge" 48
    # Button material antialiases the exact rounded corner with a scale-varying
    # white highlight. Prove the exact corner is occupied, then prove its
    # distinct marker color farther inside the same retained region.
    Assert-Occupied $bitmap ($row.Width - 5) 5 "$prefix-top-right-occupied"
    Assert-Color $bitmap ($row.Width - 40) 40 "#00A0FF" "$prefix-top-right-marker" 48
    Assert-Color $bitmap $row.X100 ($row.Height - 1) "#FFD400" "$prefix-bottom-edge" 48
    Assert-Occupied $bitmap 5 ($row.Height - 5) "$prefix-bottom-left-occupied"
    Assert-Color $bitmap 40 ($row.Height - 40) "#FFD400" "$prefix-bottom-left-marker" 48
    Assert-Occupied $bitmap ($row.Width - 5) ($row.Height - 5) "$prefix-bottom-right-occupied"
    Assert-Color $bitmap ($row.Width - 40) ($row.Height - 40) "#A855F7" "$prefix-bottom-right-marker" 48
    Assert-Color $bitmap ($row.Seam - 1) $row.Y230 "#00D9FF" "$prefix-immediate-seam" 96
    Assert-Color $bitmap $row.Seam $row.Y230 "#00A0FF" "$prefix-retained-seam" 48
}

function Click-Physical([IntPtr]$child, [int]$x, [int]$y) {
    $lparam = [IntPtr]([WeaverDpiWin32]::MakeLParam($x, $y))
    [WeaverDpiWin32]::SendMessage($child, [uint32]$WmLeftButtonDown, [UIntPtr]([uint32]1), $lparam) | Out-Null
    [WeaverDpiWin32]::SendMessage($child, [uint32]$WmLeftButtonUp, [UIntPtr]([uint32]0), $lparam) | Out-Null
    [WeaverDpiWin32]::DwmFlush() | Out-Null
    Start-Sleep -Milliseconds 250
}

function Verify-InputPixels($bitmap, $row, [string]$prefix) {
    Assert-Color $bitmap ($row.Width - 1) $row.X100 "#FFFFFF" "$prefix-right-click" 48
    Assert-Color $bitmap $row.X100 ($row.Height - 1) "#00FF66" "$prefix-bottom-click" 48
}

$gpuRun = $null
$softwareRun = $null
$currentRun = $null
try {
    $gpuRun = Start-Run "gpu" $false $true
    $initialProcess = Get-Process -Id $gpuRun.Pid
    $gpuStartHandles = $initialProcess.HandleCount
    foreach ($row in $matrix) {
        Set-DiagnosticDpi $gpuRun $row
        $geometry = Get-ClientGeometry $gpuRun.Hwnd
        Add-Check "gpu-$($row.Percent)-extent" ($geometry.Width -eq $row.Width -and $geometry.Height -eq $row.Height) "actual=$($geometry.Width)x$($geometry.Height) expected=$($row.Width)x$($row.Height)"
        Add-Check "gpu-$($row.Percent)-identity" ((Get-Process -Id $gpuRun.Pid).Id -eq $gpuRun.Pid -and [WeaverDpiWin32]::FindWindowForPid([uint32]$gpuRun.Pid) -eq $gpuRun.Hwnd) "pid=$($gpuRun.Pid) hwnd=0x$('{0:x}' -f $gpuRun.Hwnd.ToInt64())"
        $path = Join-Path $OutputDirectory "gpu-$($row.Percent).png"
        $bitmap = Capture-Client $gpuRun.Hwnd $path
        try { Verify-BasePixels $bitmap $row "gpu-$($row.Percent)" } finally { $bitmap.Dispose() }
        $results.gpu += [pscustomobject]@{ percent=$row.Percent; dpi=$row.Dpi; width=$geometry.Width; height=$geometry.Height; pid=$gpuRun.Pid; hwnd=('0x{0:x}' -f $gpuRun.Hwnd.ToInt64()); screenshot=$path }
    }

    $child = [WeaverDpiWin32]::FindGpuChild($gpuRun.Hwnd)
    Add-Check "gpu-child-window" ($child -ne [IntPtr]::Zero) "child=0x$('{0:x}' -f $child.ToInt64())"
    foreach ($row in $matrix) {
        Set-DiagnosticDpi $gpuRun $row
        $childNow = [WeaverDpiWin32]::FindGpuChild($gpuRun.Hwnd)
        Add-Check "gpu-$($row.Percent)-child-stable" ($childNow -eq $child) "child=0x$('{0:x}' -f $childNow.ToInt64())"
        Click-Physical $childNow ($row.Width - 2) $row.X100
        Click-Physical $childNow $row.X100 ($row.Height - 2)
        $path = Join-Path $OutputDirectory "gpu-$($row.Percent)-input.png"
        $bitmap = Capture-Client $gpuRun.Hwnd $path
        try { Verify-InputPixels $bitmap $row "gpu-$($row.Percent)" } finally { $bitmap.Dispose() }
    }
    Set-DiagnosticDpi $gpuRun $matrix[0]
    Start-Sleep -Seconds 2
    $gpuEndHandles = (Get-Process -Id $gpuRun.Pid).HandleCount
    Add-Check "gpu-handle-stability" ([Math]::Abs($gpuEndHandles - $gpuStartHandles) -le 8) "start=$gpuStartHandles end=$gpuEndHandles"
    $dpiLog = Join-Path $OutputDirectory "gpu-dpi-events.txt"
    $beforeIdle = (Get-Item $dpiLog).Length
    Start-Sleep -Seconds 2
    $afterIdle = (Get-Item $dpiLog).Length
    Add-Check "gpu-no-continuous-geometry-churn" ($beforeIdle -eq $afterIdle) "bytesBefore=$beforeIdle bytesAfter=$afterIdle"
    Stop-Run $gpuRun; $gpuRun = $null

    $softwareRun = Start-Run "software" $true $true
    foreach ($row in $matrix) {
        Set-DiagnosticDpi $softwareRun $row
        $geometry = Get-ClientGeometry $softwareRun.Hwnd
        $path = Join-Path $OutputDirectory "software-$($row.Percent).png"
        $bitmap = Capture-Client $softwareRun.Hwnd $path
        try { Verify-BasePixels $bitmap $row "software-$($row.Percent)" } finally { $bitmap.Dispose() }
        $results.software += [pscustomobject]@{ percent=$row.Percent; dpi=$row.Dpi; width=$geometry.Width; height=$geometry.Height; pid=$softwareRun.Pid; hwnd=('0x{0:x}' -f $softwareRun.Hwnd.ToInt64()); screenshot=$path }
    }
    $softwareChild = [WeaverDpiWin32]::FindGpuChild($softwareRun.Hwnd)
    Click-Physical $softwareChild ($matrix[4].Width - 2) $matrix[4].X100
    Click-Physical $softwareChild $matrix[4].X100 ($matrix[4].Height - 2)
    $softwareInput = Capture-Client $softwareRun.Hwnd (Join-Path $OutputDirectory "software-200-input.png")
    try { Verify-InputPixels $softwareInput $matrix[4] "software-200" } finally { $softwareInput.Dispose() }
    Stop-Run $softwareRun; $softwareRun = $null

    $currentRun = Start-Run "current-monitor" $false $false
    [WeaverDpiWin32]::DwmFlush() | Out-Null
    Start-Sleep -Milliseconds 500
    $currentGeometry = Get-ClientGeometry $currentRun.Hwnd
    $currentDpi = [WeaverDpiWin32]::GetDpiForWindow($currentRun.Hwnd)
    $currentPath = Join-Path $OutputDirectory "current-monitor-gpu.png"
    $currentBitmap = Capture-Client $currentRun.Hwnd $currentPath
    try {
        Assert-Color $currentBitmap 5 5 "#FF0055" "current-monitor-top-left"
        Assert-Occupied $currentBitmap ($currentGeometry.Width - 5) 5 "current-monitor-top-right"
        Assert-Occupied $currentBitmap 5 ($currentGeometry.Height - 5) "current-monitor-bottom-left"
        Assert-Occupied $currentBitmap ($currentGeometry.Width - 5) ($currentGeometry.Height - 5) "current-monitor-bottom-right"
    } finally { $currentBitmap.Dispose() }
    $results.currentMonitor = [pscustomobject]@{ dpi=$currentDpi; width=$currentGeometry.Width; height=$currentGeometry.Height; pid=$currentRun.Pid; hwnd=('0x{0:x}' -f $currentRun.Hwnd.ToInt64()); screenshot=$currentPath }
    Stop-Run $currentRun; $currentRun = $null
} finally {
    if ($gpuRun) { Stop-Run $gpuRun }
    if ($softwareRun) { Stop-Run $softwareRun }
    if ($currentRun) { Stop-Run $currentRun }
    Remove-Item Env:WEAVER_DPI_DIAGNOSTIC -ErrorAction SilentlyContinue
    Remove-Item Env:WEAVER_DPI_TEST_DPI -ErrorAction SilentlyContinue
    Remove-Item Env:WEAVER_FORCE_SOFTWARE -ErrorAction SilentlyContinue
    $results.finishedUtc = [DateTime]::UtcNow.ToString("o")
    $resultsPath = Join-Path $OutputDirectory "results.json"
    [IO.File]::WriteAllText($resultsPath, ($results | ConvertTo-Json -Depth 8))
}

Write-Host "DPI verification passed. Results: $(Join-Path $OutputDirectory 'results.json')"
