param([int]$From=115200,[int]$To=921600,[string]$Port='COM5')
$ErrorActionPreference='Stop'
$serial=New-Object System.IO.Ports.SerialPort $Port,$From,([System.IO.Ports.Parity]::None),8,([System.IO.Ports.StopBits]::One)
$serial.DtrEnable=$false; $serial.RtsEnable=$false; $serial.WriteTimeout=3000
try {
    $serial.Open()
    $serial.Write("stty -F /dev/ttyPS0 $To`r")
    Start-Sleep -Milliseconds 500
    $serial.BaudRate=$To
    $serial.DiscardInBuffer()
    $marker='TY_SPEED_'+[Guid]::NewGuid().ToString('N')
    $serial.Write("printf '\n$marker\n'`r")
    $timer=[Diagnostics.Stopwatch]::StartNew(); $capture=''
    while($timer.Elapsed.TotalSeconds -lt 5) {
        Start-Sleep -Milliseconds 50
        $capture+=$serial.ReadExisting()
        if($capture -match ('(?m)^'+$marker+'\r?$')){Write-Output "SERIAL_SPEED_PASS baud=$To";return}
    }
    throw "Serial speed check failed at $To baud. Board may still be at the requested speed."
} finally {if($serial.IsOpen){$serial.Close()};$serial.Dispose()}
