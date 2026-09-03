param([string]$Label='run',[int]$Seconds=120,[int]$Interval=2,[int]$Threads=12,[switch]$NoLoad,[int]$OccnEvery=0,[int]$EcOccnEvery=0,[switch]$SetPerfFirst,[int]$HbEvery=0,[int]$ModeEvery=0)
$S = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$S\omenlib.ps1"
# EC write (cmd 0x81): used only when -EcOccnEvery given, to set bit7 of EC[0x29] directly
function EcWrite([byte]$a,[byte]$v){ while((($global:ec.ReadPort(0x66)) -band 1) -ne 0){ [void]$global:ec.ReadPort(0x62) }
  if(-not (EcWaitIbf)){ return $false }; $global:ec.WritePort(0x66,0x81); if(-not (EcWaitIbf)){ return $false }; $global:ec.WritePort(0x62,$a); if(-not (EcWaitIbf)){ return $false }; $global:ec.WritePort(0x62,$v); EcWaitIbf | Out-Null; $true }
$u=RdMsr 0x606; $pu=1.0/[math]::Pow(2,$u -band 0xF); $eu=1.0/[math]::Pow(2,($u -shr 8) -band 0x1F)
$tj=((RdMsr 0x1A2) -shr 16) -band 0xFF
$names=@{0='PROCHOT';1='THERM';4='RSR';5='RATL';6='VRTHERM';7='VRTDC';8='OTHER';10='PL1';11='PL2';12='MAXTURBO';13='TURBOATT'}
$ec0 = EcDump; [IO.File]::WriteAllBytes("$S\ec_${Label}_idle.bin",$ec0)
"# label=$Label threads=$Threads secs=$Seconds  EC[0x29]=0x{0:X2} idle  (OCCM={1} MAXF={2} OCCN={3})" -f $ec0[0x29],($ec0[0x29] -band 3),(($ec0[0x29] -shr 6) -band 1),(($ec0[0x29] -shr 7) -band 1)
if($OccnEvery -gt 0){ "# WMI 0x10 (OCCN refresh) every $OccnEvery s: " + (SetOccn) }
if($EcOccnEvery -gt 0){ $cur=EcRead 0x29; $ok=EcWrite 0x29 ([byte]($cur -bor 0x80)); "# direct EC write EC[0x29] |= 0x80 every $EcOccnEvery s: write ok=$ok -> " + (EcShow29) }
if($SetPerfFirst){ "# fresh WMI 0x1A performance set: " + (SetMode 1) }
$lastRefresh=[DateTime]::UtcNow; $lastHb=$lastRefresh; $lastMode=$lastRefresh
if(-not $NoLoad){ $load = Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$S\spin.ps1`" -Threads $Threads -Seconds $($Seconds+3)" -PassThru -WindowStyle Hidden }
$tStart=[DateTime]::UtcNow; $t0=$tStart; $e0=(RdMsr 0x611) -band 0xFFFFFFFF; $prev=$ec0; $rows=@()
"t(s)   W      MHz   T(C)  PL1/PL2  0x64F       EC29 EC-changes"
$tEnd=$tStart.AddSeconds($Seconds)
while([DateTime]::UtcNow -lt $tEnd){
  Start-Sleep -Seconds $Interval
  $every=[math]::Max($OccnEvery,$EcOccnEvery)
  if($every -gt 0 -and ([DateTime]::UtcNow-$lastRefresh).TotalSeconds -ge $every){
    if($OccnEvery -gt 0){ "   -> " + (SetOccn) }
    if($EcOccnEvery -gt 0){ $cur=EcRead 0x29; $ok=EcWrite 0x29 ([byte]($cur -bor 0x80)); "   -> EC[0x29] |= 0x80 ok=$ok now " + (EcShow29) }
    $lastRefresh=[DateTime]::UtcNow }
  if($HbEvery -gt 0 -and ([DateTime]::UtcNow-$lastHb).TotalSeconds -ge $HbEvery){ "   -> " + (Heartbeat); $lastHb=[DateTime]::UtcNow }
  if($ModeEvery -gt 0 -and ([DateTime]::UtcNow-$lastMode).TotalSeconds -ge $ModeEvery){ "   -> " + (SetMode 1); $lastMode=[DateTime]::UtcNow }
  $t1=[DateTime]::UtcNow; $e1=(RdMsr 0x611) -band 0xFFFFFFFF
  $de=[double]$e1-[double]$e0; if($de -lt 0){$de+=4294967296}; $w=$de*$eu/(($t1-$t0).TotalSeconds); $t0=$t1; $e0=$e1
  $mhz=(((RdMsr 0x198) -shr 8) -band 0xFF)*100
  $temp=$tj-(((RdMsr 0x1B1) -shr 16) -band 0x7F)
  $l=RdMsr 0x610; $pl1=($l -band 0x7FFF)*$pu; $pl2=(($l -shr 32) -band 0x7FFF)*$pu
  $r=RdMsr 0x64F; $st=@(("0x{0:X8}" -f ($r -band 0xFFFFFFFF))); foreach($b in $names.Keys){ if(($r -shr $b) -band 1){$st+=$names[$b]} }
  $ecd=EcDump; $ch=@(); for($a=0;$a -lt 256;$a++){ if($ecd[$a] -ne $prev[$a]){ $ch+=("{0:X2}:{1:X2}>{2:X2}" -f $a,$prev[$a],$ecd[$a]) } }; $prev=$ecd
  $ts=[int]($t1-$tStart).TotalSeconds
  $rows+=[pscustomobject]@{t=$ts;w=$w}
  "{0,4}  {1,6:N1}  {2,5}  {3,4}  {4,3}/{5,-3}  {6,-11} {7:X2}   {8}" -f $ts,$w,$mhz,$temp,$pl1,$pl2,($st -join ','),$ecd[0x29],($ch -join ' ')
}
[IO.File]::WriteAllBytes("$S\ec_${Label}_load.bin",$prev)
$late=$rows | ? { $_.t -ge 60 }; $mid=$rows | ? { $_.t -ge 30 -and $_.t -lt 60 }; $last=$rows | ? { $_.t -ge ($Seconds-40) }
"# AVG watts 30-60s: {0:N1}   60s-end: {1:N1}   last40s: {2:N1}" -f ($mid.w | Measure -Average).Average,($late.w | Measure -Average).Average,($last.w | Measure -Average).Average
if($load){ Wait-Process -Id $load.Id -ErrorAction SilentlyContinue }
$msr.Close(); $ec.Close()
