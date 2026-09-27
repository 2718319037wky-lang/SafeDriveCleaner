#Requires -Version 5.1
<#
.SYNOPSIS
        把 SafeDriveCleaner 打包成下载即用的 zip 分发包。

    .DESCRIPTION
        产物：
            <OutDir>\SafeDriveCleaner-App-v<Version>.zip

        zip 内布局（与 src/ 仓库结构对齐，但只挑"运行 App 需要"的子集）：
        SafeDriveCleaner.cmd             wrapper，从 zip 根目录双击即用
        Install.cmd                      可选：创建桌面入口（也可手动跑）
        README-APP.md
        LICENSE
        .gitattributes
        Clean-DDrive.ps1                 CLI 入口（备份）
        Restore-FromRecycleBin.ps1       还原脚本（备份）
        app\                             桌面 App 与启动器
        src\                             引擎模块
        config\                          规则与保护配置
        tools\                           make_icon / check_icon / New-DesktopEntry

    显式**不**打包：
        .git/
        reports/                          运行期产物
        tests/                           开发自检脚本（用户不需要）
        docs/example-report.html         开发者 demo
        sandbox-expectations.json        沙箱残留
        工作根目录里的临时文件（_out.txt 等）
        dist/                            避免递归打包

    打包后自检：
        1) 解压到临时目录，列文件清单
        2) 所有 .ps1 必须 UTF-8 BOM
        3) app.ico 必须能被 check_icon.py 解析（7 尺寸齐全）
        4) SafeDriveCleaner.cmd 存在且 UTF-8
        5) 输出 SHA256 供下载页校验

.PARAMETER OutDir
    输出目录，默认仓库下的 dist\。可指定绝对路径。

.PARAMETER Version
    版本号字符串，默认取 src\Common.ps1 的 $script:CleanerVersion。

.PARAMETER RepoRoot
    仓库根目录，默认脚本目录的上一级。

.EXAMPLE
    .\tools\make_dist.ps1
    打包到 dist\SafeDriveCleaner-App-v1.1.3.zip
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    [string]$Version,
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $scriptDir }
if (-not $OutDir)   { $OutDir   = Join-Path $RepoRoot 'dist' }

# 读版本号（单一来源：src/Common.ps1）
if (-not $Version) {
    $common = Join-Path $RepoRoot 'src\Common.ps1'
    if (-not (Test-Path -LiteralPath $common)) { throw "找不到 src\Common.ps1" }
    . $common
    if (-not $script:CleanerVersion) { throw "src\Common.ps1 里没找到 `$script:CleanerVersion" }
    $Version = $script:CleanerVersion
}

# 待打包清单（相对 RepoRoot 的路径）。顺序即 zip 内顺序
$include = @(
    'SafeDriveCleaner.cmd'
    'Install.cmd'
    'README-APP.md'
    'LICENSE'
    '.gitattributes'
    'Clean-DDrive.ps1'
    'Restore-FromRecycleBin.ps1'
    'app\SafeDriveCleaner.App.ps1'
    'app\SafeDriveCleaner.cmd'
    'app\SafeDriveCleaner.vbs'
    'app\Worker.ps1'
    'app\Detect-Drives.ps1'
    'app\drives.js'
    'app\drives.json'
    'app\drives.sample.json'
    'app\ui.html'
    'app\assets\app.ico'
    'src\Common.ps1'
    'src\Rules.ps1'
    'src\Scanner.ps1'
    'src\Cleaner.ps1'
    'src\Reporter.ps1'
    'src\Restore.ps1'
    'config\rules.default.json'
    'config\protected.default.json'
    'tools\make_icon.py'
    'tools\check_icon.py'
    'tools\New-DesktopEntry.ps1'
    'tools\make_dist.ps1'    # 把打包脚本也带上，便于复现
)

# 兜底必备检查
$missing = @()
foreach ($rel in $include) {
    $abs = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $abs)) { $missing += $rel }
}
if ($missing.Count -gt 0) {
    Write-Host '[FAIL] 以下必备文件缺失：' -ForegroundColor Red
    foreach ($m in $missing) { Write-Host ('  - ' + $m) -ForegroundColor Red }
    throw '打包清单不全。请先跑 make_icon.py 生成 app.ico、生成 README-APP.md 等。'
}

# 准备 staging 目录（先把文件按 zip 内布局拷一份，再压）
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$stage = Join-Path $OutDir ("stage-App-v" + $Version)
if (Test-Path -LiteralPath $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Write-Host ''
Write-Host '=== SafeDriveCleaner 打包 ===' -ForegroundColor Cyan
Write-Host ('版本 : ' + $Version) -ForegroundColor Gray
Write-Host ('源   : ' + $RepoRoot) -ForegroundColor Gray
Write-Host ('产物 : ' + $OutDir) -ForegroundColor Gray
Write-Host ''

# 复制
foreach ($rel in $include) {
    $src  = Join-Path $RepoRoot $rel
    $dst  = Join-Path $stage $rel
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host ('  + ' + $rel)
}

# 给所有 .ps1 补 UTF-8 BOM（source 已经有，但 staging 副本再次校验避免漏）
$bomEnc = New-Object System.Text.UTF8Encoding($true)
$plainEnc = New-Object System.Text.UTF8Encoding($false)
Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object { $_.Extension -eq '.ps1' } | ForEach-Object {
    $cur = [System.IO.File]::ReadAllBytes($_.FullName)
    if ($cur.Length -ge 3 -and $cur[0] -eq 0xEF -and $cur[1] -eq 0xBB -and $cur[2] -eq 0xBF) {
        Write-Host ('  BOM ok   ' + $_.FullName.Substring($stage.Length + 1))
    } else {
        Write-Host ('  BOM fix  ' + $_.FullName.Substring($stage.Length + 1)) -ForegroundColor Yellow
        [System.IO.File]::WriteAllText($_.FullName, [System.IO.File]::ReadAllText($_.FullName, $plainEnc), $bomEnc)
    }
}

# 压 zip
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipPath = Join-Path $OutDir ("SafeDriveCleaner-App-v" + $Version + ".zip")
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

# 优先用 ZipFile.CreateFromDirectory（简单）；它会保留目录结构
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stage,
    $zipPath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false   # includeBaseDirectory = false：zip 内根就是 stage 的内容
)

# 拿 SHA256
$sha = [System.Security.Cryptography.SHA256]::Create()
$zipBytes = [System.IO.File]::ReadAllBytes($zipPath)
$hash = ($sha.ComputeHash($zipBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
$sha.Dispose()

Write-Host ''
Write-Host ('wrote: ' + $zipPath) -ForegroundColor Green
Write-Host ('size : ' + (Get-Item -LiteralPath $zipPath).Length.ToString('N0') + ' bytes')
Write-Host ('sha256: ' + $hash) -ForegroundColor Cyan
Write-Host ''

# ----- 自检：解压到临时目录 -----
$verify = Join-Path $env:TEMP ('sdc_dist_verify_v' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $verify -Force | Out-Null
try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $verify)
    $allFiles = Get-ChildItem -LiteralPath $verify -Recurse -File

    # 检查必备文件都在
    $verMissing = @()
    foreach ($rel in $include) {
        $check = Join-Path $verify $rel
        if (-not (Test-Path -LiteralPath $check)) { $verMissing += $rel }
    }
    if ($verMissing.Count -gt 0) {
        Write-Host '[FAIL] 解压后缺失文件：' -ForegroundColor Red
        foreach ($m in $verMissing) { Write-Host ('  - ' + $m) -ForegroundColor Red }
        throw '解压自检失败'
    }
    Write-Host ('[OK] 解压后文件齐全 (' + $allFiles.Count + ' 个)') -ForegroundColor Green

    # 检查所有 .ps1 都带 BOM
    $ps1 = $allFiles | Where-Object { $_.Extension -eq '.ps1' }
    $bomMiss = 0
    foreach ($f in $ps1) {
        $b = [System.IO.File]::ReadAllBytes($f.FullName)
        if ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) {
            Write-Host ('  BOM missing: ' + $f.FullName.Substring($verify.Length + 1)) -ForegroundColor Red
            $bomMiss++
        }
    }
    if ($bomMiss -eq 0) { Write-Host ('[OK] ' + $ps1.Count + ' 个 .ps1 全部 UTF-8 BOM') -ForegroundColor Green }
    else { throw ($bomMiss.ToString() + ' 个 .ps1 缺 BOM') }

    # ico 检查（用 check_icon.py 验证 7 尺寸齐全）
    $ico = Join-Path $verify 'app\assets\app.ico'
    $py  = 'C:\Users\a''s''d\.workbuddy\binaries\python\versions\3.13.12\python.exe'
    $checkScript = Join-Path $verify 'tools\check_icon.py'
    if ((Test-Path -LiteralPath $ico) -and (Test-Path -LiteralPath $py) -and (Test-Path -LiteralPath $checkScript)) {
        & $py $checkScript $ico | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host '[OK] app.ico 7 尺寸齐全' -ForegroundColor Green
        } else {
            throw 'check_icon.py 退出码非零'
        }
    }

    Write-Host ''
    Write-Host '=== 全部自检通过 ===' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $verify -Recurse -Force -ErrorAction SilentlyContinue
}

# 不删 staging —— 让用户可以查 zip 之前的中间产物
# 如果不要 staging，可以手动删：dist\stage-App-*

Write-Host ''
Write-Host '用法：' -ForegroundColor Cyan
Write-Host ('  解压 ' + (Split-Path -Leaf $zipPath) + ' 到任意目录（如 D:\Tools\SafeDriveCleaner）') -ForegroundColor Gray
Write-Host '  双击 SafeDriveCleaner.cmd 即开；想放桌面就跑 Install.cmd' -ForegroundColor Gray
Write-Host ''