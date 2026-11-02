param([string]$Vivado='C:/AMDDesigntools/2025.2/Vivado/bin/vivado.bat')
# Freeze inputs, generate Vivado's native scripts, and run both tools directly.
# This path also works when Windows Script Host / cscript is unavailable.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$env:XILINX_LOCAL_USER_DATA='no'
if(!(Test-Path -LiteralPath (Join-Path $root 'vivado/TinyYOLO_192.xpr'))) {
    throw 'Extract the complete delivery before rebuilding.'
}
$inventory=[ordered]@{}
Get-ChildItem -LiteralPath (Join-Path $root 'hardware') -File -Recurse | Sort-Object FullName | ForEach-Object {
    $name=$_.FullName.Substring($root.Length+1).Replace('\','/')
    $inventory[$name]=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()
}
foreach($name in @('build_vivado.ps1','build_vivado.tcl','message_policy.tcl','cleanup_unused_reset.tcl',
    'cleanup_unused_cdc_data.tcl','implementation_pre_bitstream.tcl','implementation_pre_opt.tcl',
    'optimize_control_fanout.tcl','require_timing_closure.tcl','diagnose_synthesis.tcl',
    'restore_implementation_budget.tcl','distribute_synchronous_reset.tcl','assert_clock_topology.tcl',
    'run_synthesis_direct.ps1','run_implementation_direct.ps1','rebuild_clockfix.ps1')) {
    $inventory["scripts/$name"]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash.ToLower()
}
$stamp=[DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff')
$archive=Join-Path $root "reports/history/before_rebuild_$stamp"
New-Item -ItemType Directory -Path $archive | Out-Null
foreach($name in @('build_source_sha256.json','native_synthesis_process.json','native_implementation_process.json',
    'finalization_provenance.json','timing_repair_provenance.json','artifact_sha256.json','delivery_audit.json')) {
    $path=Join-Path $root "reports/$name"
    if(Test-Path -LiteralPath $path){Move-Item -LiteralPath $path -Destination (Join-Path $archive $name)}
}
$inventory | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root 'reports/build_source_sha256.json') -Encoding UTF8
function Phase([string]$label,[string]$source,[string[]]$Arguments=@()) {
    Push-Location -LiteralPath $root
    try {
        $ErrorActionPreference='Continue'
        & $Vivado -mode batch -nojournal -notrace -log "reports/$label.log" -source $source @Arguments *> "reports/${label}_console.log"
        $code=$LASTEXITCODE
        $ErrorActionPreference='Stop'
        if($code -ne 0){throw "Vivado phase $label exited $code"}
    } finally {Pop-Location}
}
Phase 'clockfix_prepare_synth' 'scripts/build_vivado.tcl' @('-tclargs','scripts_synth')
& (Join-Path $PSScriptRoot 'run_synthesis_direct.ps1') -Vivado $Vivado
Phase 'clockfix_prepare_impl' 'scripts/build_vivado.tcl' @('-tclargs','scripts_impl')
& (Join-Path $PSScriptRoot 'run_implementation_direct.ps1') -Vivado $Vivado
Phase 'final_export' 'scripts/build_vivado.tcl' @('-tclargs','finish')
Phase 'synthesis_diagnostics_final' 'scripts/diagnose_synthesis.tcl'
Phase 'project_open_check' 'scripts/verify_project.tcl'
Write-Output 'CLOCKFIX_BUILD_COMPLETE regression_and_package_audit_required=1'
