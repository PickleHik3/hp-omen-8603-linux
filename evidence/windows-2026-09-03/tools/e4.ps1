# E4: does a DIRECT EC write of OCCM (EC[0x29] bits1:0) switch power, without WMI/SMI?
param([int]$Seconds=180,[int]$Interval=5,[int]$SwitchAt=70)
$S = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$S\omenlib.ps1"
function EcWrite([byte]$a,[byte]$v){ while((($global:ec.ReadPort(0x66)) -band 1) -ne 0){ [void]$global:ec.ReadPort(0x62) }
  if(-not (EcWaitIbf)){ return $false }; $global:ec.WritePort(0x66,0x81); if(-not (EcWaitIbf)){ return $false }; $global:ec.WritePort(0x62,$a); if(-not (EcWaitIbf)){ return $false }; $global:ec.WritePort(0x62,$v); EcWaitIbf | Out-Null; $true }
Get-Process | ? { $_.Name -match 'Omen' } | % { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }; Stop-Service HPOmenCap -Force -ErrorAction SilentlyContinue
"== E4: set BALANCED via WMI, load, then at t=$SwitchAt s write EC[0x29] := 0x81 directly (OCCM=1, OCCN=1) =="
SetMode 0; Start-Sleep 2; EcShow29
$u=RdMsr 0x606; $eu=1.0/[math]::Pow(2,($u -shr 8) -band 0x1F)
$load = Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$S\spin.ps1`" -Threads 12 -Seconds $($Seconds+3)" -PassThru -WindowStyle Hidden
$tStart=[DateTime]::UtcNow; $t0=$tStart; $e0=(RdMsr 0x611) -band 0xFFFFFFFF; $switched=$false
"t(s)   W      MHz  EC29"
while(([DateTime]::UtcNow-$tStart).TotalSeconds -lt $Seconds){
  Start-Sleep -Seconds $Interval
  $ts=[int]([DateTime]::UtcNow-$tStart).TotalSeconds
  if(-not $switched -and $ts -ge $SwitchAt){ $ok=EcWrite 0x29 0x81; $switched=$true; "   -> direct EC write 0x29:=0x81 ok=$ok ; " + (EcShow29) }
  if($switched -and ($ts % 60) -lt $Interval){ $cur=EcRead 0x29; [void](EcWrite 0x29 ([byte]($cur -bor 0x80))) }
  $t1=[DateTime]::UtcNow; $e1=(RdMsr 0x611) -band 0xFFFFFFFF; $de=[double]$e1-[double]$e0; if($de -lt 0){$de+=4294967296}; $w=$de*$eu/(($t1-$t0).TotalSeconds); $t0=$t1; $e0=$e1
  "{0,4}  {1,6:N1}  {2,5}  {3:X2}" -f $ts,$w,((((RdMsr 0x198) -shr 8) -band 0xFF)*100),(EcRead 0x29)
}
Wait-Process -Id $load.Id -ErrorAction SilentlyContinue
"== restore: performance via WMI =="; SetMode 1; Start-Sleep 1; EcShow29
$msr.Close(); $ec.Close()
