# boot-test.ps1 — run in an ADMIN *Windows PowerShell 5.1* window within ~1 minute of logging in
# after a fresh reboot. Answers the one open question:
#   "Does a WMI keepalive (0x10 every 60 s + 0x23 every 30 s) sent from boot, with OMEN Gaming Hub
#    kept dead, PREVENT the EC's 45 W latch from engaging?"
# Phase 1 (0-8 min): OMEN killed continuously, keepalives running, then 200 s all-core load -> want ~77 W.
# Phase 2: keepalives stopped, 7 min idle, 200 s load -> expect 45 W clamp (confirms the latch timing).
# Requires LibreHardwareMonitor 0.9.6 (PawnIO) installed via winget, and omenlib.ps1/loadtest.ps1/spin.ps1 beside this file.
param([int]$PreMinutes=8,[int]$IdleMinutes=7)
$S = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$S\omenlib.ps1"
$log = "$S\boot-test-$(Get-Date -f yyyyMMdd-HHmm).log"
function Say($m){ $l="{0} {1}" -f (Get-Date -f HH:mm:ss),$m; $l | Tee-Object -FilePath $log -Append }
function KillOmen(){ Get-Process | ? { $_.Name -match 'Omen' } | % { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }; Stop-Service HPOmenCap -Force -ErrorAction SilentlyContinue }
Say "uptime: $((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime)"
KillOmen; Say ("start: " + (EcShow29) + " | " + (ShowPL))
Say ("mode set: " + (SetMode 1))
$t0=Get-Date; $lastHb=$t0.AddSeconds(-30); $lastOccn=$t0.AddSeconds(-60)
while(((Get-Date)-$t0).TotalMinutes -lt $PreMinutes){
  KillOmen
  if(((Get-Date)-$lastOccn).TotalSeconds -ge 60){ Say ("  " + (SetOccn)); $lastOccn=Get-Date }
  if(((Get-Date)-$lastHb).TotalSeconds -ge 30){ Say ("  " + (Heartbeat) + "  " + (EcShow29)); $lastHb=Get-Date }
  Start-Sleep 5
}
$msr.Close(); $ec.Close()
Say "=== Phase 1 load (keepalives continue inside loadtest) ==="
& "$S\loadtest.ps1" -Label boot_p1 -Seconds 200 -Interval 5 -OccnEvery 60 -HbEvery 30 | Tee-Object -FilePath $log -Append | Select-String '^#|^ *[0-9]+ ' | Out-Null
Say "=== Phase 2: keepalives stopped, idle $IdleMinutes min ==="
. "$S\omenlib.ps1"
$t1=Get-Date; while(((Get-Date)-$t1).TotalMinutes -lt $IdleMinutes){ KillOmen; Say ("  " + (EcShow29)); Start-Sleep 30 }
$msr.Close(); $ec.Close()
& "$S\loadtest.ps1" -Label boot_p2 -Seconds 200 -Interval 5 | Tee-Object -FilePath $log -Append | Out-Null
Say "=== done. Compare the '# AVG' lines of boot_p1 (keepalive) and boot_p2 (no keepalive) in $log ==="
Say "Restart OMEN: Start-Service HPOmenCap; explorer.exe shell:AppsFolder\AD2F1837.OMENCommandCenter_v10z8vjag6ke6!AD2F1837.OMENCommandCenter"
