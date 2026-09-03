param([int]$WaitSec=240)
$S = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$S\omenlib.ps1"
"== E2: stop OMEN stack, watch EC[0x29] =="
Get-Process | ? { $_.Name -match '^Omen|HPOmen|OmenCap|OmenInstallMonitor|OmenCommandCenter' } | % { "killing $($_.Name) $($_.Id)"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Stop-Service HPOmenCap -Force -ErrorAction SilentlyContinue; "HPOmenCap: " + (Get-Service HPOmenCap).Status
Get-ScheduledTask | ? { $_.TaskName -match 'Omen' -and $_.State -eq 'Running' } | % { "stopping task $($_.TaskName)"; Stop-ScheduledTask -TaskName $_.TaskName -ErrorAction SilentlyContinue }
Start-Sleep 2
Get-Process | ? { $_.Name -match 'Omen' } | Select Name,Id | ft -auto | Out-String
ShowPL
$t0=Get-Date
while(((Get-Date)-$t0).TotalSeconds -lt $WaitSec){ "{0,4}s  {1}" -f [int]((Get-Date)-$t0).TotalSeconds,(EcShow29); Start-Sleep 20 }
$msr.Close(); $ec.Close()
