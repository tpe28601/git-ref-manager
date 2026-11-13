@echo off
setlocal
chcp 65001 >nul
set "TB_ACTIVE_TOOL="
for /f "delims=" %%I in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Standalone-Update.ps1" -Action Resolve') do set "TB_ACTIVE_TOOL=%%I"
if defined TB_ACTIVE_TOOL (
    call "%TB_ACTIVE_TOOL%\Run-Git-Ref-Manager.bat" %*
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Git-Ref-Manager.ps1"
endlocal
