@echo off
setlocal

set "SCRIPT=%~dp0RTL8125D-LowLatency-Tuner.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: "%SCRIPT%" was not found.
    echo.
    echo Keep these two files in the same folder:
    echo   RTL8125D-LowLatency-Tuner.ps1
    echo   Start-RTL8125D-Tuner.cmd
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%"

if errorlevel 1 (
    echo.
    echo The tuner could not be started.
    echo Log file: %TEMP%\RTL8125D-LowLatency-Tuner.log
    echo.
    pause
)

endlocal
