@echo off
rem 一键创建桌面入口。把 SafeDriveCleaner 的桌面图标放好。
rem 双击本文件即可。后面想删除可用 `-Remove`。

setlocal
set "HERE=%~dp0"
set "APPDIR=%HERE%app"

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo [错误] 找不到 PowerShell。
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%tools\New-DesktopEntry.ps1" -AppDir "%APPDIR%"
endlocal
exit /b %ERRORLEVEL%