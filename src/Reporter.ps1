# ============================================================================
#  Reporter.ps1 - 报告组装与导出（HTML / JSON）
#  SafeDriveCleaner
# ============================================================================
#Requires -Version 5.1

function New-CleanerReportObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Scan,
        $Clean,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][string]$RootPath,
        [int]$MaxDepth,
        [string]$Version
    )

    # 版本号单一来源（src\Common.ps1）。原先这里硬编码 '1.0.0'，
    # 任何不显式传 -Version 的调用都会在报告里写上一个过期版本号。
    if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $script:CleanerVersion }

    $items = @()
    foreach ($c in $Scan.Candidates) {
        $items += [pscustomobject]@{
            RuleId    = $c.RuleId
            RuleName  = $c.RuleName
            Category  = $c.Category
            Risk      = $c.Risk
            Path      = $c.Path
            Type      = $c.Type
            AgeDays   = $c.AgeDays
            MinAge    = $c.MinAge
            Bytes     = [long]$c.Bytes
            Files     = [int]$c.Files
            Dirs      = [int]$c.Dirs
            Note      = $c.Note
            IsSpecial = [bool]$c.IsSpecial
        }
    }

    $protectionHits = @()
    foreach ($s in $Scan.Skipped) {
        if ($s.Code -like 'P_*') { $protectionHits += $s }
    }

    $tooNew = @()
    foreach ($s in $Scan.Skipped) {
        if ($s.Code -eq 'S_TOO_NEW') { $tooNew += $s }
    }

    $categories = @()
    foreach ($g in ($items | Group-Object Category)) {
        $bytes = 0
        foreach ($it in $g.Group) { $bytes += $it.Bytes }
        $risk = ($g.Group | Select-Object -First 1).Risk
        $categories += [pscustomobject]@{
            Name  = $g.Name
            Count = $g.Count
            Bytes = [long]$bytes
            Risk  = $risk
        }
    }
    $categories = $categories | Sort-Object -Property Bytes -Descending

    $totalBytes = 0
    foreach ($it in $items) { $totalBytes += $it.Bytes }

    $cleanSummary = $null
    if ($Clean) {
        $deleted = 0; $failed = 0; $deletedBytes = [long]0; $failedBytes = [long]0
        foreach ($r in $Clean.Results) {
            if ($r.Status -eq 'Deleted' -or $r.Status -eq 'DryRun') {
                $deleted++
                $deletedBytes += $r.Bytes
            }
            else {
                $failed++
                $failedBytes += $r.Bytes
            }
        }
        $cleanSummary = [pscustomobject]@{
            Deleted      = $deleted
            Failed       = $failed
            DeletedBytes = $deletedBytes
            FailedBytes  = $failedBytes
            Method       = $Clean.Method
            DryRun       = $Clean.DryRun
            DurationSec  = $Clean.DurationSec
        }
    }

    $reportKind = 'scan'
    if ($Clean) { $reportKind = 'clean' }

    return [pscustomobject]@{
        Tool             = 'SafeDriveCleaner'
        Version          = $Version
        GeneratedAt      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Machine          = $env:COMPUTERNAME
        Mode             = $Mode
        Drive            = $DriveLetter
        RootPath         = $RootPath
        MaxDepth         = $MaxDepth

        IndexDirs        = $Scan.IndexDirs
        IndexFiles       = $Scan.IndexFiles
        PrunedCount      = $Scan.PrunedCount
        Truncated        = (ConvertTo-CleanerArray $Scan.Truncated)
        ScanDurationSec  = $Scan.DurationSec

        CandidateCount   = $items.Count
        TotalBytes       = $totalBytes
        Categories       = $categories
        Items            = $items

        ProtectionHits   = $protectionHits
        LinkSkips        = $Scan.LinkSkips
        SkippedTooNew    = $tooNew

        CleanSummary     = $cleanSummary
        CleanResults     = if ($Clean) { $Clean.Results } else { @() }
        ReportKind       = $reportKind
    }
}

function ConvertTo-HtmlText {
    [CmdletBinding()]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Export-CleanerJsonReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$Path
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

function Export-CleanerHtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$Path
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $modeLabel = if ($Report.ReportKind -eq 'clean') { '清理模式（Clean）' } else { '扫描模式（Scan / 只读）' }
    $modeColor = if ($Report.ReportKind -eq 'clean') { '#b45309' } else { '#047857' }

    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="zh-CN"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine('<title>SafeDriveCleaner 报告 - ' + (ConvertTo-HtmlText $Report.RootPath) + '</title>')
    [void]$sb.AppendLine(@'
<style>
:root{
  --bg:#f6f7f9; --panel:#ffffff; --panel-2:#fbfbfc; --border:#e3e6ea;
  --text:#1f2328; --muted:#6b7280; --accent:#2563eb;
  --ok:#047857; --warn:#b45309; --danger:#b91c1c; --mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
}
@media (prefers-color-scheme: dark){
  :root{ --bg:#14171a; --panel:#1b1f24; --panel-2:#20252b; --border:#2e343b;
         --text:#e6e9ee; --muted:#9aa3ad; --accent:#6ea8fe;
         --ok:#4ade80; --warn:#fbbf24; --danger:#f87171; }
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei",sans-serif;
  font-size:14px;line-height:1.6}
.wrap{max-width:1180px;margin:0 auto;padding:28px 20px 64px}
header{display:flex;flex-wrap:wrap;align-items:baseline;gap:12px;margin-bottom:6px}
h1{font-size:22px;margin:0;letter-spacing:.2px}
.badge{font-size:12px;padding:3px 10px;border-radius:999px;color:#fff;background:var(--accent)}
.badge.mode{background:#047857}
.meta{color:var(--muted);font-size:12.5px;margin:0 0 22px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(168px,1fr));gap:12px;margin-bottom:26px}
.card{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:14px 16px}
.card .k{font-size:12px;color:var(--muted);margin-bottom:6px}
.card .v{font-size:22px;font-weight:650;letter-spacing:.2px}
.card .v.accent{color:var(--accent)}
.card .v.ok{color:var(--ok)}
.card .v.warn{color:var(--warn)}
section{background:var(--panel);border:1px solid var(--border);border-radius:12px;
  padding:18px 20px;margin-bottom:20px}
h2{font-size:15px;margin:0 0 14px;padding-bottom:10px;border-bottom:1px solid var(--border)}
h2 .sub{font-weight:400;color:var(--muted);font-size:12.5px;margin-left:8px}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--border);vertical-align:top}
th{color:var(--muted);font-weight:600;font-size:12px;white-space:nowrap}
tr:last-child td{border-bottom:none}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.path{font-family:var(--mono);font-size:12px;word-break:break-all}
.risk{font-size:11.5px;padding:1px 7px;border-radius:6px;white-space:nowrap}
.risk.low{background:rgba(4,120,87,.12);color:var(--ok)}
.risk.medium{background:rgba(180,83,9,.14);color:var(--warn)}
.risk.high,.risk.unknown{background:rgba(185,28,28,.14);color:var(--danger)}
.empty{color:var(--muted);font-size:13px;padding:6px 0}
.note{color:var(--muted);font-size:12.5px}
ul.tips{margin:8px 0 0;padding-left:20px;color:var(--muted);font-size:13px}
ul.tips li{margin:4px 0}
code{font-family:var(--mono);background:var(--panel-2);border:1px solid var(--border);
  border-radius:5px;padding:1px 5px;font-size:12px}
details{margin-top:6px}
summary{cursor:pointer;color:var(--accent);font-size:13px}
.bar{height:6px;border-radius:4px;background:var(--accent);min-width:2px;display:inline-block;vertical-align:middle}
footer{color:var(--muted);font-size:12px;text-align:center;margin-top:26px}
</style></head><body><div class="wrap">
'@)

    # ---- header ----
    [void]$sb.AppendLine('<header>')
    [void]$sb.AppendLine('<h1>SafeDriveCleaner 磁盘清理报告</h1>')
    [void]$sb.AppendLine('<span class="badge mode">' + (ConvertTo-HtmlText $modeLabel) + '</span>')
    [void]$sb.AppendLine('<span class="badge">v' + (ConvertTo-HtmlText $Report.Version) + '</span>')
    [void]$sb.AppendLine('</header>')
    [void]$sb.AppendLine('<p class="meta">目标根目录 <code>' + (ConvertTo-HtmlText $Report.RootPath) +
        '</code> · 生成时间 ' + (ConvertTo-HtmlText $Report.GeneratedAt) +
        ' · 主机 ' + (ConvertTo-HtmlText $Report.Machine) +
        ' · 扫描最大深度 ' + (ConvertTo-HtmlText $Report.MaxDepth) +
        ' · 扫描耗时 ' + (ConvertTo-HtmlText $Report.ScanDurationSec) + ' 秒</p>')

    # ---- summary cards ----
    $protectCount = Get-CleanerCount $Report.ProtectionHits
    $linkCount = Get-CleanerCount $Report.LinkSkips
    $truncCount = Get-CleanerCount $Report.Truncated

    [void]$sb.AppendLine('<div class="cards">')
    [void]$sb.AppendLine('<div class="card"><div class="k">可清理总量</div><div class="v accent">' + (ConvertTo-HtmlText (Format-Size $Report.TotalBytes)) + '</div></div>')
    [void]$sb.AppendLine('<div class="card"><div class="k">候选条目</div><div class="v">' + $Report.CandidateCount + '</div></div>')
    [void]$sb.AppendLine('<div class="card"><div class="k">分类数</div><div class="v">' + (Get-CleanerCount $Report.Categories) + '</div></div>')
    [void]$sb.AppendLine('<div class="card"><div class="k">保护规则拦截</div><div class="v ok">' + $protectCount + '</div></div>')
    [void]$sb.AppendLine('<div class="card"><div class="k">链接跳过</div><div class="v ok">' + $linkCount + '</div></div>')
    [void]$sb.AppendLine('<div class="card"><div class="k">索引目录 / 文件</div><div class="v">' + $Report.IndexDirs + ' / ' + $Report.IndexFiles + '</div></div>')

    if ($truncCount -gt 0) {
        [void]$sb.AppendLine('<div class="card"><div class="k">深度截断告警</div><div class="v warn">' + $truncCount + '</div><div class="note">有目录达到最大深度未继续下探，可能漏掉更深的缓存</div></div>')
    }

    if ($Report.CleanSummary) {
        $cs = $Report.CleanSummary
        $label = if ($cs.DryRun) { '预演（未实际删除）' } else { '已清理' }
        [void]$sb.AppendLine('<div class="card"><div class="k">' + $label + '</div><div class="v ok">' + (ConvertTo-HtmlText (Format-Size $cs.DeletedBytes)) + '</div></div>')
        [void]$sb.AppendLine('<div class="card"><div class="k">成功 / 失败</div><div class="v">' + $cs.Deleted + ' / ' + $cs.Failed + '</div></div>')
    }
    [void]$sb.AppendLine('</div>')

    # ---- categories ----
    [void]$sb.AppendLine('<section><h2>分类汇总<span class="sub">按可清理体积降序</span></h2>')
    if ((Get-CleanerCount $Report.Categories) -eq 0) {
        [void]$sb.AppendLine('<p class="empty">没有发现符合白名单规则的候选目标。这通常是好事——说明该盘已经很干净，或者缓存不在本盘。</p>')
    }
    else {
        $maxBytes = 1
        foreach ($c in $Report.Categories) { if ($c.Bytes -gt $maxBytes) { $maxBytes = $c.Bytes } }
        [void]$sb.AppendLine('<table><thead><tr><th>分类</th><th class="num">条目数</th><th class="num">体积</th><th>占比</th><th>风险</th></tr></thead><tbody>')
        foreach ($c in $Report.Categories) {
            $w = [int](160 * $c.Bytes / $maxBytes)
            if ($w -lt 2) { $w = 2 }
            $riskClass = [string]$c.Risk
            if ($riskClass -notin @('low', 'medium', 'high')) { $riskClass = 'unknown' }
            [void]$sb.AppendLine('<tr><td>' + (ConvertTo-HtmlText $c.Name) + '</td>' +
                '<td class="num">' + $c.Count + '</td>' +
                '<td class="num">' + (ConvertTo-HtmlText (Format-Size $c.Bytes)) + '</td>' +
                '<td><span class="bar" style="width:' + $w + 'px"></span></td>' +
                '<td><span class="risk ' + $riskClass + '">' + (ConvertTo-HtmlText $c.Risk) + '</span></td></tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    [void]$sb.AppendLine('</section>')

    # ---- items ----
    $items = $Report.Items | Sort-Object -Property Bytes -Descending
    [void]$sb.AppendLine('<section><h2>清理明细<span class="sub">按体积降序，前 200 条</span></h2>')
    if ((Get-CleanerCount $items) -eq 0) {
        [void]$sb.AppendLine('<p class="empty">无候选条目。</p>')
    }
    else {
        [void]$sb.AppendLine('<table><thead><tr><th>路径</th><th>分类</th><th class="num">体积</th><th class="num">文件数</th><th class="num">未使用天数</th></tr></thead><tbody>')
        $n = 0
        foreach ($it in $items) {
            $n++
            if ($n -gt 200) { break }
            $age = if ($null -eq $it.AgeDays) { '—' } else { [string]$it.AgeDays }
            [void]$sb.AppendLine('<tr><td class="path">' + (ConvertTo-HtmlText $it.Path) + '</td>' +
                '<td>' + (ConvertTo-HtmlText $it.Category) + '</td>' +
                '<td class="num">' + (ConvertTo-HtmlText (Format-Size $it.Bytes)) + '</td>' +
                '<td class="num">' + $it.Files + '</td>' +
                '<td class="num">' + (ConvertTo-HtmlText $age) + '</td></tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
        if ((Get-CleanerCount $items) -gt 200) {
            [void]$sb.AppendLine('<p class="note">仅展示前 200 条，完整明细见同目录下的 JSON 报告。</p>')
        }
    }
    [void]$sb.AppendLine('</section>')

    # ---- clean results ----
    if ($Report.CleanSummary) {
        [void]$sb.AppendLine('<section><h2>执行结果<span class="sub">底层实现 ' + (ConvertTo-HtmlText $Report.CleanSummary.Method) + '</span></h2>')
        [void]$sb.AppendLine('<table><thead><tr><th>路径</th><th>状态</th><th class="num">体积</th><th>说明</th></tr></thead><tbody>')
        $n = 0
        foreach ($r in $Report.CleanResults) {
            $n++
            if ($n -gt 200) { break }
            $err = if ($r.Error) { $r.Error } else { '' }
            [void]$sb.AppendLine('<tr><td class="path">' + (ConvertTo-HtmlText $r.Path) + '</td>' +
                '<td>' + (ConvertTo-HtmlText $r.Status) + '</td>' +
                '<td class="num">' + (ConvertTo-HtmlText (Format-Size $r.Bytes)) + '</td>' +
                '<td class="note">' + (ConvertTo-HtmlText $err) + '</td></tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
        if (-not $Report.CleanSummary.DryRun -and $Report.CleanSummary.Method -ne 'Permanent') {
            [void]$sb.AppendLine('<p class="note">上述条目已移入回收站，可直接在资源管理器「回收站」中还原。也可执行 <code>.\Restore-FromRecycleBin.ps1 -ReportPath &lt;本次JSON报告&gt;</code> 批量还原。</p>')
        }
        [void]$sb.AppendLine('</section>')
    }

    # ---- skipped ----
    $tooNew = @($Report.SkippedTooNew)
    if ($tooNew.Count -gt 0) {
        [void]$sb.AppendLine('<section><h2>因"仍在使用中"而跳过<span class="sub">共 ' + $tooNew.Count + ' 项</span></h2>')
        [void]$sb.AppendLine('<details><summary>展开查看</summary><table><thead><tr><th>路径</th><th>规则</th><th>说明</th></tr></thead><tbody>')
        foreach ($s in $tooNew) {
            [void]$sb.AppendLine('<tr><td class="path">' + (ConvertTo-HtmlText $s.Path) + '</td>' +
                '<td>' + (ConvertTo-HtmlText $s.RuleName) + '</td>' +
                '<td class="note">' + (ConvertTo-HtmlText $s.Reason) + '</td></tr>')
        }
        [void]$sb.AppendLine('</tbody></table></details></section>')
    }

    # ---- protection ----
    [void]$sb.AppendLine('<section><h2>安全防线记录<span class="sub">这些路径被保护规则拦下，永远不会被删除</span></h2>')
    if ($protectCount -eq 0 -and $linkCount -eq 0) {
        [void]$sb.AppendLine('<p class="empty">本次没有任何路径触发保护规则。</p>')
    }
    else {
        [void]$sb.AppendLine('<table><thead><tr><th>路径</th><th>规则</th><th>拦截原因</th></tr></thead><tbody>')
        $seen = New-Object System.Collections.Generic.HashSet[string]
        $safetyRows = New-Object System.Collections.ArrayList
        # 分开遍历两个集合，不要写 @($a) + @($b) —— LinkSkips 是 List[object]，
        # 对它用 @() 在 PS 5.1 上会抛异常（见 Get-CleanerCount 的说明）。
        foreach ($s in $Report.ProtectionHits) {
            if ($seen.Add([string]$s.Path + '|' + [string]$s.Reason)) { [void]$safetyRows.Add($s) }
        }
        foreach ($s in $Report.LinkSkips) {
            if ($seen.Add([string]$s.Path + '|' + [string]$s.Reason)) { [void]$safetyRows.Add($s) }
        }
        foreach ($s in $safetyRows) {
            [void]$sb.AppendLine('<tr><td class="path">' + (ConvertTo-HtmlText $s.Path) + '</td>' +
                '<td>' + (ConvertTo-HtmlText $s.RuleId) + '</td>' +
                '<td class="note">' + (ConvertTo-HtmlText $s.Reason) + '</td></tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    [void]$sb.AppendLine('</section>')

    # ---- footer ----
    [void]$sb.AppendLine('<section><h2>还原与安全说明</h2><ul class="tips">')
    [void]$sb.AppendLine('<li>默认删除方式为<strong>移入回收站</strong>，可在资源管理器回收站中逐个还原。</li>')
    [void]$sb.AppendLine('<li>本工具采用<strong>白名单制</strong>：只有 <code>config/rules.default.json</code> 中显式列出的路径才会成为候选，不存在"因为没被排除所以被删掉"的情况。</li>')
    [void]$sb.AppendLine('<li>四道保护拦截（具体路径 / 目录名 / 路径段 / 扩展名）不设绕过机制，规则写错也不会删到受保护内容。</li>')
    [void]$sb.AppendLine('<li>目录联接与符号链接一律不跟随，避免通过 D 盘的链接误删其它盘的文件。</li>')
    [void]$sb.AppendLine('<li>执行前的完整命令与每条操作都记录在 <code>reports\*.log</code>，可事后审计。</li>')
    [void]$sb.AppendLine('</ul></section>')

    [void]$sb.AppendLine('<footer>SafeDriveCleaner v' + (ConvertTo-HtmlText $Report.Version) + ' · 报告由工具自动生成，请勿手工修改</footer>')
    [void]$sb.AppendLine('</div></body></html>')

    $sb.ToString() | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}
