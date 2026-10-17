param([Parameter(Mandatory)][int]$ProcessId, [int]$Top = 30, [switch]$Runs)
# Private memory of one process, grouped by allocation: committed bytes
# (what private bytes counts) and resident bytes (what private working set
# counts), largest resident first. Read-only; opens the process for query.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Regions {
  [StructLayout(LayoutKind.Sequential)] public struct MBI {
    public IntPtr BaseAddress, AllocationBase; public uint AllocationProtect; public ushort PartitionId;
    public IntPtr RegionSize; public uint State, Protect, Type;
  }
  [StructLayout(LayoutKind.Sequential)] public struct WSX { public IntPtr Va; public IntPtr Attr; }
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern IntPtr VirtualQueryEx(IntPtr h, IntPtr addr, out MBI info, IntPtr len);
  [DllImport("psapi.dll")] static extern bool QueryWorkingSetEx(IntPtr h, [In, Out] WSX[] info, int size);
  public class Row { public long Base; public long Committed; public long Resident; public uint Type; public uint Protect; public List<long> Pages = new List<long>(); }
  public static List<Row> Read(int pid) {
    IntPtr h = OpenProcess(0x0400 | 0x0010, false, pid);
    if (h == IntPtr.Zero) throw new Exception("OpenProcess failed");
    var rows = new Dictionary<long, Row>();
    long addr = 0; MBI m;
    while (VirtualQueryEx(h, (IntPtr)addr, out m, (IntPtr)Marshal.SizeOf(typeof(MBI))) != IntPtr.Zero) {
      long size = (long)m.RegionSize;
      if (m.State == 0x1000 && (m.Type == 0x20000 || m.Type == 0x1000000)) {
        long key = (long)m.AllocationBase;
        Row r; if (!rows.TryGetValue(key, out r)) { r = new Row { Base = key, Type = m.Type, Protect = m.Protect }; rows[key] = r; }
        if (m.Type == 0x20000) r.Committed += size;
        int pages = (int)(size / 4096);
        var ws = new WSX[pages];
        for (int i = 0; i < pages; i++) ws[i].Va = (IntPtr)((long)m.BaseAddress + (long)i * 4096);
        if (QueryWorkingSetEx(h, ws, pages * Marshal.SizeOf(typeof(WSX)))) {
          foreach (var p in ws) {
            long a = (long)p.Attr;
            bool valid = (a & 1) != 0; bool shared = ((a >> 15) & 1) != 0;
            if (valid && !shared) { r.Resident += 4096; r.Pages.Add((long)p.Va - key); }
          }
        }
      }
      addr = (long)m.BaseAddress + size;
    }
    CloseHandle(h);
    return new List<Row>(rows.Values);
  }
}
'@
$rows = [Regions]::Read($ProcessId)
$private = $rows | Where-Object Type -eq 0x20000
$image = $rows | Where-Object Type -eq 0x1000000
'private allocations: {0} committed {1:N2} MiB, resident {2:N2} MiB; image private-resident {3:N2} MiB' -f `
  $private.Count, (($private | Measure-Object Committed -Sum).Sum / 1MB), (($private | Measure-Object Resident -Sum).Sum / 1MB), (($image | Measure-Object Resident -Sum).Sum / 1MB)
$private | Sort-Object Resident -Descending | Select-Object -First $Top |
  Select-Object @{n='base';e={'0x{0:x}' -f $_.Base}}, @{n='committed_kib';e={[math]::Round($_.Committed/1KB)}}, @{n='resident_kib';e={[math]::Round($_.Resident/1KB)}} |
  Format-Table -AutoSize | Out-String
'private allocations by committed size:'
$private | Sort-Object Committed -Descending | Select-Object -First 12 |
  Select-Object @{n='base';e={'0x{0:x}' -f $_.Base}}, @{n='committed_kib';e={[math]::Round($_.Committed/1KB)}}, @{n='resident_kib';e={[math]::Round($_.Resident/1KB)}} |
  Format-Table -AutoSize | Out-String
if ($Runs) {
  foreach ($r in ($private | Where-Object { $_.Resident -ge 256KB } | Sort-Object Resident -Descending)) {
    $spans = @(); $start = -1; $prev = -1
    foreach ($off in ($r.Pages | Sort-Object)) {
      if ($start -lt 0) { $start = $off } elseif ($off - $prev -gt 16KB) { $spans += ,@($start, $prev + 4KB); $start = $off }
      $prev = $off
    }
    if ($start -ge 0) { $spans += ,@($start, $prev + 4KB) }
    'resident runs in 0x{0:x} (offsets in KiB, gaps under 16 KiB merged): {1}' -f $r.Base, (($spans | ForEach-Object { '{0}-{1}' -f ($_[0]/1KB), ($_[1]/1KB) }) -join ', ')
  }
}
