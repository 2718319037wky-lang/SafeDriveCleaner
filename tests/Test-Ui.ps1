#Requires -Version 5.1
<#
.SYNOPSIS
    app\ui.html 的无头验证（jsdom 层）。

.DESCRIPTION
    在 jsdom 里把 ui.html 的内联脚本跑起来，驱动 扫描 / 选择 / 确认弹窗 / 清理 / 还原 /
    规则开关 / 再次扫描，断言 94 项状态机不变量。

    为什么值得单独测：ui.html 没有构建步骤也没有类型检查，语法错能被 Test-Syntax.ps1 挡住，
    但"语法正确、逻辑错"只有真的跑起来才会暴露——本轮就是这样抓到了两处真实缺陷
    （清理后侧栏徽标不刷新、换盘后旧盘候选与徽标残留）。

    依赖 Node.js 与 jsdom（可选依赖）。缺任一个都以 SKIP 退出，不会让其它测试变红。
    启用方式（仓库根目录执行一次）：
        npm install jsdom --no-save

.PARAMETER Trace
    保留完整输出，不做截断。
#>
[CmdletBinding()]
param(
    [switch]$Trace
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$smoke = Join-Path $PSScriptRoot 'ui\smoke.js'
# 报告落在仓库内，与 tests\.transcript.txt 同一约定（已在 .gitignore 里）
$report = Join-Path $PSScriptRoot '.ui-smoke.txt'

Write-Host ''
Write-Host '=== app\ui.html 无头验证（jsdom） ===' -ForegroundColor Cyan

# 与 Python 探测同样的坑：PATH 上可能是个占位桩，必须真的跑一次并校验版本输出
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

if (-not $node) {
    Write-Host '  [SKIP] 未找到可用的 Node.js，跳过（不影响其它测试）' -ForegroundColor DarkGray
    exit 0
}

if (-not (Test-Path -LiteralPath $smoke)) {
    Write-Host '  [FAIL] 缺少 tests\ui\smoke.js' -ForegroundColor Red
    exit 1
}

# jsdom 从 smoke.js 所在目录逐级向上解析，所以要保证工作目录落在仓库内
Push-Location $root
try {
    $probeOut = & $node -e "require.resolve('jsdom')" 2>&1 | Out-String
    $hasJsdom = ($LASTEXITCODE -eq 0)
}
finally { Pop-Location }

if (-not $hasJsdom) {
    Write-Host '  [SKIP] 未找到 jsdom 依赖，跳过。' -ForegroundColor DarkGray
    Write-Host '        启用方式（仓库根目录执行一次）：npm install jsdom --no-save' -ForegroundColor DarkGray
    if ($Trace -and $probeOut.Trim()) { Write-Host ('        探针输出：' + $probeOut.Trim()) -ForegroundColor DarkGray }
    exit 0
}

if (Test-Path -LiteralPath $report) { Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue }

Push-Location $root
try {
    [void](& $node $smoke $report 2>&1 | Out-String)
    $code = $LASTEXITCODE
}
finally { Pop-Location }

# 不让 node 的 stdout 直接进控制台：它是 UTF-8，而 Windows PowerShell 5.1 会按控制台
# 代码页(GBK)解码，中文一律变乱码——报告落盘后按 UTF-8 读，与 Run-Tests.ps1 一致。
if (-not (Test-Path -LiteralPath $report)) {
    Write-Host '  [FAIL] 未生成报告文件，smoke.js 可能在启动阶段就抛异常了' -ForegroundColor Red
    exit 1
}

$body = [System.IO.File]::ReadAllText($report, [System.Text.Encoding]::UTF8)
$summary = ($body -split "`r?`n")[0]   # 形如 "PASS 94 / FAIL 0"，纯 ASCII
Write-Host ('  ' + $summary)

if ($code -ne 0) {
    Write-Host ''
    Write-Host $body -ForegroundColor Red
}
elseif ($Trace) {
    Write-Host $body
}
Write-Host ('  报告：' + $report) -ForegroundColor DarkGray

if ($code -eq 0) {
    Write-Host '  [ OK ] ui.html 状态机断言全部通过' -ForegroundColor Green
    exit 0
}
Write-Host '  [FAIL] ui.html 状态机断言存在失败项' -ForegroundColor Red
exit 1
