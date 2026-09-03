param([int]$Seconds=300,[switch]$TryTS)
$S = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$S\omenlib.ps1"
function KillOmen(){ Get-Process | ? { $_.Name -match 'Omen' } | % { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }; Stop-Service HPOmenCap -Force -ErrorAction SilentlyContinue }
KillOmen; "{0} OMEN killed. {1} | {2}" -f (Get-Date -f HH:mm:ss),(EcShow29),(ShowPL)
if($TryTS -and (Test-Path 'C:\ThrottleStop_9.7\ThrottleStop.exe')){
  $p = Start-Process 'C:\ThrottleStop_9.7\ThrottleStop.exe' -WorkingDirectory 'C:\ThrottleStop_9.7' -PassThru -WindowStyle Minimized
  Start-Sleep 10; "{0} after ThrottleStop start: {1}" -f (Get-Date -f HH:mm:ss),(ShowPL)
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Start-Sleep 2; "{0} ThrottleStop killed: {1}" -f (Get-Date -f HH:mm:ss),(ShowPL)
}
$t0=Get-Date; $lastHb=$t0.AddSeconds(-60); $lastOccn=$t0.AddSeconds(-60)
while(((Get-Date)-$t0).TotalSeconds -lt $Seconds){
  KillOmen
  if(((Get-Date)-$lastOccn).TotalSeconds -ge 60){ "{0}  {1}" -f (Get-Date -f HH:mm:ss),(SetOccn); $lastOccn=Get-Date }
  if(((Get-Date)-$lastHb).TotalSeconds -ge 30){ "{0}  {1} | {2}" -f (Get-Date -f HH:mm:ss),(Heartbeat),(EcShow29); $lastHb=Get-Date }
  Start-Sleep 5
}
$msr.Close(); $ec.Close()
