# HpReadHWData.sys client (as OMEN uses it): IOCTL type 40001 / func 2306 / buffered; 8-byte index in, 8 bytes out.
# Plain index = RDMSR. Bit63-set indexes are commands: 0x8000_0200_0000_0000|PL1x8 sets PL1, 0x8000_0300..|PL2x8 sets PL2.
param([string[]]$Index=@('0x610'))
$cs = @'
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class HpDrv {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool DeviceIoControl(SafeFileHandle h, uint code, ref ulong inBuf, uint inSize, ref ulong outBuf, uint outSize, out uint ret, IntPtr ov);
  public static uint Code = (40001u << 16) | (2306u << 2);
  public static bool Call(ulong index, out ulong value, out int err){
    value = 0; err = 0;
    var h = CreateFile(new string((char)92,2) + (char)46 + (char)92 + "HPReadHWData", 0xC0000000, 0, IntPtr.Zero, 2, 0x80, IntPtr.Zero);
    if (h.IsInvalid) { err = Marshal.GetLastWin32Error(); return false; }
    uint ret; ulong outv = 0; bool ok = DeviceIoControl(h, Code, ref index, 8, ref outv, 8, out ret, IntPtr.Zero);
    if(!ok) err = Marshal.GetLastWin32Error(); value = outv; h.Close(); return ok;
  }
}
'@
Add-Type -TypeDefinition $cs
foreach($i in ($Index -split ",")){ $idx=[Convert]::ToUInt64(($i -replace '^0x',''),16); $v=[uint64]0; $e=0; $ok=[HpDrv]::Call($idx,[ref]$v,[ref]$e); "index=0x{0:X16} ok={1} err={2} value=0x{3:X16}" -f $idx,$ok,$e,$v }
