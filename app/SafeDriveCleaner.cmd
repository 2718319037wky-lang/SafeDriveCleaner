@echo off
rem SafeDriveCleaner 启动器（cmd fallback）。
rem 优先使用 SafeDriveCleaner.vbs —— 它隐藏窗口；本文件会在「黑框」里短暂显示 PowerShell。
rem
rem 用法：
rem   双击本文件：默认扫 D 盘、自动扫描。
rem   拖放盘符到本图标：传首字母作为 -Drive。

setlocal
set "HERE=%~dp0"

rem 解析盘符（可选）
set "DRIVE=D"
if not "%~1"=="" (
    set "FIRST=%~1"
    call :parse_drive
)

rem 检测 PowerShell 可用性
where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo [错误] 找不到 PowerShell。
    echo SafeDriveCleaner 需要 Windows PowerShell 5.1（Win10/11 自带）。
    pause
    exit /b 1
)

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%HERE%SafeDriveCleaner.App.ps1" -Drive %DRIVE% -AutoScan
endlocal
exit /b 0

:parse_drive
set "CH=%FIRST:~0,1%"
for %%C in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if /i "%CH%"=="%%C" set "DRIVE=%CH%"
exit /b 0