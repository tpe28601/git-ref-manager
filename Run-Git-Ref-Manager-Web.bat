@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Git-Ref-Manager-Web.ps1" -OpenBrowser
endlocal
