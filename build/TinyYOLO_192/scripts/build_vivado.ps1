param([string]$Vivado='C:/AMDDesigntools/2025.2/Vivado/bin/vivado.bat',[switch]$ResumeSynthesis,[switch]$RebuildImplementation)
$ErrorActionPreference='Stop'
if($ResumeSynthesis -and $RebuildImplementation){throw 'Choose only one resume mode'}
$root=Split-Path -Parent $PSScriptRoot
$env:XILINX_LOCAL_USER_DATA='no'
New-Item -ItemType Directory -Path (Join-Path $root 'reports') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $root 'firmware') -Force | Out-Null
$frozen=[ordered]@{}
Get-ChildItem -LiteralPath (Join-Path $root 'hardware') -File -Recurse | ForEach-Object {
    $key=$_.FullName.Substring($root.Length+1).Replace('\','/')
    $frozen[$key]=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()
}
foreach($name in @('build_vivado.ps1','build_vivado.tcl','message_policy.tcl','cleanup_unused_reset.tcl',
                  'cleanup_unused_cdc_data.tcl','implementation_pre_bitstream.tcl',
                  'implementation_pre_opt.tcl','optimize_control_fanout.tcl','require_timing_closure.tcl',
                  'diagnose_synthesis.tcl','restore_implementation_budget.tcl','distribute_synchronous_reset.tcl')) {
    $frozen["scripts/$name"]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash.ToLower()
}
$inventoryPath=Join-Path $root 'reports/build_source_sha256.json'
if($RebuildImplementation) {
    if(!(Test-Path -LiteralPath $inventoryPath)){throw 'Implementation reuse requires the original source inventory'}
    $previousInventory=Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    $synthesisSources=[ordered]@{}
    foreach($key in $frozen.Keys) {
        if($key.StartsWith('hardware/') -or $key -eq 'scripts/message_policy.tcl') {
            if($previousInventory.$key -ne $frozen[$key]){throw "Synthesis source mismatch: $key. Run a full rebuild."}
            $synthesisSources[$key]=$frozen[$key]
        }
    }
    $oldHardware=@($previousInventory.PSObject.Properties.Name | Where-Object {$_.StartsWith('hardware/')})
    $newHardware=@($frozen.Keys | Where-Object {$_.StartsWith('hardware/')})
    if($oldHardware.Count -ne $newHardware.Count){throw 'Synthesis source inventory changed. Run a full rebuild.'}
    $synthCheckpoint=Join-Path $root 'vivado/TinyYOLO_192.runs/synth_1/Tiny_Yolo_wrapper.dcp'
    $reuse=[ordered]@{status='REUSE_IDENTICAL_SYNTHESIS_SOURCES';source_sha256=$synthesisSources;
        checkpoint='vivado/TinyYOLO_192.runs/synth_1/Tiny_Yolo_wrapper.dcp';
        checkpoint_sha256=(Get-FileHash -LiteralPath $synthCheckpoint -Algorithm SHA256).Hash.ToLower()}
    $reuse | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root 'reports/synthesis_reuse.json') -Encoding UTF8
    $frozen | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $inventoryPath -Encoding UTF8
} elseif($ResumeSynthesis) {
    if(!(Test-Path -LiteralPath $inventoryPath)){throw 'Resume requires an existing frozen source inventory'}
    $previousInventory=Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    foreach($key in $frozen.Keys) {
        if($previousInventory.$key -ne $frozen[$key]){throw "Frozen source mismatch: $key. Run a full rebuild."}
    }
} else {
    $frozen | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $inventoryPath -Encoding UTF8
}
function Invoke-Tool([string[]]$ToolArgs) {
    $previous=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & $Vivado @ToolArgs 2>&1 | Out-String -Stream
        $script:toolExit=$LASTEXITCODE
    } finally {$ErrorActionPreference=$previous}
    if($script:toolExit){throw "Vivado exited $script:toolExit"}
}
function Phase([string]$name) {
    Push-Location -LiteralPath $root
    try {Invoke-Tool @('-mode','batch','-nojournal','-notrace','-log',(Join-Path $root ("reports/$name.log")),'-source',(Join-Path $PSScriptRoot 'build_vivado.tcl'),'-tclargs',$name)}
    finally {Pop-Location}
}
if($RebuildImplementation){Phase 'rebuild_impl'}
elseif($ResumeSynthesis){Phase 'resume_synth'}
elseif(Test-Path -LiteralPath (Join-Path $root 'vivado/TinyYOLO_192.xpr')){Phase 'rebuild'}
else{Phase 'prepare'}
Push-Location -LiteralPath $root
try {
    Invoke-Tool @('-mode','batch','-nojournal','-notrace','-log',(Join-Path $root 'reports/synthesis_diagnostics.log'),
                 '-source',(Join-Path $PSScriptRoot 'diagnose_synthesis.tcl'))
} finally {Pop-Location}
Phase 'prepare_impl'
Phase 'finish'
foreach($key in $frozen.Keys) {
    $actual=(Get-FileHash -LiteralPath (Join-Path $root $key) -Algorithm SHA256).Hash.ToLower()
    if($actual -ne $frozen[$key]){throw "Source changed during build: $key"}
}
Write-Output 'FINAL_SOURCE_IDENTITY_PASS'
