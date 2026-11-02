$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'board_updates/camera_infer.py'
if (-not (Test-Path -LiteralPath $source)) { $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'board_updates/camera_infer.py' }
if (-not (Test-Path -LiteralPath $source)) { throw 'Missing board_updates/camera_infer.py' }
$oldHash = 'a9ffa8081e85a066bb2bf9ec98b0f630f5795c631abc15873c07a23729c239c4'
$newHash = (Get-FileHash -Algorithm SHA256 $source).Hash.ToLowerInvariant()
$encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
$runId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$remoteB64 = "/tmp/camera_infer_livecoords_$runId.b64"
$remoteNew = "/opt/tinyyolo/camera_infer.py.new_$runId"
$backup = "/opt/tinyyolo/camera_infer.py.pre_livecoords_$runId.bak"

$serial = [IO.Ports.SerialPort]::new('COM5', 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
$serial.ReadTimeout = 100
$serial.WriteTimeout = 5000
$serial.DtrEnable = $false
$serial.RtsEnable = $false

function Read-Prompt([int]$TimeoutSeconds = 8) {
    $response = ''
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $quiet = [DateTime]::UtcNow
    while ([DateTime]::UtcNow -lt $deadline) {
        $chunk = $serial.ReadExisting()
        if ($chunk) { $response += $chunk; $quiet = [DateTime]::UtcNow }
        if ($response -match '(?m)root@localhost:[^\r\n]*#\s*$' -and
            ([DateTime]::UtcNow - $quiet).TotalMilliseconds -gt 80) { return $response }
        Start-Sleep -Milliseconds 15
    }
    throw 'Serial response timed out'
}

function Send-Cmd([string]$Command) {
    $serial.Write($Command + "`r")
    return Read-Prompt
}

try {
    $serial.Open()
    Start-Sleep -Milliseconds 150
    $serial.Write("`r")
    $null = Read-Prompt 3

    $precheck = Send-Cmd('echo PRECHECK_BEGIN; sha256sum /opt/tinyyolo/camera_infer.py; ps w | grep -F /opt/tinyyolo/camera_infer.py | grep -v grep || true; python3 -c ''import json; print("PAN_TILT_ENABLED=", json.load(open("/opt/tinyyolo/pan_tilt.json"))["enabled"])''; echo PRECHECK_END')
    if ($precheck -notmatch $oldHash -or
        $precheck -notmatch 'PAN_TILT_ENABLED=\s+False' -or
        $precheck -match 'python3 /opt/tinyyolo/camera_infer.py ') {
        throw "Board precheck mismatch; no upload. $precheck"
    }

    $null = Send-Cmd(": > $remoteB64")
    for ($offset = 0; $offset -lt $encoded.Length; $offset += 500) {
        $count = [Math]::Min(500, $encoded.Length - $offset)
        $chunk = $encoded.Substring($offset, $count)
        $null = Send-Cmd("printf '%s' '$chunk' >> $remoteB64")
    }

    $staged = Send-Cmd("base64 -d $remoteB64 > $remoteNew && chmod 755 $remoteNew && sha256sum $remoteNew && python3 $remoteNew --selftest")
    if ($staged -notmatch $newHash -or $staged -notmatch 'target_center=1') {
        throw "Staged board selftest failed; original retained. $staged"
    }

    $installCommand = @'
current=$(sha256sum /opt/tinyyolo/camera_infer.py | cut -d' ' -f1); staged=$(sha256sum '__REMOTE_NEW__' | cut -d' ' -f1); enabled=$(python3 -c "import json; print(str(json.load(open('/opt/tinyyolo/pan_tilt.json'))['enabled']).lower())"); if [ "$current" = '__OLD_HASH__' ] && [ "$staged" = '__NEW_HASH__' ] && [ "$enabled" = false ] && ! ps w | grep -F '/opt/tinyyolo/camera_infer.py ' | grep -v grep >/dev/null; then cp -p /opt/tinyyolo/camera_infer.py '__BACKUP__' && mv '__REMOTE_NEW__' /opt/tinyyolo/camera_infer.py && echo DEPLOY_OK; else echo DEPLOY_ABORT current=$current staged=$staged enabled=$enabled; fi
'@
    $installCommand = $installCommand.Trim().Replace('__REMOTE_NEW__', $remoteNew).Replace('__OLD_HASH__', $oldHash).Replace('__NEW_HASH__', $newHash).Replace('__BACKUP__', $backup)
    $installed = Send-Cmd($installCommand)
    if ($installed -notmatch 'DEPLOY_OK') { throw "Board installation guard rejected replacement. $installed" }

    $verified = Send-Cmd('sha256sum /opt/tinyyolo/camera_infer.py; python3 /opt/tinyyolo/camera_infer.py --selftest; python3 -c ''import json; print("PAN_TILT_ENABLED=", json.load(open("/opt/tinyyolo/pan_tilt.json"))["enabled"])''')
    if ($verified -notmatch $newHash -or $verified -notmatch 'target_center=1' -or
        $verified -notmatch 'PAN_TILT_ENABLED=\s+False') {
        throw "Post-install verification failed. Backup: $backup. $verified"
    }
    $null = Send-Cmd("rm -f $remoteB64")
    "BACKUP=$backup"
    "SOURCE_SHA256=$newHash"
    $precheck
    $staged
    $installed
    $verified
}
finally {
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
}
