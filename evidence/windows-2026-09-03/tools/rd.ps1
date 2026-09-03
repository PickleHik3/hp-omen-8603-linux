param([switch]$NoEc)
$lib = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_Microsoft.Winget.Source_8wekyb3d8bbwe\LibreHardwareMonitorLib.dll"
$asm = [System.Reflection.Assembly]::LoadFrom($lib)
$BF = [Reflection.BindingFlags]'Static,Instance,Public,NonPublic'
function NewInst($tn){ $t=$asm.GetType($tn); "ctors($tn): " + (($t.GetConstructors($BF) | % { $_.ToString() }) -join ' | ') | Out-Host; [Activator]::CreateInstance($t,$true) }
$msr = NewInst 'LibreHardwareMonitor.PawnIo.IntelMsr'
function RdMsr([uint32]$i){ $v=[uint64]0; $ok=$msr.ReadMsr($i,[ref]$v); if($ok){$v}else{$null} }
$u606 = RdMsr 0x606; $pu = 1.0/[math]::Pow(2,($u606 -shr 0) -band 0xF); $tu = 1.0/[math]::Pow(2,($u606 -shr 16) -band 0xF)
"MSR 0x606 units: power=1/{0} W  time=1/{1} s" -f (1/$pu),(1/$tu)
foreach($m in 0x610,0x65C,0x614,0x64F,0x1FC,0x64C,0x648,0x649,0x64A,0x64B,0x1AD,0x1A0,0x1B1,0x19C){ $v=RdMsr $m; if($v -ne $null){ "MSR 0x{0:X3} = 0x{1:X16}" -f $m,$v } else { "MSR 0x{0:X3} = (read failed)" -f $m } }
function DecPL($v,$label){ $pl1=($v -band 0x7FFF)*$pu; $en1=($v -shr 15) -band 1; $cl1=($v -shr 16) -band 1; $ty=($v -shr 17) -band 0x1F; $tx=($v -shr 22) -band 3; $tw=[math]::Pow(2,$ty)*(1+$tx/4.0)*$tu
 $hi=$v -shr 32; $pl2=($hi -band 0x7FFF)*$pu; $en2=($hi -shr 15) -band 1; $cl2=($hi -shr 16) -band 1; $lock=($v -shr 63) -band 1
 "{0}: PL1={1} W en={2} clamp={3} tau={4:N1}s | PL2={5} W en={6} clamp={7} | lock={8}" -f $label,$pl1,$en1,$cl1,$tw,$pl2,$en2,$cl2,$lock }
DecPL (RdMsr 0x610) 'PKG_POWER_LIMIT 0x610'
DecPL (RdMsr 0x65C) 'PLATFORM_POWER_LIMIT 0x65C'
$i=RdMsr 0x614; "PKG_POWER_INFO 0x614: TDP={0} W min={1} W max={2} W maxwin={3}" -f (($i -band 0x7FFF)*$pu),((($i -shr 16) -band 0x7FFF)*$pu),((($i -shr 32) -band 0x7FFF)*$pu),(($i -shr 48) -band 0x7F)
$r=RdMsr 0x64F; $names=@{0='PROCHOT';1='Thermal';4='ResidencyState';5='RATL';6='VR_ThermAlert';7='VR_TDC';8='Other';10='PL1';11='PL2';12='MaxTurbo';13='TurboAtten'}
$st=@(); $lg=@(); foreach($b in $names.Keys){ if(($r -shr $b) -band 1){$st+=$names[$b]}; if(($r -shr ($b+16)) -band 1){$lg+=$names[$b]} }
"CORE_PERF_LIMIT_REASONS 0x64F: status=[{0}] log=[{1}]" -f ($st -join ','),($lg -join ',')
$c=RdMsr 0x64B; "CONFIG_TDP_CONTROL 0x64B: level={0} lock={1}" -f ($c -band 3),(($c -shr 31) -band 1)
$msr.Close()
if(-not $NoEc){
 "== EC dump via LPC ACPI EC (ports 0x62/0x66) =="
 $ecio = NewInst 'LibreHardwareMonitor.Hardware.Motherboard.Lpc.EC.WindowsEmbeddedControllerIO'
 $rb = $ecio.GetType().GetMethod('ReadByte',$BF)
 $bytes = New-Object byte[] 256
 for($a=0;$a -lt 256;$a++){ $bytes[$a] = $rb.Invoke($ecio,@([byte]$a)) }
 for($row=0;$row -lt 256;$row+=16){ ("{0:X2}: " -f $row) + (($bytes[$row..($row+15)] | % { $_.ToString('X2') }) -join ' ') }
 "EC[0x29]=0x{0:X2}  EC[0x95]=0x{1:X2}" -f $bytes[0x29],$bytes[0x95]
 $ecio.Dispose()
 if($env:ECOUT){ [IO.File]::WriteAllBytes($env:ECOUT,$bytes); "saved $env:ECOUT" }
}
