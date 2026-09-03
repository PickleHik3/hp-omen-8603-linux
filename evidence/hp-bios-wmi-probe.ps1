$ErrorActionPreference='Continue'
$obj   = Get-WmiObject -Namespace 'root\wmi' -Class hpqBIntM
$inCls = Get-WmiObject -Namespace 'root\wmi' -List -Class hpqBDataIn
if(-not $obj){ 'ERROR: no hpqBIntM instance'; exit 1 }
if(-not $inCls){ 'ERROR: no hpqBDataIn class'; exit 1 }
'hpqBIntM instance: ' + $obj.InstanceName

function Probe([int]$cmd,[int]$type,[int]$insize,[string]$label,[string]$m='hpqBIOSInt128'){
  $line = $label.PadRight(30) + ' cmd=0x' + $cmd.ToString('X5') + ' t=0x' + $type.ToString('X2')
  try{
    $in = $inCls.CreateInstance()
    $in.Sign        = [byte[]](0x53,0x45,0x43,0x55)
    $in.Command     = [uint32]$cmd
    $in.CommandType = [uint32]$type
    $in.Size        = [uint32]$insize
    $in.hpqBData    = New-Object byte[] $insize
    $out = $obj.$m($in)
    $rc  = $out.OutData.rwReturnCode
    $d   = $out.OutData.Data
    $hex = '(empty)'
    if($d -and $d.Count -gt 0){
      $k = [Math]::Min(11,$d.Count-1)
      $hex = (($d[0..$k]) | ForEach-Object { $_.ToString('X2') }) -join ' '
    }
    $line + ' rc=0x' + ([int]$rc).ToString('X2') + ' data=' + $hex
  } catch {
    $line + ' ERR ' + ($_.Exception.Message -replace "`r?`n",' ')
  }
}

'=== probe set 2 ==='
Probe 0x01    0x0B 4  'feature query 0x0b'
Probe 0x01    0x0D 4  'feature2 query 0x0d'
Probe 0x01    0x04 4  'hardware query 0x04'
Probe 0x01    0x4C 1  'std thermal profile GET 0x4c'
Probe 0x20008 0x00 4  'OMEN thermal profile GET'
Probe 0x20008 0x26 4  'OMEN max-fan GET 0x26'
Probe 0x20008 0x2D 4  'OMEN fan level GET 0x2d'
Probe 0x20008 0x2E 4  'OMEN 0x2e'
