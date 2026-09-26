#Requires -Version 5.1
<#
.SYNOPSIS
    SafeDriveCleaner —— 白名单驱动的 Windows 磁盘安全清理工具。

.DESCRIPTION
    核心安全设计：
      1. 默认只读：不加 -Mode Clean 永远不会删除任何东西。
      2. 白名单制：只有 config/rules.default.json 里显式列出的路径才是候选。
      3. 四道保护拦截：具体路径 / 目录名 / 路径段 / 扩展名，且无绕过机制。
      4. 不跟随链接：目录联接与符号链接一律跳过，避免跨盘误删。
      5. 回收站删除：默认走 SHFileOperation + FOF_ALLOWUNDO，可一键还原。
      6. 年龄阈值：只清「最后修改早于 N 天」的项目，避免删掉正在使用的缓存。
      7. 全程留痕：控制台、日志、JSON 报告、HTML 报告四份记录。

.PARAMETER Drive
    目标盘符，默认 D。

.PARAMETER RootPath
    直接指定根目录，用于测试或清理非盘符目录树。指定后 Drive 仅用于展示。

.PARAMETER Mode
    Scan（默认，只读扫描）/ Clean（执行清理）。

.PARAMETER Categories
    只处理指定分类，可多选。分类见 config/rules.default.json。

.PARAMETER IncludeRule / ExcludeRule
    按规则 id 定向包含 / 排除。

.PARAMETER MinAgeDays
    覆盖所有规则的年龄阈值。0 表示不限制。

.PARAMETER MaxDepth
    目录索引最大深度，默认 10。越大越慢但发现越全。
    真实缓存路径往往很深，例如
      \Users\<名>\AppData\Local\Google\Chrome\User Data\Default\Cache   （约 9 层）
      \Users\<名>\AppData\Roaming\JetBrains\IntelliJIdea2024.1\caches   （约 8 层）
    所以默认值不能太小。若因达到上限而遗漏，日志与报告会明确告警，不会静默漏报。

.PARAMETER DeleteMethod
    Auto（默认，回收站）/ RecycleBin / Permanent（永久删除，不可还原）。

.PARAMETER DryRun
    在 Clean 模式下只走流程不真删，用于最终确认。

.PARAMETER Yes
    跳过交互式确认，用于自动化。请务必先用 Scan + DryRun 验证。

.PARAMETER SkipRecycleBin
    跳过「本盘回收站」这条规则。在测试或不想动回收站时使用。

.PARAMETER RulesPath / LocalRulesPath / ProtectedPath
    自定义规则、本地覆盖规则、保护清单的路径。
    默认分别为 config 目录下的 rules.default.json / rules.local.json / protected.default.json。

.PARAMETER OutDir
    报告与日志输出目录，默认脚本目录下的 reports。

.PARAMETER NoReport
    不生成 HTML / JSON 报告（仅输出到控制台与日志）。

.PARAMETER Quiet
    安静模式：控制台只输出警告与错误。日志文件仍然完整记录。

.PARAMETER Trace
    详细模式：额外输出每条规则的匹配过程、被跳过的候选及其原因。
    注意不能命名为 -Debug，那会与 PowerShell 内置公共参数冲突。

.EXAMPLE
    .\Clean-DDrive.ps1
    只读扫描 D 盘，生成报告，不删任何东西。

.EXAMPLE
    .\Clean-DDrive.ps1 -Mode Clean -DryRun
    演练清理流程，展示将要删除的每一条，但不实际删除。

.EXAMPLE
    .\Clean-DDrive.ps1 -Mode Clean
    交互式确认后执行清理（删除到回收站）。

.EXAMPLE
    .\Clean-DDrive.ps1 -Mode Clean -Categories 浏览器缓存,缩略图缓存 -Yes
    只清理浏览器缓存与缩略图缓存，非交互执行。
#>
[CmdletBinding()]
param(
    [string]$Drive = 'D',

    [string]$RootPath,

    [ValidateSet('Scan', 'Clean')]
    [string]$Mode = 'Scan',

    [string[]]$Categories,

    [string[]]$IncludeRule,

    [string[]]$ExcludeRule,

    [int]$MinAgeDays = -1,

    [int]$MaxDepth = 10,

    [ValidateSet('Auto', 'RecycleBin', 'Permanent')]
    [string]$DeleteMethod = 'Auto',

    [switch]$DryRun,

    [switch]$SkipRecycleBin,

    [string]$RulesPath,

    [string]$LocalRulesPath,

    [string]$ProtectedPath,

    [string]$OutDir,

    [switch]$NoReport,

    [switch]$Yes,

    [switch]$Quiet,

    [switch]$Trace
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.1'

# ---------------------------------------------------------------------------
# 加载模块
# ---------------------------------------------------------------------------
$srcDir = Join-Path $PSScriptRoot 'src'
foreach ($f in @('Common.ps1', 'Rules.ps1', 'Scanner.ps1', 'Cleaner.ps1', 'Reporter.ps1', 'Restore.ps1')) {
    $p = Join-Path $srcDir $f
    if (-not (Test-Path -LiteralPath $p)) { throw "缺少模块文件: $p" }
    . $p
}

if ($Trace) { $script:CleanerDebug = $true }
if ($Quiet) {
    $script:CleanerQuiet = $true
    # 安静模式同时关掉进度条，避免在 CI / 重定向输出里产生大量噪声
    $ProgressPreference = 'SilentlyContinue'
}

# ---------------------------------------------------------------------------
# 解析参数与路径
# ---------------------------------------------------------------------------
$driveLetter = ($Drive.TrimEnd(':')).ToUpper()
if ($driveLetter.Length -ne 1 -or $driveLetter -notmatch '^[A-Z]$') {
    throw "无效的盘符: $Drive"
}

if ($RootPath) {
    $root = Get-NormalizedPath $RootPath
}
else {
    $root = $driveLetter + ':\'
}

if (-not (Test-Path -LiteralPath $root)) {
    throw "目标根目录不存在或不可访问: $root"
}
if (-not $root.EndsWith('\')) { $root = $root + '\' }

$configDir = Join-Path $PSScriptRoot 'config'
if (-not $RulesPath) { $RulesPath = Join-Path $configDir 'rules.default.json' }
if (-not $ProtectedPath) { $ProtectedPath = Join-Path $configDir 'protected.default.json' }
if (-not $LocalRulesPath) { $LocalRulesPath = Join-Path $configDir 'rules.local.json' }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'reports' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $OutDir ("safedrivecleaner-$stamp.log")
Set-CleanerLogFile -Path $logPath

# ---------------------------------------------------------------------------
# 开场信息
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host (" SafeDriveCleaner v$ScriptVersion  ·  白名单驱动的磁盘安全清理") -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-CLog ("目标根目录 : " + $root) 'INFO'
Write-CLog ("运行模式   : " + $Mode + $(if ($DryRun) { ' + DryRun' } else { '' })) 'INFO'
Write-CLog ("删除方式   : " + $DeleteMethod) 'INFO'
Write-CLog ("日志文件   : " + $logPath) 'INFO'
Write-Host ''

try {
    # -----------------------------------------------------------------------
    # 加载配置
    # -----------------------------------------------------------------------
    Write-CLog '加载白名单规则与保护配置...' 'STEP'
    $allRules   = Import-CleanerRules -RulesPath $RulesPath -LocalRulesPath $LocalRulesPath `
        -RootPath $root -DriveLetter $driveLetter
    $protection = Import-CleanerProtection -ProtectedPath $ProtectedPath `
        -RootPath $root -DriveLetter $driveLetter

    Write-CLog ("规则总数 " + @($allRules).Count + " 条，保护路径 " + $protection.NeverTouchPaths.Count +
        " 条，保护目录名 " + $protection.NeverTouchDirNames.Count + " 个") 'INFO'

    $rules = Select-CleanerRules -Rules $allRules -Categories $Categories `
        -IncludeRule $IncludeRule -ExcludeRule $ExcludeRule

    if (@($rules).Count -eq 0) {
        Write-CLog '筛选后没有任何规则可执行，请检查 -Categories / -IncludeRule / -ExcludeRule 参数。' 'WARN'
        exit 0
    }
    Write-CLog ("本次参与规则 " + @($rules).Count + " 条") 'INFO'
    foreach ($r in $rules) {
        Write-CLog ("  - [" + $r.id + "] " + $r.name + "  (minAge=" + $r.minAgeDays + "d, risk=" + $r.risk + ")") 'DEBUG'
    }
    Write-Host ''

    # -----------------------------------------------------------------------
    # 扫描
    # -----------------------------------------------------------------------
    $scan = Invoke-CleanerScan -Rules $rules -Protection $protection -RootPath $root `
        -DriveLetter $driveLetter -MaxDepth $MaxDepth -MinAgeDaysOverride $MinAgeDays `
        -SkipRecycleBin:$SkipRecycleBin

    # -----------------------------------------------------------------------
    # 扫描摘要
    # -----------------------------------------------------------------------
    $sorted = $scan.Candidates | Sort-Object -Property Bytes -Descending
    $totalBytes = [long]0
    foreach ($c in $sorted) { $totalBytes += $c.Bytes }

    Write-Host ''
    Write-CLog '---------------- 扫描结果 ----------------' 'HEAD'
    if (@($sorted).Count -eq 0) {
        Write-CLog '未发现符合白名单规则的可清理目标。' 'INFO'
    }
    else {
        $byCat = @()
        foreach ($g in ($sorted | Group-Object Category)) {
            $b = [long]0
            foreach ($x in $g.Group) { $b += $x.Bytes }
            $byCat += [pscustomobject]@{ 分类 = $g.Name; 条目 = $g.Count; 体积 = (Format-Size $b); Bytes = $b }
        }
        $byCat = $byCat | Sort-Object -Property Bytes -Descending
        $byCat | Select-Object 分类, 条目, 体积 | Format-Table -AutoSize | Out-String | Write-Host

        Write-CLog ("可清理总量 " + (Format-Size $totalBytes) + "，候选条目 " + @($sorted).Count + " 项") 'OK'
    }

    Write-CLog ("索引目录 " + $scan.IndexDirs + " 个 / 文件 " + $scan.IndexFiles + " 个；剪枝跳过 " + $scan.PrunedCount + " 处") 'INFO'
    Write-CLog ("扫描耗时 " + $scan.DurationSec + " 秒") 'INFO'

    $truncCount = Get-CleanerCount $scan.Truncated
    if ($truncCount -gt 0) {
        Write-CLog ("注意：有 " + $truncCount + " 个目录因达到 -MaxDepth " + $MaxDepth +
            " 而未继续下探，其更深层内容未被索引，可能漏掉缓存。建议提高 -MaxDepth 后重新扫描。") 'WARN'
        if ($script:CleanerDebug) {
            foreach ($t in ($scan.Truncated | Select-Object -First 20)) {
                Write-CLog ("    截断于深度 " + $t.Depth + "：" + $t.Path) 'DEBUG'
            }
        }
    }

    $protectCount = @($scan.Skipped | Where-Object { $_.Code -like 'P_*' }).Count
    if ($protectCount -gt 0) {
        Write-CLog ("保护规则拦截了 " + $protectCount + " 个候选（安全防线生效）") 'OK'
        if ($script:CleanerDebug) {
            foreach ($s in ($scan.Skipped | Where-Object { $_.Code -like 'P_*' } | Select-Object -First 20)) {
                Write-CLog ("    " + $s.Path + " → " + $s.Reason) 'DEBUG'
            }
        }
    }
    $tooNewCount = @($scan.Skipped | Where-Object { $_.Code -eq 'S_TOO_NEW' }).Count
    if ($tooNewCount -gt 0) {
        Write-CLog ("因'仍在使用中'（未达年龄阈值）跳过 " + $tooNewCount + " 项") 'INFO'
    }

    # -----------------------------------------------------------------------
    # 扫描模式到此结束
    # -----------------------------------------------------------------------
    $cleanResult = $null

    if ($Mode -eq 'Clean' -and @($sorted).Count -gt 0) {

        Write-Host ''
        Write-CLog '---------------- 待清理明细（按体积降序，前 40 条） ----------------' 'HEAD'
        $i = 0
        foreach ($c in $sorted) {
            $i++
            if ($i -gt 40) { break }
            $riskTag = ''
            if ($c.Risk -eq 'high') { $riskTag = '  [高风险]' }
            elseif ($c.Risk -eq 'medium') { $riskTag = '  [需重新下载/重建]' }
            Write-Host ('  ' + (Format-Size $c.Bytes).PadLeft(10) + '  ' + $c.Path + $riskTag) -ForegroundColor Gray
        }
        if (@($sorted).Count -gt 40) {
            Write-Host ('  ... 其余 ' + (@($sorted).Count - 40) + ' 条见报告') -ForegroundColor DarkGray
        }

        $needConfirm = -not $Yes
        $confirmed = $false

        if ($DryRun) {
            Write-Host ''
            Write-CLog 'DryRun 模式：不会实际删除任何文件。' 'WARN'
            $confirmed = $true
        }
        elseif ($needConfirm) {
            Write-Host ''
            Write-Host '------------------------------------------------------------' -ForegroundColor Yellow
            if ($DeleteMethod -eq 'Permanent') {
                Write-CLog '⚠ 你选择了永久删除：被清理的内容将无法通过回收站还原！' 'WARN'
                Write-Host '请输入 PERMANENT 确认永久删除，其它任意输入将取消：' -ForegroundColor Yellow
                $ans = $null
                try { $ans = Read-Host } catch { $ans = $null }
                if ($ans -ceq 'PERMANENT') { $confirmed = $true }
            }
            else {
                Write-Host ('即将把以上 ' + @($sorted).Count + ' 项、合计 ' + (Format-Size $totalBytes) +
                    ' 的内容移入回收站（可在回收站还原）。') -ForegroundColor Yellow
                Write-Host '请输入 YES 确认执行，其它任意输入将取消：' -ForegroundColor Yellow
                $ans = $null
                try { $ans = Read-Host } catch { $ans = $null }
                if ($ans -ceq 'YES') { $confirmed = $true }
            }
            Write-Host '------------------------------------------------------------' -ForegroundColor Yellow
        }
        else {
            Write-CLog '已指定 -Yes，跳过交互式确认。' 'WARN'
            if ($DeleteMethod -eq 'Permanent') {
                Write-CLog '⚠ -Yes 与永久删除同时使用：将直接执行不可还原的删除。' 'WARN'
            }
            $confirmed = $true
        }

        if ($confirmed) {
            Write-Host ''
            $cleanResult = Invoke-CleanerClean -Candidates $sorted -DriveLetter $driveLetter `
                -DeleteMethod $DeleteMethod -DryRun:$DryRun `
                -RootPath $root -Protection $protection

            $okN = 0; $failN = 0
            foreach ($r in $cleanResult.Results) {
                if ($r.Status -eq 'Deleted' -or $r.Status -eq 'DryRun') { $okN++ } else { $failN++ }
            }
            Write-Host ''
            if ($DryRun) {
                Write-CLog ('预演完成：' + $okN + ' 项将被清理，合计 ' + (Format-Size $totalBytes)) 'OK'
            }
            else {
                Write-CLog ('清理完成：成功 ' + $okN + ' 项，失败 ' + $failN + ' 项') 'OK'
                if ($cleanResult.Method -ne 'Permanent') {
                    Write-CLog '内容已移入回收站，如需还原请使用 Restore-FromRecycleBin.ps1 或手动打开回收站。' 'INFO'
                }
            }
        }
        else {
            Write-CLog '已取消，未做任何删除。' 'WARN'
        }
    }
    elseif ($Mode -eq 'Clean') {
        Write-CLog '没有可清理的目标，跳过清理阶段。' 'INFO'
    }

    # -----------------------------------------------------------------------
    # 报告
    # -----------------------------------------------------------------------
    if (-not $NoReport) {
        $report = New-CleanerReportObject -Scan $scan -Clean $cleanResult -Mode $Mode `
            -DriveLetter $driveLetter -RootPath $root -MaxDepth $MaxDepth -Version $ScriptVersion

        $jsonPath = Join-Path $OutDir ("safedrivecleaner-$stamp.json")
        $htmlPath = Join-Path $OutDir ("safedrivecleaner-$stamp.html")
        $latestHtml = Join-Path $OutDir 'latest.html'

        Export-CleanerJsonReport -Report $report -Path $jsonPath | Out-Null
        Export-CleanerHtmlReport -Report $report -Path $htmlPath | Out-Null
        Copy-Item -LiteralPath $htmlPath -Destination $latestHtml -Force

        Write-Host ''
        Write-CLog '---------------- 报告已生成 ----------------' 'HEAD'
        Write-CLog ('HTML 报告 : ' + $htmlPath) 'INFO'
        Write-CLog ('JSON 报告 : ' + $jsonPath) 'INFO'
        Write-CLog ('日志文件 : ' + $logPath) 'INFO'
        Write-CLog ('最新报告 : ' + $latestHtml) 'INFO'

        $script:LastHtmlReport = $htmlPath
    }

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' 完成。' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Close-CleanerLogFile
}
catch {
    $ex = $_.Exception
    Write-CLog ('执行失败：' + $ex.GetType().FullName) 'ERROR'
    Write-CLog ('错误信息：' + $ex.Message) 'ERROR'
    $pos = ''
    try { $pos = ($_.InvocationInfo.PositionMessage -replace "`r?`n", ' | ').Trim() } catch { }
    Write-CLog ('出错位置：' + $pos) 'ERROR'
    Write-CLog ('调用栈：' + $_.ScriptStackTrace) 'DEBUG'
    Close-CleanerLogFile
    exit 1
}
