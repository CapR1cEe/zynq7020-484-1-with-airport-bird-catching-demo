@echo off
setlocal
cd /d "%~dp0"
set "TINYYOLO_UI_PYTHON=python"
if exist "C:\Python314\python.exe" set "TINYYOLO_UI_PYTHON=C:\Python314\python.exe"
"%TINYYOLO_UI_PYTHON%" -X utf8 bird_preview.py %*
if errorlevel 1 (
    echo.
    echo Preview could not start. Check Python, requirements.txt and the serial port.
    pause
)
endlocal
