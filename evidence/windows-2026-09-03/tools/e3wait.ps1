param([int]$MaxSec=420)
$S = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$S\omenlib.ps1"
Get-Process | ? { $_.Name -match 'Omen' } | % { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Stop-Service HPOmenCap -Force -ErrorAction SilentlyContinue
"HPOmenCap=" + (Get-Service HPOmenCap).Status + "  omen procs=" + ((Get-Process | ? { $_.Name -match 'Omen' }).Count)
$t0=Get-Date
while(((Get-Date)-$t0).TotalSeconds -lt $MaxSec){ $v=EcRead 0x29; "{0,4}s  EC[0x29]=0x{1:X2}" -f [int]((Get-Date)-$t0).TotalSeconds,$v; if((($v -shr 7) -band 1) -eq 0){ "OCCN cleared"; break }; Start-Sleep 20 }
$msr.Close(); $ec.Close()
