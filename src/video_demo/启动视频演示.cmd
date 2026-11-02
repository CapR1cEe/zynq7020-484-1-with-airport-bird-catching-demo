@echo off
setlocal
cd /d "%~dp0"
set "TINYYOLO_DEMO_PYTHON=python"
if exist "C:\Python314\python.exe" set "TINYYOLO_DEMO_PYTHON=C:\Python314\python.exe"
"%TINYYOLO_DEMO_PYTHON%" -X utf8 bird_video_demo.py %*
if errorlevel 1 (
    echo.
    echo Demo could not start. Install Python and the packages in requirements.txt.
    pause
)
endlocal
