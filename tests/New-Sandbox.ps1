#Requires -Version 5.1
<#
.SYNOPSIS
    构建一个模拟"D 盘"的沙箱目录树，用于安全测试。
    沙箱内镜像真实的缓存布局，同时包含若干"必须被保护"的诱饵目录。
#>
[CmdletBinding()]
param(
    [string]$SandboxPath
)

$ErrorActionPreference = 'Stop'

if (-not $SandboxPath) { $SandboxPath = Join-Path $PSScriptRoot '.sandbox' }
$outsidePath = Join-Path $PSScriptRoot '.outside-target'
$linkedPath  = Join-Path $PSScriptRoot '.linked-target'

function New-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    return $Path
}

function New-File {
    param([string]$Path, [string]$Content = 'x')
    $d = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
    return $Path
}

function New-BigFile {
    param([string]$Path, [int]$KB = 16)
    $d = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $bytes = New-Object byte[] ($KB * 1024)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
    return $Path
}

# --- 干净重建 ---------------------------------------------------------------
$root = New-Dir $SandboxPath

# 1) 系统临时目录（规则 sys-temp-drive 应命中）
New-BigFile (Join-Path $root 'Temp\junk1.tmp') 32 | Out-Null
New-BigFile (Join-Path $root 'Temp\junk2.tmp') 16 | Out-Null
New-BigFile (Join-Path $root 'Windows\Temp\sysjunk.tmp') 24 | Out-Null

# 2) 包管理器缓存（pkg-node 应命中）
New-BigFile (Join-Path $root 'cache\npm-cache\_cacache\blob1') 64 | Out-Null
New-BigFile (Join-Path $root 'Users\tester\AppData\Roaming\npm-cache\_cacache\blob2') 48 | Out-Null
New-BigFile (Join-Path $root 'Users\tester\AppData\Local\pnpm-store\v3\blob3') 40 | Out-Null

# 3) 浏览器缓存（browser-chromium 应命中）
New-BigFile (Join-Path $root 'Users\tester\AppData\Local\Google\Chrome\User Data\Default\Cache\data_0') 80 | Out-Null
New-BigFile (Join-Path $root 'Users\tester\AppData\Local\Google\Chrome\User Data\Default\Cache\data_1') 56 | Out-Null
New-BigFile (Join-Path $root 'Users\tester\AppData\Local\Microsoft\Edge\User Data\Default\Cache\data_0') 40 | Out-Null
# 诱饵：Chrome 的用户数据必须保留
New-File (Join-Path $root 'Users\tester\AppData\Local\Google\Chrome\User Data\Default\Bookmarks') '{"bookmarks":[]}' | Out-Null
New-File (Join-Path $root 'Users\tester\AppData\Local\Google\Chrome\User Data\Default\Login Data') 'secret' | Out-Null
New-File (Join-Path $root 'Users\tester\AppData\Local\Google\Chrome\User Data\Default\History') 'history' | Out-Null

# 4) IDE 缓存（ide-jetbrains 应命中）
New-BigFile (Join-Path $root 'Users\tester\AppData\Roaming\JetBrains\IntelliJIdea2024.1\caches\index.dat') 72 | Out-Null
New-BigFile (Join-Path $root 'Users\tester\AppData\Roaming\JetBrains\IntelliJIdea2024.1\log\idea.log') 12 | Out-Null
New-BigFile (Join-Path $root 'Tools\Code\CachedData\pkg.bin') 36 | Out-Null

# 5) 缩略图缓存（sys-thumbnail-cache 应命中，file 类型）
New-BigFile (Join-Path $root 'Pictures-Thumbs\Thumbs.db') 8 | Out-Null
New-BigFile (Join-Path $root 'Users\tester\AppData\Local\ehthumbs.db') 4 | Out-Null

# 6) 崩溃转储（sys-crashdumps 应命中）
New-BigFile (Join-Path $root 'CrashDumps\app.exe.1234.dmp') 20 | Out-Null

# --- 诱饵：绝对不能被删除 ---------------------------------------------------
# 用户数据
New-File (Join-Path $root 'Users\tester\Documents\important.docx') 'doc' | Out-Null
New-File (Join-Path $root 'Users\tester\Desktop\todo.txt') 'todo' | Out-Null
New-File (Join-Path $root 'Users\tester\Downloads\installer.exe') 'exe' | Out-Null
# 代码仓库与依赖
New-File (Join-Path $root 'Users\tester\Documents\myrepo\.git\config') 'git' | Out-Null
New-File (Join-Path $root 'projects\myapp\package.json') '{}' | Out-Null
New-BigFile (Join-Path $root 'projects\myapp\node_modules\lodash\index.js') 24 | Out-Null
# 数据库与虚拟机镜像
New-BigFile (Join-Path $root 'data\app.sqlite') 48 | Out-Null
New-BigFile (Join-Path $root 'VMs\win11.vhdx') 128 | Out-Null
# 与规则无关的普通目录
New-BigFile (Join-Path $root 'KeepMe\keep.bin') 96 | Out-Null

# --- 年龄测试：一个"新鲜"的 npm-cache，未达 7 天阈值，应被跳过 ---------------
New-BigFile (Join-Path $root 'fresh\npm-cache\_cacache\newblob') 32 | Out-Null

# --- 重解析点：junction 指向沙箱外，规则命中但必须被 P_LINK 拦下 -------------
$outside = New-Dir $outsidePath
New-BigFile (Join-Path $outside 'precious-data.bin') 200 | Out-Null
New-BigFile (Join-Path $outside 'npm-cache\_cacache\outside-blob') 100 | Out-Null

$linkedTarget = New-Dir $linkedPath
New-BigFile (Join-Path $linkedTarget 'npm-cache\_cacache\linked-blob') 120 | Out-Null

# 注意：这两个 junction 会被遍历剪枝 / 保护裁决拦下，删除它们自身时
#      绝不能跟随链接，否则会删掉沙箱外目录里的内容。
foreach ($j in @(
        @{ Path = (Join-Path $root 'npm-cache'); Target = (Join-Path $outside 'npm-cache') },
        @{ Path = (Join-Path $root 'linked'); Target = $linkedTarget }
    )) {
    if (Test-Path -LiteralPath $j.Path) {
        [System.IO.Directory]::Delete($j.Path, $false)
    }
    New-Item -ItemType Junction -Path $j.Path -Target $j.Target -ErrorAction Stop | Out-Null
}

# --- 统一把时间戳改老（细则：先文件后目录，目录按深度倒序） ------------------
$old = (Get-Date).AddDays(-45)
Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike ($outsidePath + '*') } |
    ForEach-Object { try { $_.LastWriteTime = $old; $_.CreationTime = $old } catch { } }

$allDirs = Get-ChildItem -LiteralPath $root -Recurse -Force -Directory -ErrorAction SilentlyContinue |
    Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
    Sort-Object { $_.FullName.Split('\').Count } -Descending
foreach ($d in $allDirs) {
    try { $d.LastWriteTime = $old; $d.CreationTime = $old } catch { }
}
try {
    $di = [System.IO.DirectoryInfo]::new($root)
    $di.LastWriteTime = $old
    $di.CreationTime = $old
}
catch { }

# fresh 目录保持"刚刚修改"，用于验证年龄阈值
$freshDir = Join-Path $root 'fresh\npm-cache'
if (Test-Path -LiteralPath $freshDir) {
    $now = Get-Date
    Get-ChildItem -LiteralPath $freshDir -Recurse -Force | ForEach-Object { try { $_.LastWriteTime = $now; $_.CreationTime = $now } catch { } }
    $dinfo = [System.IO.DirectoryInfo]::new($freshDir)
    $dinfo.LastWriteTime = $now
    $dinfo.CreationTime = $now
}

Write-Host ''
Write-Host "沙箱已构建: $root" -ForegroundColor Green

# --- 输出一份期望清单，供测试断言使用 --------------------------------------
$expectFile = Join-Path $PSScriptRoot 'sandbox-expectations.json'
$expect = [ordered]@{
    sandbox        = $root
    outsideTarget  = $outsidePath
    linkedTarget   = $linkedPath

    mustBeCandidates = @(
        (Join-Path $root 'Temp'),
        (Join-Path $root 'Windows\Temp'),
        (Join-Path $root 'cache\npm-cache'),
        (Join-Path $root 'Users\tester\AppData\Roaming\npm-cache'),
        (Join-Path $root 'Users\tester\AppData\Local\pnpm-store'),
        (Join-Path $root 'Users\tester\AppData\Local\Google\Chrome\User Data\Default\Cache'),
        (Join-Path $root 'Users\tester\AppData\Local\Microsoft\Edge\User Data\Default\Cache'),
        (Join-Path $root 'Users\tester\AppData\Roaming\JetBrains\IntelliJIdea2024.1\caches'),
        (Join-Path $root 'Users\tester\AppData\Roaming\JetBrains\IntelliJIdea2024.1\log'),
        (Join-Path $root 'Tools\Code\CachedData'),
        (Join-Path $root 'Pictures-Thumbs\Thumbs.db'),
        (Join-Path $root 'Users\tester\AppData\Local\ehthumbs.db'),
        (Join-Path $root 'CrashDumps')
    )

    mustBeProtected = @(
        (Join-Path $root 'Users\tester\Documents\important.docx'),
        (Join-Path $root 'Users\tester\Documents\myrepo\.git\config'),
        (Join-Path $root 'Users\tester\Desktop\todo.txt'),
        (Join-Path $root 'Users\tester\Downloads\installer.exe'),
        (Join-Path $root 'projects\myapp\node_modules\lodash\index.js'),
        (Join-Path $root 'projects\myapp\package.json'),
        (Join-Path $root 'data\app.sqlite'),
        (Join-Path $root 'VMs\win11.vhdx'),
        (Join-Path $root 'KeepMe\keep.bin'),
        (Join-Path $root 'Users\tester\AppData\Local\Google\Chrome\User Data\Default\Bookmarks'),
        (Join-Path $root 'Users\tester\AppData\Local\Google\Chrome\User Data\Default\Login Data'),
        (Join-Path $root 'Users\tester\AppData\Local\Google\Chrome\User Data\Default\History')
    )

    mustBeBlockedByLink = @(
        (Join-Path $root 'npm-cache'),
        (Join-Path $root 'linked')
    )

    mustBeSkippedAsTooNew = @(
        $freshDir
    )

    outsidePrecious = @(
        (Join-Path $outsidePath 'precious-data.bin'),
        (Join-Path $outsidePath 'npm-cache\_cacache\outside-blob'),
        (Join-Path $linkedTarget 'npm-cache\_cacache\linked-blob')
    )
}

$expect | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $expectFile -Encoding UTF8
Write-Host "期望清单: $expectFile" -ForegroundColor Green
Write-Host ''
