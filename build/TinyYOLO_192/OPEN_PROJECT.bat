@echo off
setlocal
set XILINX_LOCAL_USER_DATA=no
set "TY_VIVADO=C:\AMDDesigntools\2025.2\Vivado\bin\vivado.bat"
if defined VIVADO_BAT set "TY_VIVADO=%VIVADO_BAT%"
if not exist "%TY_VIVADO%" (
  echo Set VIVADO_BAT to your Vivado 2025.2 vivado.bat path, or open vivado\TinyYOLO_192.xpr in Vivado.
  pause
  exit /b 1
)
call "%TY_VIVADO%" -mode gui "%~dp0vivado\TinyYOLO_192.xpr"
