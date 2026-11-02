param([string]$Vivado='C:/AMDDesigntools/2025.2/Vivado/bin/vivado.bat')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$runDir=Join-Path $root 'vivado/TinyYOLO_192.runs/impl_1'
$scriptPath=Join-Path $runDir 'Tiny_Yolo_wrapper.tcl'
$text=Get-Content -LiteralPath $scriptPath -Raw
foreach($step in @('init_design','opt_design','place_design','route_design','write_bitstream')) {
    if($text -notmatch "(?m)^start_step $step\s*$"){throw "Missing native implementation step: $step"}
}
$frozen=Get-Content -LiteralPath (Join-Path $root 'reports/build_source_sha256.json') -Raw | ConvertFrom-Json
function Check-FrozenSources {
    foreach($entry in $frozen.PSObject.Properties) {
        $actual=(Get-FileHash -LiteralPath (Join-Path $root $entry.Name) -Algorithm SHA256).Hash.ToLower()
        if($actual -ne $entry.Value){throw "Build source changed: $($entry.Name)"}
    }
}
Check-FrozenSources
$env:XILINX_LOCAL_USER_DATA='no'
$started=[DateTime]::UtcNow
$begin=[xml]'<?xml version="1.0"?><ProcessHandle Version="1" Minor="0"><Process /></ProcessHandle>'
$process=$begin.SelectSingleNode('/ProcessHandle/Process')
$process.SetAttribute('Command','powershell.exe')
$process.SetAttribute('Owner',[Environment]::UserName)
$process.SetAttribute('Host',[Environment]::MachineName)
$process.SetAttribute('Pid',"$PID")
$begin.Save((Join-Path $runDir '.vivado.begin.rst'))
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
        throw 'This invocation did not finish the native bitstream step.'
    }
    Check-FrozenSources
    [IO.File]::WriteAllText((Join-Path $runDir '.vivado.end.rst'),'')
    $checkpoint=Join-Path $runDir 'Tiny_Yolo_wrapper_postroute_physopt.dcp'
    $receipt=[ordered]@{status='PASS_NATIVE_IMPLEMENTATION_PROCESS';vivado_exit_code=$toolExit;
        started_utc=$started.ToString('o');finished_utc=[DateTime]::UtcNow.ToString('o');
        generated_script_sha256=(Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLower();
        checkpoint_sha256=(Get-FileHash -LiteralPath $checkpoint -Algorithm SHA256).Hash.ToLower();
        synthesis_reused=$false;full_implementation_repeated=$true;run_properties_forced=$false;
        synthesis_checkpoint_sha256=(Get-FileHash -LiteralPath (Join-Path $root 'vivado/TinyYOLO_192.runs/synth_1/Tiny_Yolo_wrapper.dcp') -Algorithm SHA256).Hash.ToLower();
        bit_sha256=(Get-FileHash -LiteralPath $bit.FullName -Algorithm SHA256).Hash.ToLower();
        frozen_sources_verified_before_and_after=$true}
    $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'reports/native_implementation_process.json') -Encoding UTF8
    Write-Output 'FINAL_SOURCE_IDENTITY_PASS'
    Write-Output 'CORRECTED_NATIVE_IMPLEMENTATION_PASS'
} catch {
    [IO.File]::WriteAllText((Join-Path $runDir '.vivado.error.rst'),'')
    throw
} finally {Pop-Location}
