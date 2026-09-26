# ============================================================================
#  Restore.ps1 - 从回收站按报告还原
#  SafeDriveCleaner
#  说明：本文件只做"尽力而为"的批量还原，依赖 Windows Shell 的回收站还原动作。
#        任何一项失败都不影响其它项；失败时请手动打开回收站按名称还原。
# ============================================================================
#Requires -Version 5.1

<#
.SYNOPSIS
    枚举当前用户回收站中的条目，返回 名称 -> 原始位置 的映射。
#>
function Get-RecycleBinEntryMap {
    [CmdletBinding()]
    param()

    $list = New-Object System.Collections.Generic.List[object]
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.Namespace(10)     # ssfBITBUCKET = 10
        if (-not $bin) { return , $list }
        foreach ($item in $bin.Items()) {
            $from = $null
            try { $from = $item.ExtendedProperty('System.Recycle.DeletedFrom') } catch { $from = $null }
            $list.Add([pscustomobject]@{
                    Item          = $item
                    Name          = $item.Name
                    DeletedFrom   = $from
                    FullPathGuess = if ($from) { $from.TrimEnd('\') + '\' + $item.Name } else { $null }
                })
        }
    }
    catch {
        Write-CLog ('读取回收站失败：' + $_.Exception.Message) 'WARN'
    }
    return ,(ConvertTo-CleanerArray $list)
}

<#
.SYNOPSIS
    对单个回收站条目执行"还原"动词。
#>
function Restore-RecycleBinEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry)

    try {
        $verbs = $Entry.Item.Verbs()
        $target = $null
        foreach ($v in $verbs) {
            if ($v.Name -match '还原|复原|Restore|復原|復元') { $target = $v; break }
        }
        if (-not $target) {
            return [pscustomobject]@{ Success = $false; Error = '未找到"还原"动作（可能是本地化名称异常），请手工在回收站中还原' }
        }
        $target.DoIt()
        return [pscustomobject]@{ Success = $true; Error = $null }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Error = $_.Exception.Message }
    }
}

<#
.SYNOPSIS
    根据本次清理生成的 JSON 报告，批量还原被移入回收站的条目。
#>
function Restore-CleanerFromReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReportPath,
        [switch]$DryRun
    )

    if (-not (Test-Path -LiteralPath $ReportPath)) { throw "报告文件不存在: $ReportPath" }

    $report = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $targets = @()
    foreach ($r in $report.CleanResults) {
        if ($r.Status -eq 'Deleted' -and $r.Type -ne 'recycleBin') { $targets += $r }
    }

    if ($targets.Count -eq 0) {
        Write-CLog '该报告中没有被移入回收站的条目，无需还原。' 'INFO'
        return
    }

    Write-CLog ('报告中共有 ' + $targets.Count + ' 项待还原，正在读取回收站...') 'STEP'
    $entries = Get-RecycleBinEntryMap

    $ok = 0
    $fail = 0
    foreach ($t in $targets) {
        $leaf = Split-Path -Leaf $t.Path
        $parent = Split-Path -Parent $t.Path

        $match = $null
        foreach ($e in $entries) {
            if ($e.Name -ine $leaf) { continue }
            if ($e.DeletedFrom -and ($e.DeletedFrom.TrimEnd('\') -ieq $parent.TrimEnd('\'))) { $match = $e; break }
            if (-not $match) { $match = $e }
        }

        if (-not $match) {
            Write-CLog ('  未在回收站中找到：' + $t.Path) 'WARN'
            $fail++
            continue
        }

        if ($DryRun) {
            Write-CLog ('  [预演] 将还原：' + $t.Path) 'INFO'
            $ok++
            continue
        }

        $res = Restore-RecycleBinEntry -Entry $match
        if ($res.Success) {
            Write-CLog ('  已还原：' + $t.Path) 'OK'
            $ok++
        }
        else {
            Write-CLog ('  还原失败：' + $t.Path + ' → ' + $res.Error) 'WARN'
            $fail++
        }
        # 重新枚举，避免 Shell 缓存过期导致后续匹配错位
        $entries = Get-RecycleBinEntryMap
    }

    Write-CLog ('还原结束：成功 ' + $ok + ' 项，失败 ' + $fail + ' 项') 'STEP'
    if ($fail -gt 0) {
        Write-CLog '失败的条目请手动打开「回收站」按文件名还原。' 'INFO'
    }
}
