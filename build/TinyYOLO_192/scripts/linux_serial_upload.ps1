param(
    [Parameter(Mandatory=$true)][string]$LocalFile,
    [Parameter(Mandatory=$true)][ValidatePattern('^/dev/shm/[A-Za-z0-9_.-]+$')][string]$RemoteFile,
    [Parameter(Mandatory=$true)][string]$Log,
    [string]$Port='COM5',
    [int]$Baud=115200
)
$ErrorActionPreference='Stop'
$bytes=[IO.File]::ReadAllBytes($LocalFile)
$hash=(Get-FileHash -LiteralPath $LocalFile -Algorithm SHA256).Hash.ToLower()
$receiver=@'
import os,select,termios,tty,hashlib
size=__SIZE__
path='__PATH__'
saved=termios.tcgetattr(0)
try:
    tty.setraw(0)
    with open(path,'xb') as stream:
        digest=hashlib.sha256()
        pos=0
        os.write(1,b'\nTY_UPLOAD_READY\n')
        while pos<size:
            want=min(4096,size-pos)
            data=b''
            while len(data)<want:
                if not select.select([0],[],[],20)[0]:
                    raise RuntimeError('serial upload timeout')
                block=os.read(0,want-len(data))
                if not block: raise RuntimeError('serial EOF')
                data+=block
            stream.write(data);digest.update(data);pos+=len(data)
            os.write(1,('TY_UPLOAD_ACK:%d\n'%pos).encode())
        stream.flush()
        os.write(1,('TY_UPLOAD_SHA256:%s\n'%digest.hexdigest()).encode())
finally:
    termios.tcsetattr(0,termios.TCSANOW,saved)
'@
$receiver=$receiver.Replace('__SIZE__',[string]$bytes.Length).Replace('__PATH__',$RemoteFile)
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($receiver))
$line='python3 -c '+"'import base64;exec(base64.b64decode("+'"'+$encoded+'"'+"))'"
$serial=New-Object System.IO.Ports.SerialPort $Port,$Baud,([System.IO.Ports.Parity]::None),8,([System.IO.Ports.StopBits]::One)
$serial.Handshake=[System.IO.Ports.Handshake]::None
$serial.DtrEnable=$false; $serial.RtsEnable=$false
$serial.ReadTimeout=500; $serial.WriteTimeout=10000
$transcript=''
function Wait-Marker([string]$Pattern) {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.Elapsed.TotalSeconds -lt 25) {
        $script:transcript+=$serial.ReadExisting()
        if($script:transcript -match $Pattern){return}
        Start-Sleep -Milliseconds 5
    }
    throw "Serial upload marker timeout: $Pattern"
}
try {
    $serial.Open();$serial.Write($line+"`r")
    Wait-Marker '(?m)^TY_UPLOAD_READY\r?$'
    $pos=0;$progress=0
    while($pos -lt $bytes.Length) {
        $count=[Math]::Min(4096,$bytes.Length-$pos)
        $serial.Write($bytes,$pos,$count);$pos+=$count
        Wait-Marker ('(?m)^TY_UPLOAD_ACK:'+$pos+'\r?$')
        if($pos-$progress -ge 262144 -or $pos -eq $bytes.Length) {
            Write-Output "UPLOAD_PROGRESS bytes=$pos total=$($bytes.Length)"
            $progress=$pos
        }
    }
    Wait-Marker ('(?m)^TY_UPLOAD_SHA256:'+$hash+'\r?$')
    Write-Output "UPLOAD_PASS sha256=$hash remote=$RemoteFile"
} finally {
    [IO.File]::WriteAllText($Log,$transcript,(New-Object Text.UTF8Encoding $false))
    if($serial.IsOpen){$serial.Close()};$serial.Dispose()
}
