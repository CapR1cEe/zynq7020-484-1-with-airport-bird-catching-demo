param([string]$Vivado='C:/AMDDesigntools/2025.2/Vivado/bin/vivado.bat')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$runDir=Join-Path $root 'vivado/TinyYOLO_192.runs/synth_1'
$scriptPath=Join-Path $runDir 'Tiny_Yolo_wrapper.tcl'
$frozen=Get-Content -LiteralPath (Join-Path $root 'reports/build_source_sha256.json') -Raw | ConvertFrom-Json
function Check-FrozenSources {
    foreach($entry in $frozen.PSObject.Properties) {
        $actual=(Get-FileHash -LiteralPath (Join-Path $root $entry.Name) -Algorithm SHA256).Hash.ToLower()
        if($actual -ne $entry.Value){throw "Build source changed: $($entry.Name)"}
    }
}
Check-FrozenSources
if((Get-Content -LiteralPath $scriptPath -Raw) -notmatch '(?m)^synth_design -top Tiny_Yolo_wrapper ') {
    throw 'The generated native synthesis script is missing its synth_design step.'
}
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
    & $Vivado -log Tiny_Yolo_wrapper.vds -m64 -product Vivado -messageDb vivado.pb -mode batch -source Tiny_Yolo_wrapper.tcl -notrace 2>&1 |
        Tee-Object -FilePath (Join-Path $runDir 'runme.log')
    $toolExit=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    if($toolExit -ne 0){throw "Vivado synthesis exited $toolExit"}
    $complete=Get-Item -LiteralPath (Join-Path $runDir '__synthesis_is_complete__')
    $checkpoint=Get-Item -LiteralPath (Join-Path $runDir 'Tiny_Yolo_wrapper.dcp')
    if($complete.LastWriteTimeUtc -lt $started -or $checkpoint.LastWriteTimeUtc -lt $started -or $checkpoint.Length -eq 0) {
        throw 'This invocation did not finish native synthesis.'
    }
    Check-FrozenSources
    [IO.File]::WriteAllText((Join-Path $runDir '.vivado.end.rst'),'')
    [ordered]@{status='PASS_NATIVE_SYNTHESIS_PROCESS';vivado_exit_code=$toolExit;
        started_utc=$started.ToString('o');finished_utc=[DateTime]::UtcNow.ToString('o');
        generated_script_sha256=(Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLower();
        checkpoint_sha256=(Get-FileHash -LiteralPath $checkpoint.FullName -Algorithm SHA256).Hash.ToLower();
        source_sha256=$frozen;run_properties_forced=$false;full_synthesis_repeated=$true;
        frozen_sources_verified_before_and_after=$true} | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $root 'reports/native_synthesis_process.json') -Encoding UTF8
    Write-Output 'CLOCKFIX_NATIVE_SYNTHESIS_PASS'
} catch {
    [IO.File]::WriteAllText((Join-Path $runDir '.vivado.error.rst'),'')
    throw
} finally {Pop-Location}
