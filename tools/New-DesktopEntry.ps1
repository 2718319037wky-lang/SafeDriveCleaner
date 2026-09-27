#Requires -Version 5.1
<#
.SYNOPSIS
    在桌面上放一个「双击即开」的入口（生成 vbs 快捷方式 + 拷图标到 ASCII 路径）。

.DESCRIPTION
    把 app\SafeDriveCleaner.vbs（vbs 模板）里的 {{SDC_APP_DIR}} 占位符替换为
    SafeDriveCleaner.App.ps1 所在的真实绝对路径，再把替换后的 vbs 写到桌面。
    同时把 app\assets\app.ico 复制到 %LOCALAPPDATA%\SafeDriveCleaner\app.ico
    （纯 ASCII 路径 —— 图标路径含中文时，外壳解析不出来，会掉成默认图标）。

    原版曾直接复制 vbs 到桌面，那是 bug：vbs 启动时拿 WScript.ScriptFullName
    等于桌面目录，App.ps1 根本不在那里。这里改成显式注入路径。

    本脚本只做两件事，且都只"新建"，不改动桌面上任何已有文件：
      1. 拷贝 app\assets\app.ico -> %LOCALAPPDATA%\SafeDriveCleaner\app.ico
      2. 拷贝替换 {{APP_DIR}} 后的 SafeDriveCleaner.vbs -> 桌面

    想要带箭头的原生 .lnk，可以在桌面上右键该 vbs →「创建快捷方式」，
    再在快捷方式属性里把图标指向上面那个 app.ico。

.PARAMETER AppDir
    SafeDriveCleaner.App.ps1 所在的目录（通常是 SafeDriveCleaner\app\）。
    必填，避免脚本去猜。

.PARAMETER Name
    桌面入口的文件名（不含扩展名），默认 SafeDriveCleaner。

.PARAMETER Remove
    只删除本脚本创建的那个桌面入口 + 回收图标，不动其它任何东西。

.EXAMPLE
    .\New-DesktopEntry.ps1 -AppDir 'D:\Tools\SafeDriveCleaner\app'
    创建桌面入口。

.EXAMPLE
    .\New-DesktopEntry.ps1 -Remove
    移除桌面入口。

.EXAMPLE
    .\New-DesktopEntry.ps1 -AppDir 'D:\Tools\SafeDriveCleaner\app' -Name '清理D盘'
    创建名为「清理D盘」的桌面入口。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$AppDir,

    [string]$Name = 'SafeDriveCleaner',

    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$template  = Join-Path $repoRoot 'app\SafeDriveCleaner.vbs'
$iconSrc   = Join-Path $repoRoot 'app\assets\app.ico'

# 桌面可能被 OneDrive 重定向，不要写死 %USERPROFILE%\Desktop
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) {
    throw '找不到桌面目录。'
}

$entryPath = Join-Path $desktop ($Name + '.vbs')
$iconDir   = Join-Path $env:LOCALAPPDATA 'SafeDriveCleaner'
$iconDst   = Join-Path $iconDir 'app.ico'

Write-Host ''
Write-Host '=== SafeDriveCleaner 桌面入口 ===' -ForegroundColor Cyan
Write-Host ('桌面目录     : ' + $desktop) -ForegroundColor Gray

if ($Remove) {
    if (Test-Path -LiteralPath $entryPath) {
        [System.IO.File]::Delete($entryPath)
        if (Test-Path -LiteralPath $entryPath) {
            Write-Host '删除后文件仍然存在，请手工处理。' -ForegroundColor Red
            exit 1
        }
        Write-Host ('已移除入口：' + $entryPath) -ForegroundColor Green
    } else {
        Write-Host '桌面上没有本工具创建的入口，无需移除。' -ForegroundColor Yellow
    }
    if (Test-Path -LiteralPath $iconDst) {
        try {
            [System.IO.File]::Delete($iconDst)
            Write-Host ('已移除图标：' + $iconDst) -ForegroundColor Green
        } catch {
            Write-Host ('图标删除失败：' + $iconDst + '（可能其它安装仍在使用，请手工处理）') -ForegroundColor Yellow
        }
    }
    exit 0
}

if (-not $AppDir) {
    # 没传 -AppDir 时默认指向当前仓库内的 app 目录（开发模式）
    $AppDir = Join-Path $repoRoot 'app'
    Write-Host ('未指定 -AppDir，使用默认值（开发模式）：' + $AppDir) -ForegroundColor Yellow
}
$AppDir = (Get-Item -LiteralPath $AppDir).FullName.TrimEnd('\') + '\'

$appScript = Join-Path $AppDir 'SafeDriveCleaner.App.ps1'
foreach ($p in @($template, $iconSrc, $appScript)) {
    if (-not (Test-Path -LiteralPath $p)) { throw ('缺少文件：' + $p) }
}

# 路径含非 ASCII 字符时要警告 —— vbs 不会乱但图标可能会
if ($AppDir -notmatch '^[A-Za-z0-9\\\:\.\-_ ]+$') {
    Write-Host ''
    Write-Host '[WARN] AppDir 路径含非 ASCII 字符：' -ForegroundColor Yellow
    Write-Host ('       ' + $AppDir) -ForegroundColor Yellow
    Write-Host '       PowerShell 路径处理没毛病，但图标关联可能在某些 Windows 上失效。' -ForegroundColor Yellow
    Write-Host '       建议改放到纯英文路径（例如 D:\Tools\SafeDriveCleaner）。' -ForegroundColor Yellow
    Write-Host ''
}

if ($PSCmdlet.ShouldProcess($entryPath, '创建桌面入口')) {
    # 1) 图标放到纯 ASCII 路径
    if (-not (Test-Path -LiteralPath $iconDir)) {
        New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $iconSrc -Destination $iconDst -Force

    # 2) 读 vbs 模板，替换 {{APP_DIR}}，写桌面
    $enc = New-Object System.Text.UTF8Encoding($false)
    $tpl = [System.IO.File]::ReadAllText($template, $enc)
    if (-not $tpl.Contains('{{SDC_APP_DIR}}')) {
        throw 'vbs 模板里没有 {{SDC_APP_DIR}} 占位符 —— 模板可能被改坏了。'
    }
    $rendered = $tpl.Replace('{{SDC_APP_DIR}}', $AppDir)
    [System.IO.File]::WriteAllText($entryPath, $rendered, $enc)
}

# 交付自检
$ok = $true
foreach ($p in @($entryPath, $iconDst)) {
    if (Test-Path -LiteralPath $p) {
        Write-Host ('[OK]   ' + $p + '  (' + (Get-Item -LiteralPath $p).Length + ' bytes)') -ForegroundColor Green
    } else {
        $ok = $false
        Write-Host ('[MISS] ' + $p) -ForegroundColor Red
    }
}
# 验证 vbs 里的路径已正确替换
$check = [System.IO.File]::ReadAllText($entryPath, (New-Object System.Text.UTF8Encoding($false)))
if ($check.Contains('{{SDC_APP_DIR}}')) {
    Write-Host '[FAIL] vbs 里仍含 {{SDC_APP_DIR}} 占位符 —— 替换未生效' -ForegroundColor Red
    $ok = $false
} elseif ($check.Contains($AppDir)) {
    Write-Host ('[OK]   vbs 路径已注入：' + $AppDir) -ForegroundColor Green
}

if ($ok) {
    Write-Host ''
    Write-Host '桌面上已出现 SafeDriveCleaner，双击即可打开界面。' -ForegroundColor Green
    Write-Host '想要带箭头的原生快捷方式：右键它 →「创建快捷方式」，' -ForegroundColor Gray
    Write-Host ('然后在属性里把图标指向 ' + $iconDst) -ForegroundColor Gray
} else {
    exit 1
}

Write-Host ''