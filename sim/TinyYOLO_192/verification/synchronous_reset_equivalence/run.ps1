$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $taskRoot 'work/reset_retiming_unisim'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$bin='C:/AMDDesigntools/2025.2/Vivado/bin'
Push-Location -LiteralPath $testRoot
try {
    & (Join-Path $bin 'xvlog.bat') (Join-Path $taskRoot 'work/reset_retime_tb.v') 'C:/AMDDesigntools/2025.2/Vivado/data/verilog/src/glbl.v' *> compile_console.log
    if($LASTEXITCODE){throw 'UNISIM reset test compilation failed'}
    & (Join-Path $bin 'xelab.bat') reset_retime_tb glbl -L unisims_ver -s reset_retime_sim *> elaborate_console.log
    if($LASTEXITCODE){throw 'UNISIM reset test elaboration failed'}
    & (Join-Path $bin 'xsim.bat') reset_retime_sim -runall *> simulation_console.log
    if($LASTEXITCODE){throw 'UNISIM reset test simulation failed'}
    if(!(Get-Content -LiteralPath xsim.log -Raw).Contains('PASS_RESET_RETIMING_UNISIM')){throw 'Reset equivalence test did not pass'}
    Get-Content -LiteralPath xsim.log -Tail 12
} finally {Pop-Location}
