#Requires -Version 5.1
<#
.SYNOPSIS
    在桌面上放一个「双击即开」的入口，并把图标放到纯 ASCII 路径。

.DESCRIPTION
    为什么不是 .lnk：
      本机 PowerShell 的 COM 实例化被安全策略禁用，WScript.Shell 建不了快捷方式；
      而手写 .lnk 二进制在含中文的路径下不可靠，且无法在无 GUI 环境验证解析结果。
      所以这里放的是 .vbs 启动器 —— 由 Windows Script Host 直接执行，不需要 COM。

    本脚本只做两件事，且都只"新建"，不改动桌面上任何已有文件：
      1. 把 app\assets\app.ico 复制到 %LOCALAPPDATA%\SafeDriveCleaner\app.ico
         （纯 ASCII 路径 —— 图标路径含中文时，外壳解析不出来，会掉成默认图标）
      2. 把 app\SafeDriveCleaner.vbs 复制到桌面

    想要带箭头的原生 .lnk，可以在桌面上右键该文件 →「创建快捷方式」，
    再在快捷方式属性里把图标指向上面那个 app.ico。

.PARAMETER Name
    桌面入口的文件名（不含扩展名），默认 SafeDriveCleaner。

.PARAMETER Remove
    只删除本脚本创建的那个桌面入口，不动其它任何东西。

.EXAMPLE
    .\New-DesktopEntry.ps1
    创建桌面入口。

.EXAMPLE
    .\New-DesktopEntry.ps1 -Remove
    移除桌面入口。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Name = 'SafeDriveCleaner',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$appDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'app'
$launcher = Join-Path $appDir 'SafeDriveCleaner.vbs'
$iconSrc = Join-Path $appDir 'assets\app.ico'

# 桌面可能被 OneDrive 重定向，不要写死 %USERPROFILE%\Desktop
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) {
    throw '找不到桌面目录。'
}

$entryPath = Join-Path $desktop ($Name + '.vbs')
$iconDir = Join-Path $env:LOCALAPPDATA 'SafeDriveCleaner'
$iconDst = Join-Path $iconDir 'app.ico'

Write-Host ''
Write-Host '=== SafeDriveCleaner 桌面入口 ===' -ForegroundColor Cyan
Write-Host ('桌面目录 : ' + $desktop) -ForegroundColor Gray
Write-Host ('入口文件 : ' + $entryPath) -ForegroundColor Gray
Write-Host ''

if ($Remove) {
    if (Test-Path -LiteralPath $entryPath) {
        # 中文文件名走回收站会失败，直接删；删完必须复核
        [System.IO.File]::Delete($entryPath)
        if (Test-Path -LiteralPath $entryPath) {
            Write-Host '删除后文件仍然存在，请手工处理。' -ForegroundColor Red
            exit 1
        }
        Write-Host ('已移除：' + $entryPath) -ForegroundColor Green
    }
    else {
        Write-Host '桌面上没有本工具创建的入口，无需移除。' -ForegroundColor Yellow
    }
    exit 0
}

foreach ($p in @($launcher, $iconSrc)) {
    if (-not (Test-Path -LiteralPath $p)) { throw ('缺少文件：' + $p) }
}

if ($PSCmdlet.ShouldProcess($entryPath, '创建桌面入口')) {
    # 1) 图标放到纯 ASCII 路径
    if (-not (Test-Path -LiteralPath $iconDir)) {
        New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $iconSrc -Destination $iconDst -Force

    # 2) 启动器放桌面（只新建/覆盖我们自己这一个文件）
    Copy-Item -LiteralPath $launcher -Destination $entryPath -Force
}

# 交付自检：不要只看脚本返回值，要把文件真的列出来
$ok = $true
foreach ($p in @($entryPath, $iconDst)) {
    if (Test-Path -LiteralPath $p) {
        Write-Host ('[OK] ' + $p + '  (' + (Get-Item -LiteralPath $p).Length + ' bytes)') -ForegroundColor Green
    }
    else {
        $ok = $false
        Write-Host ('[MISSING] ' + $p) -ForegroundColor Red
    }
}

if ($ok) {
    Write-Host ''
    Write-Host '桌面上已出现 SafeDriveCleaner，双击即可打开界面。' -ForegroundColor Green
    Write-Host '想要带箭头的原生快捷方式：右键它 →「创建快捷方式」，' -ForegroundColor Gray
    Write-Host ('然后在属性里把图标指向 ' + $iconDst) -ForegroundColor Gray
}
else {
    exit 1
}

Write-Host ''
