#Requires -Version 5.1
# 用 Windows 自带的 IExpress 生成 SafeDriveCleaner.exe 自解压包
# 用法：powershell -File tools\make_exe.ps1

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $repo 'dist'
$sed  = Join-Path $dist 'SafeDriveCleaner.sed'

$iex = Join-Path $env:WINDIR 'System32\iexpress.exe'
if (-not (Test-Path -LiteralPath $iex)) {
    Write-Host '[FAIL] 找不到系统自带的 IExpress（iexpress.exe）' -ForegroundColor Red
    exit 1
}

# IExpress 会在 SED 文件所在目录生成 TargetName 指定的 exe
# 所以先把工作目录切到 dist，再调 iexpress
Push-Location $dist
try {
    Write-Host '=== 生成自解压 exe ===' -ForegroundColor Cyan
    Write-Host ('SED : ' + $sed) -ForegroundColor Gray
    Write-Host ('IExpress : ' + $iex) -ForegroundColor Gray
    Write-Host ''

    # /N = 用 SED 文件（非交互），/Q = 安静
    & $iex /N /Q $sed
    $code = $LASTEXITCODE
    Write-Host ('IExpress 退出码: ' + $code)
}
finally {
    Pop-Location
}

$exe = Join-Path $dist 'SafeDriveCleaner.exe'
if (Test-Path -LiteralPath $exe) {
    $fi = Get-Item -LiteralPath $exe
    Write-Host ''
    Write-Host ('[OK] 生成成功: ' + $exe) -ForegroundColor Green
    Write-Host ('     大小: ' + $fi.Length.ToString('N0') + ' bytes')

    # SHA256
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = ($sha.ComputeHash([System.IO.File]::ReadAllBytes($exe)) | ForEach-Object { $_.ToString('x2') }) -join ''
    $sha.Dispose()
    Write-Host ('     SHA256: ' + $hash) -ForegroundColor Cyan
}
else {
    Write-Host '[FAIL] 未生成 exe，IExpress 可能失败' -ForegroundColor Red
    exit 1
}
