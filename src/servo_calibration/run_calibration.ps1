param([ValidateRange(2000,2500)][int]$WidthUs = 2250)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$utf8 = [Text.UTF8Encoding]::new($false)
if (-not (Select-String -Path "$root\build_microtest.log" -Pattern '^SERVO_CALIBRATION_BUILD_PASS frames=150 range_us=2000:2500 ' -Quiet)) { throw 'Calibration build is incomplete' }
if (-not (Select-String -Path "$root\sim\simulation.log" -Pattern '^CALIBRATION_RTL_PASS$' -Quiet)) { throw 'Calibration RTL simulation is incomplete' }
foreach ($check in 'Setup','Hold') {
    if (-not (Select-String -Path "$root\reports\timing.rpt" -Pattern "$check\s*:\s*0\s+Failing Endpoints,\s*Worst Slack\s+[0-9.]+ns" -Quiet)) { throw "$check timing failed" }
}
if (-not (Select-String -Path "$root\reports\drc.rpt" -Pattern 'Checks found:\s*0' -Quiet)) { throw 'Calibration DRC failed' }
if ((Get-Item "$root\firmware\servo_calibration.bit").Length -lt 1024) { throw 'Calibration bitstream is incomplete' }
$runId = 'cal{0}_{1}' -f $WidthUs,[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssffff')
$runroot = Join-Path (Join-Path $root 'runs') $runId
New-Item -ItemType Directory -Path $runroot | Out-Null
$serial = [IO.Ports.SerialPort]::new('COM5',115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
$serial.Handshake='None'
$serial.DtrEnable=$false
$serial.RtsEnable=$false
$serial.WriteTimeout=3000
$capture=[Text.StringBuilder]::new()
$process=$null
$quiesced=$false
$sequence=$null
$postflight=$null
function Read-Prompt([int]$seconds=10) {
    $response=''
    $deadline=[DateTime]::UtcNow.AddSeconds($seconds)
    $quiet=[DateTime]::UtcNow
    while ([DateTime]::UtcNow -lt $deadline) {
        $chunk=$serial.ReadExisting()
        if ($chunk.Length) { $response += $chunk; $quiet=[DateTime]::UtcNow }
        if ($response -match 'root@localhost:[^\r\n]*#\s*$' -and ([DateTime]::UtcNow-$quiet).TotalMilliseconds -gt 70) {
            [void]$capture.Append($response)
            return $response
        }
        Start-Sleep -Milliseconds 20
    }
    [void]$capture.Append($response)
    throw 'Linux serial response timed out'
}
function Command([string]$line) { $serial.Write($line+"`r"); Read-Prompt }
function Synchronize-Serial {
    [void]$capture.Append($serial.ReadExisting())
    $serial.Write("`r")
    Start-Sleep -Milliseconds 200
    $serial.Write([string][char]3+[string][char]17+"`r`n")
    $null=Read-Prompt
}
function Upload([string]$local,[string]$remote) {
    $base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($local))
    $null=Command ": > $remote.b64"
    for ($index=0; $index -lt $base64.Length; $index+=180) {
        $chunk=$base64.Substring($index,[Math]::Min(180,$base64.Length-$index))
        $null=Command "printf '%s' '$chunk' >> $remote.b64"
    }
    $result=Command "base64 -d $remote.b64 > $remote; printf '\nUPLOAD_RC=%s\n' `$?"
    if ($result -notmatch '(?m)^UPLOAD_RC=0\r?$') { throw 'Board script transfer failed' }
}
try {
    $serial.Open()
    [void]$capture.Append($serial.ReadExisting())
    $serial.Write([string][char]17+"`r`n")
    $null=Read-Prompt
    Upload "$root\quiesce_for_servo.sh" "/tmp/${runId}_prepare.sh"
    Upload "$root\microtest_axis.py" "/tmp/${runId}_run.py"
    Upload "$root\restore_driver.sh" "/tmp/${runId}_restore.sh"
    $result=Command "sh /tmp/${runId}_prepare.sh; printf '\nPREPARE_RC=%s\n' `$?"
    Write-Output $result
    if ($result -notmatch '(?m)^PREPARE_RC=0\r?$') { throw 'Inference driver could not be quiesced' }
    $quiesced=$true
    $env:XILINX_LOCAL_USER_DATA=Join-Path $root '.vivado_user_data'
    $vivado='C:\AMDDesigntools\2025.2\Vivado\bin\vivado.bat'
    $arguments="/d /c $vivado -mode batch -nojournal -log `"$runroot\hardware.log`" -source `"$root\test_and_restore.tcl`" -tclargs `"$runroot`""
    $process=Start-Process -FilePath $env:ComSpec -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$runroot\hardware_console.log" -RedirectStandardError "$runroot\hardware_stderr.log"
    $deadline=[DateTime]::UtcNow.AddSeconds(50)
    while (-not (Test-Path "$runroot\test_programmed.flag")) {
        if ($process.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'Calibration configuration was not confirmed' }
        Start-Sleep -Milliseconds 100
    }
    Write-Output "CALIBRATION_READY width_us=$WidthUs run_id=$runId"
    Synchronize-Serial
    $line="test `"`$(cat /proc/sys/kernel/random/boot_id)`" = `"`$(cat /tmp/servo_microtest_retest_boot_id)`" && test ! -e /dev/tinyyolo0 && python3 /tmp/${runId}_run.py $WidthUs $runId; printf '\nTEST_RC=%s\n' `$?"
    $result=Command $line
    Write-Output $result
    if ($result -notmatch "(?m)^CALIBRATION_SEQUENCE_PASS width_us=$WidthUs pulses=150 duration_ms=3000\r?$" -or $result -notmatch '(?m)^TEST_RC=0\r?$') { throw 'Calibration completion not confirmed; no automatic retry' }
    $sequence=[regex]::Match($result,'(?m)^\{"axis": [^\r\n]*\}\r?$').Value.Trim() | ConvertFrom-Json
} finally {
    if ($null -ne $process) {
        [IO.File]::WriteAllText("$runroot\restore_requested.flag",'restore',$utf8)
        if (-not $process.WaitForExit(60000)) { Write-Warning 'Restoration is still running; inspect hardware.log' }
    }
    try {
        $restoreConfirmed=Test-Path "$runroot\inference_restored.flag"
        $programmingStarted=Test-Path "$runroot\programming_started.flag"
        if ($quiesced -and ($restoreConfirmed -or $null -eq $process -or ($process.HasExited -and -not $programmingStarted))) {
            Synchronize-Serial
            $line="sh /tmp/${runId}_restore.sh && (for pin in `$(seq 54 69); do test ! -d /sys/class/gpio/gpio`$pin || exit 1; done); printf '\nRESTORE_RC=%s\n' `$?"
            $result=Command $line
            Write-Output $result
            if ($result -notmatch '(?m)^SERVO_ORIGINAL_INFERENCE_RESTORED\r?$' -or $result -notmatch '(?m)^RESTORE_RC=0\r?$') { throw 'Inference or GPIO restoration failed' }
            $postflight=[regex]::Match($result,'(?m)^\{"abi": [^\r\n]*\}\r?$').Value.Trim() | ConvertFrom-Json
        } elseif ($quiesced) { throw 'Original bitstream restoration is not confirmed; driver left unloaded' }
    } finally {
        [IO.File]::WriteAllText("$runroot\board_console.log",$capture.ToString(),$utf8)
        $serial.Close()
        $serial.Dispose()
        $record=[ordered]@{run_id=$runId;width_us=$WidthUs;axis='tilt';ball='H19';pulses=150;duration_ms=3000;H20='constant_low';runtime=$sequence;restored_inference=$postflight;physical_motion_confirmed=$null;physical_observation_status='awaiting_user_feedback';angle_reference='fixed_operator_zero';angle_sign='forward_positive_backward_negative';physical_pin_waveform_measured=$false;bitstream_sha256=(Get-FileHash -LiteralPath "$root\firmware\servo_calibration.bit" -Algorithm SHA256).Hash}
        [IO.File]::WriteAllText("$runroot\receipt.json",($record|ConvertTo-Json -Depth 8),$utf8)
    }
}
Write-Output "CALIBRATION_COMPLETED_AND_INFERENCE_RESTORED width_us=$WidthUs run_id=$runId"
