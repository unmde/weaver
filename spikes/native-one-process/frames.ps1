param([string]$Exe = (Join-Path $PSScriptRoot '..\..\runtime\zig-out\bin\weaver-widget.exe'), [int]$MinKiB = 64, [int]$Top = 20)
# Functions with large stack frames in an x64 PE, largest first. A frame over
# one page is entered through `mov eax, size; call __chkstk; sub rsp, rax`,
# and __chkstk touches every page of it, so each such frame is resident stack
# whenever it is on the call chain. Names come from the PDB via dbghelp.
$Exe = (Resolve-Path $Exe).Path
$bytes = [IO.File]::ReadAllBytes($Exe)
$pe = [BitConverter]::ToInt32($bytes, 0x3c)
$sections = [BitConverter]::ToUInt16($bytes, $pe + 6)
$optional = [BitConverter]::ToUInt16($bytes, $pe + 20)
$imageBase = [BitConverter]::ToUInt64($bytes, $pe + 24 + 24)
$text = $null
for ($i = 0; $i -lt $sections; $i++) {
  $o = $pe + 24 + $optional + 40 * $i
  if ([Text.Encoding]::ASCII.GetString($bytes, $o, 5) -eq '.text') {
    $text = @{ va = [BitConverter]::ToUInt32($bytes, $o + 12); size = [BitConverter]::ToUInt32($bytes, $o + 16); raw = [BitConverter]::ToUInt32($bytes, $o + 20) }
  }
}
$code = [Text.Encoding]::GetEncoding(28591).GetString($bytes, $text.raw, $text.size)
$hits = foreach ($m in [regex]::Matches($code, "\xB8(.{4})\xE8.{4}\x48\x29\xC4", 'Singleline')) {
  $size = [BitConverter]::ToUInt32($bytes, $text.raw + $m.Index + 1)
  if ($size -ge $MinKiB * 1KB) { [pscustomobject]@{ address = $imageBase + $text.va + $m.Index; kib = [math]::Round($size / 1KB, 1) } }
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FrameSym {
  [DllImport("dbghelp.dll", CharSet=CharSet.Unicode)] public static extern bool SymInitializeW(IntPtr h, string path, bool invade);
  [DllImport("dbghelp.dll", CharSet=CharSet.Unicode)] public static extern ulong SymLoadModuleExW(IntPtr h, IntPtr file, string image, string module, ulong baseAddr, uint size, IntPtr data, uint flags);
  [DllImport("dbghelp.dll")] public static extern uint SymSetOptions(uint o);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SYMBOL_INFOW {
    public uint SizeOfStruct, TypeIndex; public ulong Reserved0, Reserved1; public uint Index, Size; public ulong ModBase; public uint Flags; public ulong Value, Address; public uint Register, Scope, Tag, NameLen, MaxNameLen;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=1024)] public string Name;
  }
  [DllImport("dbghelp.dll", CharSet=CharSet.Unicode)] public static extern bool SymFromAddrW(IntPtr h, ulong addr, out ulong disp, ref SYMBOL_INFOW info);
  public static string Name(IntPtr h, ulong a) {
    var s = new SYMBOL_INFOW(); s.SizeOfStruct = 88; s.MaxNameLen = 1024; ulong disp;
    return SymFromAddrW(h, a, out disp, ref s) ? s.Name : "?";
  }
}
'@
$h = [IntPtr]0x5eed
[FrameSym]::SymSetOptions(0x2 -bor 0x10) | Out-Null
[FrameSym]::SymInitializeW($h, (Split-Path $Exe), $false) | Out-Null
[FrameSym]::SymLoadModuleExW($h, [IntPtr]::Zero, $Exe, $null, $imageBase, 0, [IntPtr]::Zero, 0) | Out-Null
$hits | Sort-Object kib -Descending | Select-Object -First $Top |
  Select-Object kib, @{ n = 'function'; e = { [FrameSym]::Name($h, [uint64]$_.address) } } | Format-Table -AutoSize | Out-String
