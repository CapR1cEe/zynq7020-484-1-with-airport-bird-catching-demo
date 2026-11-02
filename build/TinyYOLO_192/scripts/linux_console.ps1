param(
    [Parameter(Mandatory=$true)][string]$CommandFile,
    [Parameter(Mandatory=$true)][string]$Log,
    [string]$Port='COM5',
    [int]$Baud=115200,
    [ValidateRange(2,300)][int]$TimeoutSeconds=30
)
$ErrorActionPreference='Stop'
$scriptText=[IO.File]::ReadAllText($CommandFile).Replace("`r`n","`n").Replace("`r","`n")
$payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptText))
$token='TY_'+[Guid]::NewGuid().ToString('N')
$line=@'
printf '\n__TOKEN___BEGIN\n'; bash -c "$(printf '%s' '__PAYLOAD__' | base64 -d)"; ty_console_rc=$?; printf '\n__TOKEN___END:%s\n' "$ty_console_rc"
'@
$line=$line.Replace('__PAYLOAD__',$payload).Replace('__TOKEN__',$token)
$serial=New-Object System.IO.Ports.SerialPort $Port,$Baud,([System.IO.Ports.Parity]::None),8,([System.IO.Ports.StopBits]::One)
$serial.Handshake=[System.IO.Ports.Handshake]::None
$serial.ReadBufferSize=1048576
$serial.DtrEnable=$false; $serial.RtsEnable=$false
$serial.ReadTimeout=500; $serial.WriteTimeout=5000
$capture=''
try {
    $serial.Open()
    # Pace the interactive shell line: without flow control a busy ARM may
    # overrun UART receive while its line editor echoes a long base64 command.
    $transmit=$line+"`r"
    for($offset=0;$offset -lt $transmit.Length;$offset+=32) {
        $serial.Write($transmit.Substring($offset,[Math]::Min(32,$transmit.Length-$offset)))
        Start-Sleep -Milliseconds 10
    }
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $pattern='(?m)^'+[Regex]::Escape($token)+'_END:(\d+)\r?$'
    while($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Milliseconds 10
        $capture+=$serial.ReadExisting()
        $match=[Regex]::Match($capture,$pattern)
        if($match.Success){break}
    }
    [IO.File]::WriteAllText($Log,$capture,(New-Object Text.UTF8Encoding $false))
    Write-Output $capture
    if(!$match.Success){throw "Board command timed out; inspect $Log"}
    if($match.Groups[1].Value -ne '0'){throw "Board command failed; inspect $Log"}
} finally {
    [IO.File]::WriteAllText($Log,$capture,(New-Object Text.UTF8Encoding $false))
    if($serial.IsOpen){$serial.Close()}; $serial.Dispose()
}
