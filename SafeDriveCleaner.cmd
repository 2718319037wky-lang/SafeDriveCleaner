@echo off
rem SafeDriveCleaner 启动器（zip 根目录版）
rem 双击本文件即可：默认扫 D 盘、自动扫描。
rem 等价于 app\SafeDriveCleaner.cmd，但放在 zip 根目录方便用户直接看到。

setlocal
set "HERE=%~dp0"

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo [错误] 找不到 PowerShell。
    echo SafeDriveCleaner 需要 Windows PowerShell 5.1（Win10/11 自带）。
    pause
    exit /b 1
)

set "DRIVE=D"
if not "%~1"=="" (
    set "CH=%~1"
    call :parse_drive
)

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%HERE%app\SafeDriveCleaner.App.ps1" -Drive %DRIVE% -AutoScan
endlocal
exit /b 0

:parse_drive
for %%C in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if /i "%CH%"=="%%C" set "DRIVE=%CH%"
exit /b 0