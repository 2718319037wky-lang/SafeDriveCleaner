#Requires -Version 5.1
<#
.SYNOPSIS
    静态检查：解析所有 .ps1 的语法、校验所有 .json 的合法性。
    不执行任何清理逻辑，可安全地在 CI 中运行。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$script:Err = 0

Write-Host ''
Write-Host '=== PowerShell 语法检查 ===' -ForegroundColor Cyan

# 注意：-Include 与 -LiteralPath 一起使用时会被忽略（实测返回全部文件），必须用 -Path
# 同时排除运行期产物（沙箱、报告、期望清单）。它们都在 .gitignore 里，
# 静态检查不应依赖本地生成物，否则一份残留的旧产物就能让 CI 红掉。
function Test-IsGeneratedArtifact {
    param([string]$FullName)
    return ($FullName -like '*\.sandbox\*' -or
        $FullName -like '*\.reports\*' -or
        $FullName -like '*\sandbox-expectations.json')
}

$psFiles = @(Get-ChildItem -Path $root -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-IsGeneratedArtifact $_.FullName) })

foreach ($f in $psFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $script:Err++
        Write-Host ('  [FAIL] ' + $f.Name) -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host ('         L' + $e.Extent.StartLineNumber + ': ' + $e.Message) -ForegroundColor Red
        }
    }
    else {
        Write-Host ('  [ OK ] ' + $f.FullName.Substring($root.Length).TrimStart('\')) -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '=== UTF-8 BOM 校验 ===' -ForegroundColor Cyan
Write-Host '  说明：Windows PowerShell 5.1 读取无 BOM 的 UTF-8 脚本时会按 ANSI 解码，' -ForegroundColor DarkGray
Write-Host '        中文会变成乱码并引发语法错误。所有 .ps1 必须带 UTF-8 BOM。' -ForegroundColor DarkGray

foreach ($f in $psFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hasBom) {
        Write-Host ('  [ OK ] ' + $f.FullName.Substring($root.Length).TrimStart('\')) -ForegroundColor Green
    }
    else {
        $script:Err++
        Write-Host ('  [FAIL] ' + $f.Name + ' 缺少 UTF-8 BOM（PS 5.1 下中文会乱码）') -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '=== JSON 校验 ===' -ForegroundColor Cyan

$jsonFiles = @(Get-ChildItem -Path $root -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-IsGeneratedArtifact $_.FullName) })

foreach ($f in $jsonFiles) {
    try {
        $null = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        Write-Host ('  [ OK ] ' + $f.FullName.Substring($root.Length).TrimStart('\')) -ForegroundColor Green
    }
    catch {
        $script:Err++
        Write-Host ('  [FAIL] ' + $f.Name + ' -> ' + $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '=== 版本号单一来源检查 ===' -ForegroundColor Cyan
Write-Host '  说明：版本字面量只允许出现一次，且必须在 src\Common.ps1 里。' -ForegroundColor DarkGray
Write-Host '        CLI 与桌面版各写一份曾导致 CLI 停在 1.0.1、桌面版已是 1.1.0。' -ForegroundColor DarkGray

# 匹配「把版本号字面量赋给某个 *version* 变量」这一类写法（不含 $X = $script:CleanerVersion）
$semverAssign = '\$[A-Za-z_:.]*[Vv]ersion[A-Za-z_]*\s*=\s*''(\d+\.\d+\.\d+)'''
$versionHits = New-Object System.Collections.Generic.List[string]
foreach ($f in $psFiles) {
    $rel = $f.FullName.Substring($root.Length).TrimStart('\')
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)) {
        $lineNo++
        if ($line -match $semverAssign) {
            $versionHits.Add($rel + ':' + $lineNo + ' = ' + $Matches[1])
        }
    }
}

if ($versionHits.Count -eq 1 -and $versionHits[0].StartsWith('src\Common.ps1:')) {
    Write-Host ('  [ OK ] 版本字面量唯一：' + $versionHits[0]) -ForegroundColor Green
}
else {
    $script:Err++
    Write-Host ('  [FAIL] 版本字面量应恰好 1 处且位于 src\Common.ps1，实际 ' + $versionHits.Count + ' 处：') -ForegroundColor Red
    foreach ($h in $versionHits) { Write-Host ('         ' + $h) -ForegroundColor Red }
    if ($versionHits.Count -eq 0) {
        Write-Host '         提示：请确认 src\Common.ps1 里的 $script:CleanerVersion 未被删除或改写成计算式。' -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '=== 内联 JavaScript 语法检查 ===' -ForegroundColor Cyan
Write-Host '  说明：界面原型 app\ui.html 的交互逻辑全部写在内联 <script> 里，页面还用内联' -ForegroundColor DarkGray
Write-Host '        onclick 引用全局函数。语法一旦写错，整页会静默失效（按钮点了没反应），' -ForegroundColor DarkGray
Write-Host '        而 HTML 本身仍能正常打开——所以必须单独解析一次。' -ForegroundColor DarkGray

function Test-RealNode {
    param([string]$Exe)
    try {
        $out = & $Exe --version 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return $false }
        return [bool]($out -match 'v\d+\.\d+')
    }
    catch { return $false }
}

$node = $null
foreach ($cand in @('node', 'nodejs')) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    if (Test-RealNode -Exe $cmd.Source) { $node = $cmd.Source; break }
}

$htmlFiles = @(Get-ChildItem -Path $root -Recurse -File -Filter '*.html' -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-IsGeneratedArtifact $_.FullName) })

if (-not $node) {
    Write-Host '  [SKIP] 未找到可用的 Node.js，跳过内联脚本语法检查' -ForegroundColor DarkGray
}
else {
    foreach ($f in $htmlFiles) {
        $html = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        # 只检查没有 src 属性的内联脚本；带 src 的是外部文件，不属于本检查范围
        $blocks = [regex]::Matches($html, '(?s)<script(?![^>]*\bsrc\s*=)[^>]*>(.*?)</script>')
        $rel = $f.FullName.Substring($root.Length).TrimStart('\')
        if ($blocks.Count -eq 0) {
            Write-Host ('  [ OK ] ' + $rel + '（无内联脚本）') -ForegroundColor Green
            continue
        }
        for ($i = 0; $i -lt $blocks.Count; $i++) {
            $tmp = Join-Path $env:TEMP ('sdc-inline-' + [Guid]::NewGuid().ToString('N') + '.js')
            [System.IO.File]::WriteAllText($tmp, $blocks[$i].Groups[1].Value, (New-Object System.Text.UTF8Encoding($false)))
            $out = & $node --check $tmp 2>&1 | Out-String
            $code = $LASTEXITCODE
            [System.IO.File]::Delete($tmp)
            $label = $rel + ' (内联脚本 #' + ($i + 1) + ')'
            if ($code -eq 0) {
                Write-Host ('  [ OK ] ' + $label) -ForegroundColor Green
            }
            else {
                $script:Err++
                Write-Host ('  [FAIL] ' + $label) -ForegroundColor Red
                foreach ($line in ($out -split "`r?`n")) {
                    if ($line.Trim()) { Write-Host ('         ' + $line.Trim()) -ForegroundColor Red }
                }
            }
        }
    }
}

Write-Host ''
Write-Host '=== 应用图标校验 ===' -ForegroundColor Cyan

$icoPath = Join-Path $root 'app\assets\app.ico'
$iconChecker = Join-Path $root 'tools\check_icon.py'

# 注意：不能只看 Get-Command 能不能找到。
# Windows 上 PATH 里的 python.exe 常常是 Microsoft Store 的占位桩，
# 它存在、可执行，但一跑就打印"Python was not found"并以非 0 退出。
# 必须真的执行一次并校验版本输出，否则会把"没有 Python"误判成"图标校验失败"。
function Test-RealPython {
    param([string]$Exe, [string[]]$Prefix)
    try {
        $out = & $Exe @Prefix --version 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return $false }
        return [bool]($out -match 'Python 3\.')
    }
    catch { return $false }
}

$python = $null
$pythonArgs = @()
foreach ($cand in @(
        @{ Exe = 'python'; Prefix = @() },
        @{ Exe = 'python3'; Prefix = @() },
        @{ Exe = 'py'; Prefix = @('-3') }
    )) {
    $cmd = Get-Command $cand.Exe -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    if (Test-RealPython -Exe $cmd.Source -Prefix $cand.Prefix) {
        $python = $cmd.Source
        $pythonArgs = $cand.Prefix
        break
    }
}

if (-not $python) {
    Write-Host '  [SKIP] 未找到可用的 Python，跳过（该检查只依赖标准库，不影响其它检查）' -ForegroundColor DarkGray
}
elseif (-not (Test-Path -LiteralPath $icoPath)) {
    $script:Err++
    Write-Host '  [FAIL] 缺少 app\assets\app.ico' -ForegroundColor Red
}
elseif (-not (Test-Path -LiteralPath $iconChecker)) {
    Write-Host '  [SKIP] 未找到 tools\check_icon.py' -ForegroundColor DarkGray
}
else {
    $icoOut = & $python @pythonArgs $iconChecker $icoPath 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  [ OK ] app.ico 结构完整、图案存在' -ForegroundColor Green
    }
    else {
        $script:Err++
        Write-Host '  [FAIL] app.ico 校验未通过：' -ForegroundColor Red
        foreach ($line in ($icoOut -split "`r?`n")) {
            if ($line.Trim()) { Write-Host ('         ' + $line.Trim()) -ForegroundColor Red }
        }
    }
}

Write-Host ''
if ($script:Err -eq 0) {
    Write-Host ('静态检查通过：' + $psFiles.Count + ' 个 ps1 + ' + $jsonFiles.Count + ' 个 json + ' + $htmlFiles.Count + ' 个 html') -ForegroundColor Green
    exit 0
}
Write-Host ('静态检查失败：' + $script:Err + ' 处问题') -ForegroundColor Red
exit 1
