# dot-source: . .\omenlib.ps1   (Windows PowerShell 5.1)
$lib = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_Microsoft.Winget.Source_8wekyb3d8bbwe\LibreHardwareMonitorLib.dll"
$asm = [System.Reflection.Assembly]::LoadFrom($lib)
$global:msr = [Activator]::CreateInstance($asm.GetType('LibreHardwareMonitor.PawnIo.IntelMsr'),$true)
$global:ec  = [Activator]::CreateInstance($asm.GetType('LibreHardwareMonitor.PawnIo.LpcAcpiEc'),$true)
function RdMsr([uint32]$i){ $v=[uint64]0; if($global:msr.ReadMsr($i,[ref]$v)){$v}else{[uint64]0} }
function EcWaitIbf(){ for($k=0;$k -lt 20000;$k++){ if((($global:ec.ReadPort(0x66)) -band 2) -eq 0){ return $true } }; $false }
function EcWaitObf(){ for($k=0;$k -lt 20000;$k++){ if((($global:ec.ReadPort(0x66)) -band 1) -ne 0){ return $true } }; $false }
function EcXfer([byte]$a){ while((($global:ec.ReadPort(0x66)) -band 1) -ne 0){ [void]$global:ec.ReadPort(0x62) }
  if(-not (EcWaitIbf)){ return -1 }; $global:ec.WritePort(0x66,0x80); if(-not (EcWaitIbf)){ return -1 }; $global:ec.WritePort(0x62,$a); if(-not (EcWaitObf)){ return -1 }; return [int]$global:ec.ReadPort(0x62) }
function EcRead([byte]$a){ for($t=0;$t -lt 4;$t++){ $v1=EcXfer $a; $v2=EcXfer $a; if($v1 -ge 0 -and $v1 -eq $v2){ return [byte]$v1 } }; [byte]($v1 -band 0xFF) }
function EcDump(){ $b=New-Object byte[] 256; for($a=0;$a -lt 256;$a++){ $b[$a]=EcRead ([byte]$a) }; $b }
function EcShow29(){ $v=EcRead 0x29; "EC[0x29]=0x{0:X2}  OCCM={1} MAXF={2} OCCN={3}" -f $v,($v -band 3),(($v -shr 6) -band 1),(($v -shr 7) -band 1) }
function HexDump([byte[]]$b){ for($r=0;$r -lt 256;$r+=16){ ("{0:X2}: " -f $r) + (($b[$r..($r+15)] | % { $_.ToString('X2') }) -join ' ') } }
# HP OMEN BIOS WMI (hpqBIntM) command
$global:wobj = Get-WmiObject -Namespace 'root\wmi' -Class hpqBIntM
$global:winc = Get-WmiObject -Namespace 'root\wmi' -List -Class hpqBDataIn
function WmiCmd([uint32]$cmd,[uint32]$type,[byte[]]$data,[string]$m='hpqBIOSInt128'){
  $in=$global:winc.CreateInstance(); $in.Sign=[byte[]](0x53,0x45,0x43,0x55); $in.Command=$cmd; $in.CommandType=$type; $in.Size=[uint32]$data.Length; $in.hpqBData=$data
  $out=$global:wobj.$m($in); $rc=[int]$out.OutData.rwReturnCode; $d=$out.OutData.Data
  $hex=''; if($d -and $d.Count -gt 0){ $hex=(($d[0..([Math]::Min(7,$d.Count-1))]) | % { $_.ToString('X2') }) -join ' ' }
  "WMI cmd=0x{0:X5} type=0x{1:X2} in=[{2}] -> rc=0x{3:X2} out=[{4}]" -f $cmd,$type,(($data|%{$_.ToString('X2')}) -join ' '),$rc,$hex
}
function SetMode([byte]$mode){ WmiCmd 0x20008 0x1A ([byte[]](0xFF,$mode,0,0)) }   # 0=balanced 1=performance 2=cool
function SetOccn(){ WmiCmd 0x20008 0x10 ([byte[]](0,0,0,0)) }
function Heartbeat(){ WmiCmd 0x20008 0x23 ([byte[]](0,0,0,0)) }
function MaxFan([byte]$on){ WmiCmd 0x20008 0x27 ([byte[]]@($on)) }
function ShowPL(){ $u=RdMsr 0x606; $pu=1.0/[math]::Pow(2,$u -band 0xF); $l=RdMsr 0x610; "MSR 0x610 PL1={0} W en={1} clamp={2} | PL2={3} W  raw=0x{4:X16}" -f (($l -band 0x7FFF)*$pu),(($l -shr 15) -band 1),(($l -shr 16) -band 1),((($l -shr 32) -band 0x7FFF)*$pu),$l }
