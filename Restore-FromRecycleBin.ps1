#Requires -Version 5.1
<#
.SYNOPSIS
    按清理报告把内容从回收站批量还原。

.DESCRIPTION
    这是 src/Restore.ps1 的命令行入口薄封装。
    读取 Clean-DDrive.ps1 生成的 JSON 报告，找出其中「已移入回收站」的条目，
    再通过 Windows Shell 的回收站还原动作逐个还原。

.PARAMETER ReportPath
    清理模式生成的 JSON 报告路径（reports\safedrivecleaner-*.json）。

.PARAMETER DryRun
    只列出将要还原的条目，不实际执行。

.EXAMPLE
    .\Restore-FromRecycleBin.ps1 -ReportPath .\reports\safedrivecleaner-20260926-220000.json -DryRun
    先看看会还原什么。

.EXAMPLE
    .\Restore-FromRecycleBin.ps1 -ReportPath .\reports\safedrivecleaner-20260926-220000.json
    执行还原。

.NOTES
    自动还原依赖 Windows 本地化的「还原」动词，存在语言环境差异。
    任何一条还原失败都不影响其它条目；如遇失败，请直接打开资源管理器「回收站」
    按文件名手动还原 —— 报告里记录了每一条的完整原始路径。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$ReportPath,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$srcDir = Join-Path $PSScriptRoot 'src'
foreach ($f in @('Common.ps1', 'Restore.ps1')) {
    . (Join-Path $srcDir $f)
}

$resolved = Get-NormalizedPath $ReportPath
if (-not (Test-Path -LiteralPath $resolved)) {
    Write-Host ''
    Write-Host ('找不到报告文件: ' + $ReportPath) -ForegroundColor Red
    Write-Host '请传入清理模式生成的 reports\safedrivecleaner-*.json' -ForegroundColor Gray
    Write-Host ''
    exit 1
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' SafeDriveCleaner · 从回收站还原' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

$logPath = Join-Path (Split-Path -Parent $resolved) ('restore-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
Set-CleanerLogFile -Path $logPath
Write-CLog ('报告文件 : ' + $resolved) 'INFO'
Write-CLog ('日志文件 : ' + $logPath) 'INFO'
if ($DryRun) { Write-CLog 'DryRun：只列不还原' 'WARN' }
Write-Host ''

try {
    Restore-CleanerFromReport -ReportPath $resolved -DryRun:$DryRun
    Close-CleanerLogFile
}
catch {
    Write-CLog ('还原失败：' + $_.Exception.Message) 'ERROR'
    Close-CleanerLogFile
    exit 1
}

Write-Host ''
