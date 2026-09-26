@echo off
rem SafeDriveCleaner launcher fallback for machines where .vbs is not associated.
rem Prefer SafeDriveCleaner.vbs -- this one briefly flashes a console window.
setlocal
set "HERE=%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%HERE%SafeDriveCleaner.App.ps1" %1
endlocal
