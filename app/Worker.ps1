#Requires -Version 5.1
<#
.SYNOPSIS
    GUI 与清理引擎之间的桥接层。

.DESCRIPTION
    本文件被界面以**后台任务**方式调用，作用只有两个：

      1. 在后台进程里加载现有引擎（src\*.ps1），把扫描/清理包成一次可调用的任务；
      2. 把结果整理成扁平、可序列化的对象交回界面。

    安全要点（很重要，不要改成"界面直接传候选列表给删除接口"）：
    清理模式下界面只传**路径字符串**，本函数会重新完整扫描一遍，
    再与界面传来的路径取**交集**后才交给 Invoke-CleanerClean。

    由此得到一条硬性质：
        界面能做的只有"从引擎自己算出的候选里减掉一些"，
        永远无法让引擎去删一个它自己不会产生的目标。
    即使界面被改坏、或用户手工构造了路径，也无法越过这道限制；
    而且 Invoke-CleanerClean 内部还会对每一条再做一次完整保护裁决。
#>
[CmdletBinding()]
param()

# 在加载期就把根目录记下来。
# 注意：$PSScriptRoot 只有在本文件**顶层执行**时才可靠；在函数体内（尤其是被 job
# 反序列化上下文调用时）它可能为空，所以统一走这个变量，不要在函数里重新算。
$script:EngineRoot = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $script:EngineRoot 'src'
foreach ($f in @('Common.ps1', 'Rules.ps1', 'Scanner.ps1', 'Cleaner.ps1', 'Reporter.ps1', 'Restore.ps1')) {
    . (Join-Path $srcDir $f)
}

<#
.SYNOPSIS
    执行一次扫描或清理任务，返回扁平可序列化的结果对象。
#>
function Invoke-CleanerAppTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [string]$DriveLetter = 'D',
        [ValidateSet('Scan', 'Clean')][string]$Mode = 'Scan',

        # 仅 Clean 模式使用：允许清理的路径白名单（界面勾选结果）。
        # 会与引擎自身候选集求交集；留空表示清理全部候选。
        [string[]]$OnlyPaths,

        [ValidateSet('RecycleBin', 'Permanent')][string]$DeleteMethod = 'RecycleBin',
        [int]$MaxDepth = 10,
        [int]$MinAgeDays = -1,
        [switch]$SkipRecycleBin,
        [string]$OutDir
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $root = $script:EngineRoot
    if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
    if (-not $OutDir) { $OutDir = Join-Path $root 'reports' }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $OutDir ("gui-$stamp.log")
    Set-CleanerLogFile -Path $logPath
    $script:CleanerQuiet = $true

    $result = [ordered]@{
        Ok              = $false
        Error           = ''
        Mode            = $Mode
        RootPath        = $RootPath
        DriveLetter     = $DriveLetter
        MaxDepth        = $MaxDepth
        StartedAt       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        DurationSec     = 0
        CandidateCount  = 0
        TotalBytes      = 0
        Categories      = @()
        Candidates      = @()
        ProtectionHits  = @()
        LinkSkips       = @()
        TooNew          = @()
        Truncated       = @()
        TruncatedCount  = 0
        IndexDirs       = 0
        IndexFiles      = 0
        PrunedCount     = 0
        RequestedCount  = 0
        MatchedCount    = 0
        DeletedCount    = 0
        FailedCount     = 0
        SkippedCount    = 0
        DeletedBytes    = 0
        CleanResults    = @()
        HtmlReport      = ''
        JsonReport      = ''
        LogFile         = $logPath
    }

    try {
        $norm = Get-NormalizedPath $RootPath
        if (-not (Test-Path -LiteralPath $norm)) { throw ('目标根目录不存在或不可访问: ' + $RootPath) }

        $rules = Import-CleanerRules -RulesPath (Join-Path $root 'config\rules.default.json') `
            -LocalRulesPath (Join-Path $root 'config\rules.local.json') `
            -RootPath $norm -DriveLetter $DriveLetter

        $protection = Import-CleanerProtection -ProtectedPath (Join-Path $root 'config\protected.default.json') `
            -RootPath $norm -DriveLetter $DriveLetter

        $scan = Invoke-CleanerScan -Rules $rules -Protection $protection -RootPath $norm `
            -DriveLetter $DriveLetter -MaxDepth $MaxDepth -MinAgeDaysOverride $MinAgeDays `
            -SkipRecycleBin:$SkipRecycleBin

        # ---- 候选清单 ----
        $candidates = @()
        $totalBytes = [long]0
        foreach ($c in $scan.Candidates) {
            $totalBytes += [long]$c.Bytes
            $candidates += [pscustomobject]@{
                Path     = [string]$c.Path
                RuleId   = [string]$c.RuleId
                RuleName = [string]$c.RuleName
                Category = [string]$c.Category
                Risk     = [string]$c.Risk
                Type     = [string]$c.Type
                Bytes    = [long]$c.Bytes
                Files    = [int]$c.Files
                Dirs     = [int]$c.Dirs
                AgeDays  = $c.AgeDays
                Note     = [string]$c.Note
            }
        }
        $candidates = ConvertTo-CleanerArray $candidates

        # ---- 分类汇总 ----
        $categories = @()
        foreach ($g in ($candidates | Group-Object Category)) {
            $b = [long]0
            foreach ($x in $g.Group) { $b += [long]$x.Bytes }
            $categories += [pscustomobject]@{
                Name  = [string]$g.Name
                Count = [int]$g.Count
                Bytes = $b
            }
        }
        $categories = ConvertTo-CleanerArray ($categories | Sort-Object -Property Bytes -Descending)

        # ---- 保护拦截 / 跳过 ----
        $protHits = @(); $tooNew = @()
        foreach ($s in $scan.Skipped) {
            $row = [pscustomobject]@{
                Path   = [string]$s.Path
                RuleId = [string]$s.RuleId
                Reason = [string]$s.Reason
                Code   = [string]$s.Code
            }
            if ($s.Code -like 'P_*') { $protHits += $row }
            elseif ($s.Code -eq 'S_TOO_NEW') { $tooNew += $row }
        }

        $linkRows = @()
        foreach ($s in $scan.LinkSkips) {
            $linkRows += [pscustomobject]@{
                Path   = [string]$s.Path
                RuleId = [string]$s.RuleId
                Reason = [string]$s.Reason
                Code   = [string]$s.Code
            }
        }

        $truncRows = @()
        foreach ($t in $scan.Truncated) {
            $truncRows += [pscustomobject]@{ Path = [string]$t.Path; Depth = [int]$t.Depth }
        }

        $result.CandidateCount = @($candidates).Count
        $result.TotalBytes = $totalBytes
        $result.Categories = $categories
        $result.Candidates = $candidates
        $result.ProtectionHits = ConvertTo-CleanerArray $protHits
        $result.LinkSkips = ConvertTo-CleanerArray $linkRows
        $result.TooNew = ConvertTo-CleanerArray $tooNew
        $result.Truncated = ConvertTo-CleanerArray $truncRows
        $result.TruncatedCount = @($truncRows).Count
        $result.IndexDirs = [int]$scan.IndexDirs
        $result.IndexFiles = [int]$scan.IndexFiles
        $result.PrunedCount = [int]$scan.PrunedCount

        # ---- 清理 ----
        $clean = $null
        if ($Mode -eq 'Clean') {
            $result.RequestedCount = if ($OnlyPaths) { @($OnlyPaths).Count } else { @($candidates).Count }

            $targets = $candidates
            if ($OnlyPaths -and @($OnlyPaths).Count -gt 0) {
                # 关键：与引擎自身候选集求交集。界面多传的路径会在这里被丢掉。
                $wanted = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($p in $OnlyPaths) { [void]$wanted.Add([string]$p) }

                $kept = @()
                foreach ($c in $candidates) {
                    if ($wanted.Contains([string]$c.Path)) { $kept += $c }
                }
                $targets = ConvertTo-CleanerArray $kept
            }
            $result.MatchedCount = @($targets).Count

            Write-CLog ('界面请求清理 ' + $result.RequestedCount + ' 项，与引擎候选集求交后剩余 ' + $result.MatchedCount + ' 项') 'INFO'

            if (@($targets).Count -gt 0) {
                $clean = Invoke-CleanerClean -Candidates $targets -DriveLetter $DriveLetter `
                    -DeleteMethod $DeleteMethod -RootPath $norm -Protection $protection
            }
            else {
                $clean = [pscustomobject]@{
                    Results = @(); DryRun = $false
                    Method = if ($DeleteMethod -eq 'Permanent') { 'Permanent' } else { 'RecycleBin' }
                    DurationSec = 0
                }
            }

            $cleanRows = @()
            $deleted = 0; $failed = 0; $skipped = 0; $deletedBytes = [long]0
            foreach ($r in $clean.Results) {
                if ($r.Status -eq 'Deleted') { $deleted++; $deletedBytes += [long]$r.Bytes }
                elseif ($r.Status -eq 'Failed') { $failed++ }
                else { $skipped++ }
                $cleanRows += [pscustomobject]@{
                    Path     = [string]$r.Path
                    RuleId   = [string]$r.RuleId
                    RuleName = [string]$r.RuleName
                    Category = [string]$r.Category
                    Type     = [string]$r.Type
                    Bytes    = [long]$r.Bytes
                    Status   = [string]$r.Status
                    Strategy = [string]$r.Strategy
                    Error    = [string]$r.Error
                }
            }
            $result.CleanResults = ConvertTo-CleanerArray $cleanRows
            $result.DeletedCount = $deleted
            $result.FailedCount = $failed
            $result.SkippedCount = $skipped
            $result.DeletedBytes = $deletedBytes
            $result.DeleteMethod = [string]$clean.Method
        }

        # ---- 报告 ----
        $report = New-CleanerReportObject -Scan $scan -Clean $clean -Mode $Mode `
            -DriveLetter $DriveLetter -RootPath $norm -MaxDepth $MaxDepth -Version '1.1.0'

        $jsonPath = Join-Path $OutDir ("gui-$stamp.json")
        $htmlPath = Join-Path $OutDir ("gui-$stamp.html")
        Export-CleanerJsonReport -Report $report -Path $jsonPath | Out-Null
        Export-CleanerHtmlReport -Report $report -Path $htmlPath | Out-Null
        Copy-Item -LiteralPath $htmlPath -Destination (Join-Path $OutDir 'latest.html') -Force

        $result.HtmlReport = $htmlPath
        $result.JsonReport = $jsonPath
        $result.Ok = $true
    }
    catch {
        $result.Ok = $false
        $result.Error = $_.Exception.Message
        Write-CLog ('任务失败：' + $_.Exception.Message) 'ERROR'
    }
    finally {
        $sw.Stop()
        $result.DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Close-CleanerLogFile
    }

    return [pscustomobject]$result
}
