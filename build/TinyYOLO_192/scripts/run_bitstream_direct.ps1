param([string]$Vivado='C:/AMDDesigntools/2025.2/Vivado/bin/vivado.bat')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$runDir=Join-Path $root 'vivado/TinyYOLO_192.runs/impl_1'
$checkpoint=Join-Path $runDir 'Tiny_Yolo_wrapper_postroute_physopt.dcp'
$scriptPath=Join-Path $runDir 'Tiny_Yolo_wrapper.tcl'
if(!(Test-Path -LiteralPath $checkpoint) -or !(Test-Path -LiteralPath $scriptPath)) {
    throw 'An existing routed checkpoint and Vivado-generated run script are required.'
}
# Run only a generated script whose active step is write_bitstream.
$text=Get-Content -LiteralPath $scriptPath -Raw
$steps=@([regex]::Matches($text,'(?m)^start_step (\S+)\s*$') | ForEach-Object {$_.Groups[1].Value})
if($steps.Count -ne 1 -or $steps[0] -ne 'write_bitstream') {
    throw 'Generate a write_bitstream-only run script before using this launcher.'
}
$before=(Get-FileHash -LiteralPath $checkpoint -Algorithm SHA256).Hash.ToLower()
$env:XILINX_LOCAL_USER_DATA='no'
$started=[DateTime]::UtcNow
# Equivalent to the Vivado ISEWrap process lifecycle, using the actual exit code.
# This replaces the unavailable Windows Script Host launcher; no run property is forced.
$begin=[xml]'<?xml version="1.0"?><ProcessHandle Version="1" Minor="0"><Process /></ProcessHandle>'
$process=$begin.SelectSingleNode('/ProcessHandle/Process')
$process.SetAttribute('Command','powershell.exe')
$process.SetAttribute('Owner',[Environment]::UserName)
$process.SetAttribute('Host',[Environment]::MachineName)
$process.SetAttribute('Pid',"$PID")
$begin.Save((Join-Path $runDir '.vivado.begin.rst'))
foreach($name in @('.vivado.end.rst','.vivado.error.rst')) {
    $old=Join-Path $runDir $name
    if(Test-Path -LiteralPath $old){Remove-Item -LiteralPath $old}
}
Push-Location -LiteralPath $runDir
try {
    $ErrorActionPreference='Continue'
    & $Vivado -log Tiny_Yolo_wrapper.vdi -applog -m64 -product Vivado -messageDb vivado.pb -mode batch -source Tiny_Yolo_wrapper.tcl -notrace 2>&1 |
        Tee-Object -FilePath (Join-Path $runDir 'runme.log')
    $toolExit=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    if($toolExit -ne 0){throw "Vivado exited $toolExit"}
    $stepEnd=Get-Item -LiteralPath (Join-Path $runDir '.write_bitstream.end.rst')
    $bit=Get-Item -LiteralPath (Join-Path $runDir 'Tiny_Yolo_wrapper.bit')
    if($stepEnd.LastWriteTimeUtc -lt $started -or $bit.LastWriteTimeUtc -lt $started -or $bit.Length -eq 0) {
        throw 'Current invocation did not produce a completed bitstream.'
    }
    if((Get-FileHash -LiteralPath $checkpoint -Algorithm SHA256).Hash.ToLower() -ne $before) {
        throw 'Routed checkpoint changed during bitstream export.'
    }
    [IO.File]::WriteAllText((Join-Path $runDir '.vivado.end.rst'),'')
    $receipt=[ordered]@{status='PASS_NATIVE_BITSTREAM_PROCESS';vivado_exit_code=$toolExit;
        started_utc=$started.ToString('o');finished_utc=[DateTime]::UtcNow.ToString('o');
        generated_script_sha256=(Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLower();
        checkpoint_sha256=$before;checkpoint_unchanged=$true;
        bit_sha256=(Get-FileHash -LiteralPath $bit.FullName -Algorithm SHA256).Hash.ToLower();
        run_properties_forced=$false}
    $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'reports/native_bitstream_process.json') -Encoding UTF8
    Write-Output 'FINAL_NATIVE_BITSTREAM_PROCESS_PASS'
} catch {
    [IO.File]::WriteAllText((Join-Path $runDir '.vivado.error.rst'),'')
    throw
} finally {Pop-Location}
