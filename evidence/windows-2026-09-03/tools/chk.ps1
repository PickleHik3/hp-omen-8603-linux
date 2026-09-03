$S = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$S\omenlib.ps1"
EcShow29; ShowPL
$msr.Close(); $ec.Close()
