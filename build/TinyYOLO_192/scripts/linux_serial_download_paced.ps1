param(
    [Parameter(Mandatory=$true)][ValidatePattern('^/[A-Za-z0-9_./-]+$')][string]$RemoteFile,
    [Parameter(Mandatory=$true)][string]$LocalFile,
    [Parameter(Mandatory=$true)][string]$Log,
    [string]$Port='COM5',
    [int]$Baud=921600
)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $LocalFile){throw 'Download destination exists'}
$sender=@'
import base64,hashlib,os,select,termios,tty
path='__PATH__'
saved=termios.tcgetattr(0)
def response():
    line=b''
    while not line.endswith(b'\n'):
        if not select.select([0],[],[],20)[0]:raise RuntimeError('ACK timeout')
        line+=os.read(0,1)
    return line.strip()
try:
    tty.setraw(0)
    digest=hashlib.sha256()
    index=0
    with open(path,'rb') as stream:
        os.write(1,b'\nTY_PACED_READY\n')
        if response()!=b'GO':raise RuntimeError('Missing start ACK')
        while True:
            block=stream.read(1536)
            if not block:break
            packet=('TY_PACED_BLOCK:%d:%s:'%(index,hashlib.sha256(block).hexdigest())).encode()+base64.b64encode(block)+b'\n'
            for attempt in range(4):
                os.write(1,packet)
                if response()==('ACK:%d'%index).encode():break
            else:raise RuntimeError('Repeated chunk rejection')
            digest.update(block)
            index+=1
    os.write(1,('TY_PACED_DONE:%d:%s\n'%(index,digest.hexdigest())).encode())
finally:
    termios.tcsetattr(0,termios.TCSANOW,saved)
'@
$sender=$sender.Replace('__PATH__',$RemoteFile)
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sender))
$line='python3 -c '+"'import base64;exec(base64.b64decode("+'"'+$encoded+'"'+"))'"
$serial=New-Object System.IO.Ports.SerialPort $Port,$Baud,([System.IO.Ports.Parity]::None),8,([System.IO.Ports.StopBits]::One)
$serial.Handshake=[System.IO.Ports.Handshake]::None
$serial.DtrEnable=$false; $serial.RtsEnable=$false
$serial.ReadBufferSize=1048576; $serial.ReadTimeout=30000; $serial.WriteTimeout=5000
$serial.NewLine="`n"
$stream=New-Object IO.MemoryStream
$algorithm=[Security.Cryptography.SHA256]::Create()
$messages=New-Object 'System.Collections.Generic.List[string]'
try {
    $serial.Open();$serial.Write($line+"`r")
    do {$ready=$serial.ReadLine().TrimEnd("`r")} while($ready -ne 'TY_PACED_READY')
    $serial.Write("GO`n")
    $expected=0; $lastProgress=0
    while($true){
        $packet=$serial.ReadLine().TrimEnd("`r")
        if($packet -match '^TY_PACED_DONE:(\d+):([a-f0-9]{64})$'){
            if([int]$Matches[1] -ne $expected){throw 'Chunk count mismatch'}
            $declared=$Matches[2];break
        }
        if($packet -notmatch '^TY_PACED_BLOCK:(\d+):([a-f0-9]{64}):([A-Za-z0-9+/=]+)$'){
            $messages.Add("REJECT_PACKET expected=$expected")
            $serial.Write("RETRY:$expected`n");continue
        }
        $index=[int]$Matches[1];$digest=$Matches[2];$payload=$Matches[3]
        try{$block=[Convert]::FromBase64String($payload)}catch{$serial.Write("RETRY:$expected`n");continue}
        $actual=([BitConverter]::ToString($algorithm.ComputeHash($block))).Replace('-','').ToLowerInvariant()
        if($index -ne $expected -or $actual -ne $digest){
            $messages.Add("REJECT_HASH index=$index expected=$expected")
            $serial.Write("RETRY:$expected`n");continue
        }
        $stream.Write($block,0,$block.Length);$expected++
        $serial.Write("ACK:$index`n")
        if($stream.Length-$lastProgress -ge 1048576){
            Write-Output "DOWNLOAD_PROGRESS bytes=$($stream.Length)"
            $lastProgress=$stream.Length
        }
    }
    $bytes=$stream.ToArray()
    $actual=([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    if($actual -ne $declared){throw 'Complete download SHA mismatch'}
    [IO.File]::WriteAllBytes($LocalFile,$bytes)
    $messages.Add("DOWNLOAD_PASS bytes=$($bytes.Length) sha256=$actual chunks=$expected")
    Write-Output $messages[$messages.Count-1]
} finally {
    [IO.File]::WriteAllLines($Log,$messages,(New-Object Text.UTF8Encoding $false))
    if($serial.IsOpen){$serial.Close()};$serial.Dispose();$algorithm.Dispose();$stream.Dispose()
}
