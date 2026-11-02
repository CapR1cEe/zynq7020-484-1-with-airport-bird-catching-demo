[CmdletBinding()]
param(
    [ValidateSet('track', 'home-only', 'batch20', 'boundary-sweep', 'smooth-boundary')]
    [string]$Mode = 'track'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$utf8 = [Text.UTF8Encoding]::new($false)
$vivado = 'C:\AMDDesigntools\2025.2\Vivado\bin\vivado.bat'
if (-not (Test-Path -LiteralPath $vivado)) { throw 'Vivado 2025.2 is unavailable' }
$env:XILINX_LOCAL_USER_DATA = Join-Path $root '.vivado_user_data'

$vivadoSimLog = Join-Path $root 'sim_pan_tilt_link.log'
if (-not (Test-Path $vivadoSimLog) -or -not (Select-String -Path $vivadoSimLog -Pattern '^PAN_TILT_LINK_RTL_PASS' -Quiet) -or (Select-String -Path $vivadoSimLog -Pattern '^Fatal:' -Quiet)) {
    $simProcess = Start-Process -FilePath $vivado -ArgumentList "-mode batch -nojournal -log `"$vivadoSimLog`" -source `"$root\sim_pan_tilt_link.tcl`"" -WindowStyle Hidden -PassThru -Wait
    if ($simProcess.ExitCode -ne 0) { throw "Pan-tilt RTL simulation failed (exit $($simProcess.ExitCode))" }
}
if (-not (Select-String -Path $vivadoSimLog -Pattern '^PAN_TILT_LINK_RTL_PASS' -Quiet)) { throw 'Pan-tilt RTL simulation did not report its pass marker' }

$buildLog = Join-Path $root 'build_pan_tilt_link.log'
if (-not (Test-Path $buildLog) -or -not (Select-String -Path $buildLog -Pattern '^SERVO_PAN_TILT_LINK_BUILD_PASS frames=50 range_us=1000:2300 stream=4095:start,4094:stop pan_pin=H20 tilt_pin=H19 ' -Quiet) -or -not (Test-Path "$root\firmware\servo_pan_tilt_link.bit")) {
    $buildProcess = Start-Process -FilePath $vivado -ArgumentList "-mode batch -nojournal -log `"$buildLog`" -source `"$root\build_pan_tilt_link.tcl`"" -WindowStyle Hidden -PassThru -Wait
    if ($buildProcess.ExitCode -ne 0) { throw "Pan-tilt FPGA build failed (exit $($buildProcess.ExitCode))" }
}
if (-not (Select-String -Path $buildLog -Pattern '^SERVO_PAN_TILT_LINK_BUILD_PASS frames=50 range_us=1000:2300 stream=4095:start,4094:stop pan_pin=H20 tilt_pin=H19 ' -Quiet)) { throw 'Pan-tilt FPGA build is incomplete' }
foreach ($check in 'Setup','Hold') {
    if (-not (Select-String -Path "$root\reports\timing.rpt" -Pattern "$check\s*:\s*0\s+Failing Endpoints,\s*Worst Slack\s+[0-9.]+ns" -Quiet)) { throw "$check timing failed" }
}
if (-not (Select-String -Path "$root\reports\drc.rpt" -Pattern 'Checks found:\s*0' -Quiet)) { throw 'Pan-tilt DRC failed' }
if ((Get-Item "$root\firmware\servo_pan_tilt_link.bit").Length -lt 1024) { throw 'Pan-tilt bitstream is incomplete' }

$runId = 'pantilt_{0}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssffff')
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
$cameraAvailable=$false
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
function Command([string]$line,[int]$seconds=10) { $serial.Write($line+"`r"); Read-Prompt $seconds }
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
    $cameraCheck=Command 'test -c /dev/video0 && test "$(cat /sys/class/video4linux/video0/name)" = "USB Camera"; printf "\nCAMERA_ENUM_RC=%s\n" $?'
    $cameraAvailable=$cameraCheck -match '(?m)^CAMERA_ENUM_RC=0\r?$'
    if (-not $cameraAvailable) { Write-Output 'CAMERA_NOT_CONNECTED continuing_without_capture' }
    Upload "$root\quiesce_for_servo.sh" "/tmp/${runId}_prepare.sh"
    Upload "$root\pan_tilt_link.py" "/tmp/${runId}_run.py"
    Upload "$root\restore_driver.sh" "/tmp/${runId}_restore.sh"
    $result=Command "sh /tmp/${runId}_prepare.sh; printf '\nPREPARE_RC=%s\n' `$?"
    Write-Output $result
    if ($result -notmatch '(?m)^PREPARE_RC=0\r?$') { throw 'Inference driver could not be quiesced' }
    $quiesced=$true
    $arguments="-mode batch -nojournal -log `"$runroot\hardware.log`" -source `"$root\test_and_restore_pan_tilt_link.tcl`" -tclargs `"$runroot`""
    $process=Start-Process -FilePath $vivado -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$runroot\hardware_console.log" -RedirectStandardError "$runroot\hardware_stderr.log"
    $deadline=[DateTime]::UtcNow.AddSeconds(50)
    while (-not (Test-Path "$runroot\test_programmed.flag")) {
        if ($process.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'Pan-tilt configuration was not confirmed' }
        Start-Sleep -Milliseconds 100
    }
    Write-Output "PAN_TILT_LINK_READY run_id=$runId"
    Synchronize-Serial
    $line="test `"`$(cat /proc/sys/kernel/random/boot_id)`" = `"`$(cat /tmp/servo_microtest_retest_boot_id)`" && test ! -e /dev/tinyyolo0 && python3 /tmp/${runId}_run.py /tmp/${runId}_view.jpg $Mode; printf '\nTEST_RC=%s\n' `$?"
    $commandTimeout = if ($Mode -eq 'batch20') { 2100 } elseif ($Mode -eq 'smooth-boundary') { 240 } elseif ($Mode -eq 'boundary-sweep') { 180 } else { 75 }
    $result=Command $line $commandTimeout
    Write-Output $result
    $sequence=[regex]::Match($result,'(?m)^\{[^\r\n]*"axis": "pan\+tilt"[^\r\n]*\}\r?$').Value.Trim() | ConvertFrom-Json
    $homeMarker = $sequence.home_us -join ','
    if ($Mode -eq 'home-only') {
        $passMarker = "PAN_TILT_HOME_CORRECTION_PASS home=$homeMarker"
    } elseif ($Mode -eq 'batch20') {
        $passMarker = "PAN_TILT_BATCH20_PASS groups=$($sequence.group_count) tracking_s=$($sequence.tracking_duration_s) rest_s=$($sequence.inter_group_rest_s) home=$homeMarker"
    } elseif ($Mode -eq 'boundary-sweep') {
        $passMarker = "PAN_TILT_BOUNDARY_SWEEP_PASS steps=$($sequence.boundary_sweep_steps) approach=$($sequence.boundary_approach_steps) start=$($sequence.boundary_start_us -join ',') end=$($sequence.boundary_end_us -join ',') home=$homeMarker"
    } elseif ($Mode -eq 'smooth-boundary') {
        $passMarker = "PAN_TILT_SMOOTH_BOUNDARY_PASS approach=$($sequence.smooth_approach_steps) sweep=$($sequence.smooth_sweep_steps) start=$($sequence.boundary_start_us -join ',') end=$($sequence.boundary_end_us -join ',') home=$homeMarker"
    } else {
        $passMarker = "PAN_TILT_TRACK_SIM_PASS steps=$($sequence.tracking_path_us.Count) duration_s=$($sequence.tracking_duration_s) home=$homeMarker"
    }
    if ($result -notmatch ('(?m)^' + [regex]::Escape($passMarker) + '\r?$') -or $result -notmatch '(?m)^TEST_RC=0\r?$') { throw 'Pan-tilt motion completion not confirmed; no automatic retry' }
    if ($sequence.camera_frame) {
        $remoteFrame=[string]$sequence.camera_frame
        $frameOutput=Command "base64 '$remoteFrame' | tr -d '\n'; printf '\nFRAME_B64_DONE\n'" 60
        $frameMatch=[regex]::Match($frameOutput,'(?s)\r?\n([A-Za-z0-9+/=]+)\r?\nFRAME_B64_DONE')
        if (-not $frameMatch.Success) { throw 'Camera frame could not be retrieved over serial' }
        $localFrame=Join-Path $runroot 'track_view.jpg'
        [IO.File]::WriteAllBytes($localFrame,[Convert]::FromBase64String($frameMatch.Groups[1].Value))
        $sequence | Add-Member -NotePropertyName camera_frame_local -NotePropertyValue $localFrame -Force
    }
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
        $trackPath = @($sequence.tracking_path_us | ForEach-Object { $_ -join ',' })
        $sequenceMode = if ($Mode -eq 'home-only') { 'one_shot_home_correction' } elseif ($Mode -eq 'batch20') { 'twenty_groups_with_home_and_inter_group_rest' } elseif ($Mode -eq 'boundary-sweep') { 'slow_dual_axis_boundary_sweep_with_home_return' } elseif ($Mode -eq 'smooth-boundary') { 'continuous_dual_axis_stream_boundary_sweep' } else { 'simulated_target_path_synchronized_independent_widths' }
        $moveDurationMs = if ($sequence.transitions.Count -gt 0) { [int]([double]$sequence.transitions[0].run.completed_after_s * 1000) } else { 0 }
        $record=[ordered]@{run_id=$runId;axis='pan+tilt';sequence_mode=$sequenceMode;pan_ball='H20';tilt_ball='H19';camera_connected=$cameraAvailable;track_path_us=$trackPath;home_widths_us=@($sequence.home_us);frames_per_move=$sequence.frames_per_move;duration_ms_per_move=$moveDurationMs;repeats_per_target=$sequence.repeats_per_target;tracking_duration_s=$sequence.tracking_duration_s;group_count=$sequence.group_count;inter_group_rest_s=$sequence.inter_group_rest_s;boundary_start_us=@($sequence.boundary_start_us);boundary_end_us=@($sequence.boundary_end_us);boundary_approach_steps=$sequence.boundary_approach_steps;boundary_sweep_steps=$sequence.boundary_sweep_steps;smooth_approach_steps=$sequence.smooth_approach_steps;smooth_sweep_steps=$sequence.smooth_sweep_steps;runtime=$sequence;restored_inference=$postflight;physical_motion_confirmed=$null;physical_pin_waveform_measured=$false;bitstream_sha256=(Get-FileHash -LiteralPath "$root\firmware\servo_pan_tilt_link.bit" -Algorithm SHA256).Hash}
        [IO.File]::WriteAllText("$runroot\receipt.json",($record|ConvertTo-Json -Depth 8),$utf8)
    }
}
Write-Output "PAN_TILT_LINK_COMPLETED_AND_INFERENCE_RESTORED run_id=$runId"
