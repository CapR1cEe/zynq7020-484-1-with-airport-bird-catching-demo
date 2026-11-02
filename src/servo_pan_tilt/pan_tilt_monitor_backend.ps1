[CmdletBinding()]
param([string]$Port = 'COM5')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$serial = [IO.Ports.SerialPort]::new($Port, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
$serial.Handshake = 'None'
$serial.DtrEnable = $false
$serial.RtsEnable = $false
$serial.ReadTimeout = 100
$serial.WriteTimeout = 3000
$targetStatusPath = '/tmp/tinyyolo_monitor_target.json'
$detectorPidPath = '/tmp/tinyyolo_monitor_detector.pid'
$runId = [Guid]::NewGuid().ToString('N')
$detectorOutputPath = "/tmp/tinyyolo_monitor_$runId"
$detectorLogPath = "/tmp/tinyyolo_monitor_$runId.log"

$trackerCommand = @'
if test -e /dev/video0; then START=0; if ! grep -q -- --live-status /opt/tinyyolo/camera_infer.py; then TRACKER=unsupported; elif test -f '__PID__'; then oldpid=$(cat '__PID__'); if test -d "/proc/$oldpid" && tr '\000' ' ' < "/proc/$oldpid/cmdline" | grep -F -- '__STATUS__' >/dev/null; then TRACKER=running; else rm -f '__PID__'; START=1; fi; else START=1; fi; if test "$START" = 1; then if ps w | grep -F '/opt/tinyyolo/camera_infer.py' | grep -v grep >/dev/null; then TRACKER=busy; else rm -f '__STATUS__'; nohup python3 /opt/tinyyolo/camera_infer.py --track --frames 10000 --control-fps 15 --live-status '__STATUS__' --output '__OUTPUT__' > '__LOG__' 2>&1 </dev/null & echo $! > '__PID__'; TRACKER=starting; fi; fi; else if test -f '__PID__'; then oldpid=$(cat '__PID__'); if test -d "/proc/$oldpid" && tr '\000' ' ' < "/proc/$oldpid/cmdline" | grep -F -- '__STATUS__' >/dev/null; then kill -INT "$oldpid" 2>/dev/null || true; fi; rm -f '__PID__' '__STATUS__'; fi; TRACKER=no_camera; fi; echo TRACKER_STATE=$TRACKER
'@
$trackerCommand = $trackerCommand.Trim().Replace("`r", ' ').Replace("`n", ' ')
$trackerCommand = $trackerCommand.Replace('__PID__', $detectorPidPath).Replace('__STATUS__', $targetStatusPath).Replace('__OUTPUT__', $detectorOutputPath).Replace('__LOG__', $detectorLogPath)

$monitorCommand = @(
    'echo MONITOR_BEGIN'
    'printf "UPTIME="; cut -d" " -f1 /proc/uptime'
    'printf "LOAD="; cut -d" " -f1 /proc/loadavg'
    'printf "KERNEL="; uname -r'
    'printf "CAMERA="; if test -e /dev/video0; then cat /sys/class/video4linux/video0/name; else echo missing; fi'
    'printf "INFERENCE="; if test -c /dev/tinyyolo0; then echo ready; else echo missing; fi'
    $trackerCommand
    'printf "TARGET_STATUS="; if test -s "__STATUS__"; then cat "__STATUS__"; else echo missing; fi'
    'if test -d /sys/class/gpio/gpio54; then echo GPIO_EXPORTED=1; printf "GPIO_REQUEST_PAN="; cat /sys/class/gpio/gpio54/value; printf "GPIO_REQUEST_TILT="; cat /sys/class/gpio/gpio55/value; printf "GPIO_BUSY="; cat /sys/class/gpio/gpio56/value; printf "GPIO_DONE="; cat /sys/class/gpio/gpio57/value; GPIO_WIDTH=0; for i in $(seq 0 11); do value=$(cat /sys/class/gpio/gpio$((58+i))/value); GPIO_WIDTH=$((GPIO_WIDTH | (value << i))); done; echo GPIO_WIDTH=$GPIO_WIDTH; else echo GPIO_EXPORTED=0; echo GPIO_REQUEST_PAN=0; echo GPIO_REQUEST_TILT=0; echo GPIO_BUSY=0; echo GPIO_DONE=0; echo GPIO_WIDTH=0; fi'
    'echo MONITOR_END'
) -join '; '
$monitorCommand = $monitorCommand.Replace('__STATUS__', $targetStatusPath)

function Read-Prompt([int]$TimeoutSeconds = 5) {
    $response = ''
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $quietSince = [DateTime]::UtcNow
    while ([DateTime]::UtcNow -lt $deadline) {
        $chunk = $serial.ReadExisting()
        if ($chunk.Length) {
            $response += $chunk
            $quietSince = [DateTime]::UtcNow
        }
        if ($response -match '(?m)root@localhost:[^\r\n]*#\s*$' -and
            ([DateTime]::UtcNow - $quietSince).TotalMilliseconds -gt 80) {
            return $response
        }
        Start-Sleep -Milliseconds 15
    }
    throw 'Serial response timed out'
}

function Publish-Status($Status) {
    [Console]::Out.WriteLine(($Status | ConvertTo-Json -Compress -Depth 4))
}

$script:StopInputTask = [Console]::In.ReadLineAsync()
function Test-StopMessage {
    if ($script:StopInputTask.IsCompleted) {
        $message = $script:StopInputTask.GetAwaiter().GetResult()
        if ($message -eq 'STOP') { return $true }
        $script:StopInputTask = [Console]::In.ReadLineAsync()
    }
    return $false
}

try {
    while ($true) {
        if (Test-StopMessage) { break }
        try {
            if (-not $serial.IsOpen) {
                $serial.Open()
                Start-Sleep -Milliseconds 100
                $serial.Write("`r")
                try { $null = Read-Prompt 3 }
                catch {
                    $serial.Write([string][char]3 + [string][char]17 + "`r`n")
                    $null = Read-Prompt 3
                }
            }

            $timer = [Diagnostics.Stopwatch]::StartNew()
            $serial.Write($monitorCommand + "`r")
            $response = Read-Prompt 5
            $timer.Stop()
            $section = [regex]::Match($response, '(?s)MONITOR_BEGIN\r?\n(.*?)\r?\nMONITOR_END')
            if (-not $section.Success) { throw 'Board status response was incomplete' }

            $values = @{}
            foreach ($line in ($section.Groups[1].Value -split "`r?`n")) {
                $match = [regex]::Match($line, '^([A-Z_]+)=(.*)$')
                if ($match.Success) { $values[$match.Groups[1].Value] = $match.Groups[2].Value.Trim() }
            }
            $uptime = 0.0
            $load = 0.0
            [void][double]::TryParse($values.UPTIME, [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$uptime)
            [void][double]::TryParse($values.LOAD, [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$load)

            $detectorStatus = $null
            $detectorAvailable = ([string]$values.TRACKER_STATE -in @('running', 'starting'))
            $detectorState = [string]$values.TRACKER_STATE
            $targetDetected = $false
            $targetDx = $null
            $targetDy = $null
            $frameWidth = 640
            $frameHeight = 480
            $targetQuality = $null
            $targetSource = $null
            if ($detectorAvailable -and $values.TARGET_STATUS -and $values.TARGET_STATUS -ne 'missing') {
                try {
                    $detectorStatus = [string]$values.TARGET_STATUS | ConvertFrom-Json
                    $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 - [double]$detectorStatus.timestamp_unix
                    if ($age -ge 0 -and $age -le 2.5) {
                        $detectorState = [string]$detectorStatus.state
                        $targetDetected = [bool]$detectorStatus.target_detected
                        $targetDx = $detectorStatus.target_dx_px
                        $targetDy = $detectorStatus.target_dy_px
                        $frameWidth = [int]$detectorStatus.frame_width
                        $frameHeight = [int]$detectorStatus.frame_height
                        $targetQuality = $detectorStatus.target_quality
                        $targetSource = $detectorStatus.target_source
                    }
                    else {
                        $detectorAvailable = $false
                        $detectorState = 'stale'
                    }
                }
                catch {
                    $detectorAvailable = $false
                    $detectorState = 'invalid_status'
                }
            }

            Publish-Status ([ordered]@{
                connected = $true
                port = $Port
                latency_ms = $timer.ElapsedMilliseconds
                updated_at = (Get-Date -Format 'HH:mm:ss.fff')
                uptime_s = $uptime
                load = $load
                kernel = [string]$values.KERNEL
                camera = [string]$values.CAMERA
                inference = ([string]$values.INFERENCE -eq 'ready')
                detector_available = $detectorAvailable
                detector_state = $detectorState
                target_detected = $targetDetected
                target_dx_px = $targetDx
                target_dy_px = $targetDy
                frame_width = $frameWidth
                frame_height = $frameHeight
                target_quality = $targetQuality
                target_source = $targetSource
                gpio_exported = ([string]$values.GPIO_EXPORTED -eq '1')
                request_pan = ([string]$values.GPIO_REQUEST_PAN -eq '1')
                request_tilt = ([string]$values.GPIO_REQUEST_TILT -eq '1')
                busy = ([string]$values.GPIO_BUSY -eq '1')
                done = ([string]$values.GPIO_DONE -eq '1')
                bus_width_us = [int]$values.GPIO_WIDTH
                position_feedback = $false
            })
        }
        catch {
            if ($serial.IsOpen) { $serial.Close() }
            Publish-Status ([ordered]@{
                connected = $false
                port = $Port
                updated_at = (Get-Date -Format 'HH:mm:ss')
                error = $_.Exception.Message
            })
        }
        Start-Sleep -Milliseconds 250
    }
}
finally {
    if ($serial.IsOpen) {
        try {
            $stopCommand = @'
if test -f '__PID__'; then p=$(cat '__PID__'); if test -d "/proc/$p" && tr '\000' ' ' < "/proc/$p/cmdline" | grep -F -- '__STATUS__' >/dev/null; then kill -INT "$p" 2>/dev/null || true; fi; rm -f '__PID__' '__STATUS__'; fi; echo MONITOR_STOPPED
'@
            $stopCommand = $stopCommand.Trim().Replace('__PID__', $detectorPidPath).Replace('__STATUS__', $targetStatusPath) + "`r"
            $serial.Write($stopCommand)
            $null = Read-Prompt 3
        }
        catch { }
    }
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
}
