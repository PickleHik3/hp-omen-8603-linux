$ErrorActionPreference='Continue'
$obj   = Get-WmiObject -Namespace 'root\wmi' -Class hpqBIntM
$inCls = Get-WmiObject -Namespace 'root\wmi' -List -Class hpqBDataIn

function Probe([int]$cmd,[int]$type,[int]$insize,[string]$label,[string]$m='hpqBIOSInt128'){
  $line = $label.PadRight(34) + ' cmd=0x' + $cmd.ToString('X5') + ' t=0x' + $type.ToString('X2')
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
      $k = [Math]::Min(31,$d.Count-1)
      $hex = (($d[0..$k]) | ForEach-Object { $_.ToString('X2') }) -join ' '
    }
    $line + ' rc=0x' + ([int]$rc).ToString('X2') + ' data=' + $hex
  } catch {
    $line + ' ERR ' + ($_.Exception.Message -replace "`r?`n",' ')
  }
}

'=== safe GET probes: OMEN gaming-mode command (HPWMI_GM = 0x20008) ==='
Probe 0x20008 0x11 4   'FAN_SPEED_GET (0x11)'
Probe 0x20008 0x28 128 'GET_SYSTEM_DESIGN_DATA (0x28)'
Probe 0x20008 0x26 4   'FAN_SPEED_MAX_GET (0x26) recheck'
''
'=== does buffer size change the 0x4c verdict? ==='
Probe 0x01 0x4C 0 'std thermal profile GET size=0'
Probe 0x01 0x4C 4 'std thermal profile GET size=4'
