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
if ($script:Err -eq 0) {
    Write-Host ('静态检查通过：' + $psFiles.Count + ' 个 ps1 + ' + $jsonFiles.Count + ' 个 json') -ForegroundColor Green
    exit 0
}
Write-Host ('静态检查失败：' + $script:Err + ' 处问题') -ForegroundColor Red
exit 1
