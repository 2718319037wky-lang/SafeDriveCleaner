# ============================================================================
#  Scanner.ps1 - 目录树索引、规则匹配、保护裁决与体积统计
#  SafeDriveCleaner
#  设计要点：整个目标盘只遍历一次建立索引，之后所有规则都在内存里做匹配，
#            避免每条规则都全盘扫一遍。
# ============================================================================
#Requires -Version 5.1

<#
.SYNOPSIS
    一次性遍历根目录建立索引（目录 + 文件），跳过重解析点与剪枝目录。
#>
function Get-CleanerTreeIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [int]$MaxDepth = 6,
        [string[]]$PruneNames
    )

    $dirs      = New-Object System.Collections.Generic.List[object]
    $files     = New-Object System.Collections.Generic.List[object]
    $pruned    = New-Object System.Collections.Generic.List[object]
    $truncated = New-Object System.Collections.Generic.List[object]
    $queue     = New-Object System.Collections.Generic.Queue[object]

    $queue.Enqueue(@{ Path = $RootPath; Depth = 0 })
    $visited = 0

    while ($queue.Count -gt 0) {
        $node  = $queue.Dequeue()
        $cur   = $node.Path
        $depth = $node.Depth
        $visited++
        if (($visited % 500) -eq 0) {
            Write-Progress -Activity '建立目录索引' -Status ("已遍历 $visited 个目录，索引 " + $dirs.Count + " 个子目录") -PercentComplete -1
        }

        if ($depth -ge $MaxDepth) {
            # 记录达到深度上限、仍有子目录的节点。
            # 这类节点之下不会被索引，若有规则本该命中就会静默漏掉 —— 必须让调用方知道，
            # 否则用户会以为"盘很干净"，其实是"根本没扫到"。
            try {
                $boundary = [System.IO.DirectoryInfo]::new($cur)
                if ($boundary.GetDirectories().Count -gt 0) {
                    $truncated.Add([pscustomobject]@{ Path = $cur; Depth = $depth })
                }
            }
            catch { }
            continue
        }

        $di = $null
        try { $di = [System.IO.DirectoryInfo]::new($cur) } catch { continue }

        $subFiles = @()
        try { $subFiles = $di.GetFiles() } catch { $subFiles = @() }
        foreach ($f in $subFiles) {
            $files.Add([pscustomobject]@{
                    Path   = $f.FullName
                    Name   = $f.Name
                    Depth  = $depth + 1
                    Length = $f.Length
                })
        }

        $subDirs = @()
        try { $subDirs = $di.GetDirectories() } catch { $subDirs = @() }
        foreach ($sd in $subDirs) {
            if ($sd.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                $pruned.Add([pscustomobject]@{ Path = $sd.FullName; Reason = 'reparse-point' })
                continue
            }
            $skip = $false
            foreach ($n in $PruneNames) {
                if ($n -and $sd.Name -ieq $n) { $skip = $true; break }
            }
            if ($skip) {
                $pruned.Add([pscustomobject]@{ Path = $sd.FullName; Reason = 'pruned' })
                continue
            }

            $dirs.Add([pscustomobject]@{ Path = $sd.FullName; Name = $sd.Name; Depth = $depth + 1 })
            $queue.Enqueue(@{ Path = $sd.FullName; Depth = $depth + 1 })
        }
    }

    Write-Progress -Activity '建立目录索引' -Completed

    return [pscustomobject]@{
        Root        = $RootPath
        Directories = $dirs
        Files       = $files
        Pruned      = $pruned
        Truncated   = $truncated
        MaxDepth    = $MaxDepth
    }
}

<#
.SYNOPSIS
    统计一个目录/文件的体积与条目数（不跟随重解析点）。
#>
function Get-PathStats {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IsFile
    )

    if ($IsFile) {
        try {
            $len = [System.IO.FileInfo]::new($Path).Length
            return [pscustomobject]@{ Bytes = [long]$len; Files = 1; Dirs = 0 }
        }
        catch { return [pscustomobject]@{ Bytes = [long]0; Files = 0; Dirs = 0 } }
    }

    $bytes = [long]0
    $nFiles = 0
    $nDirs = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)

    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        $di = $null
        try { $di = [System.IO.DirectoryInfo]::new($cur) } catch { continue }

        try {
            foreach ($f in $di.GetFiles()) {
                $bytes += $f.Length
                $nFiles++
            }
        }
        catch { }

        try {
            foreach ($sd in $di.GetDirectories()) {
                if ($sd.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $nDirs++
                $stack.Push($sd.FullName)
            }
        }
        catch { }
    }

    return [pscustomobject]@{ Bytes = $bytes; Files = $nFiles; Dirs = $nDirs }
}

<#
.SYNOPSIS
    估算目标盘回收站占用（尽力而为，无权限时返回 -1 表示未知）。
#>
function Get-RecycleBinStats {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DriveLetter)

    $bin = $DriveLetter.TrimEnd(':') + ':\$Recycle.Bin'
    if (-not (Test-Path -LiteralPath $bin)) {
        return [pscustomobject]@{ Bytes = [long]0; Files = 0; Dirs = 0; Accessible = $true }
    }
    $st = Get-PathStats -Path $bin
    return [pscustomobject]@{
        Bytes      = $st.Bytes
        Files      = $st.Files
        Dirs       = $st.Dirs
        Accessible = ($st.Bytes -ge 0)
    }
}

<#
.SYNOPSIS
    用一条规则去索引里找候选目标。
#>
function Find-RuleCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Rule,
        [Parameter(Mandatory)]$Index,
        [Parameter(Mandatory)][string]$RootPath
    )

    $found = New-Object System.Collections.Generic.List[object]
    $seen  = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    $wantFile = ($Rule.targetType -eq 'file')

    foreach ($pattern in $Rule.patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }

        $hasWildcard = ($pattern -match '[\*\?]')

        if (-not $hasWildcard) {
            # 字面路径：直接检查存在性，不受索引深度限制
            $norm = Get-NormalizedPath $pattern
            if ($norm -and $seen.Add($norm)) {
                $found.Add([pscustomobject]@{ Path = $norm; Type = $Rule.targetType; Source = 'literal' })
            }
            continue
        }

        $regex = ConvertTo-GlobRegex -Pattern $pattern -IgnoreCase
        $hint  = Get-GlobLiteralHint -Pattern $pattern

        $pool = $Index.Files
        if (-not $wantFile) { $pool = $Index.Directories }

        foreach ($entry in $pool) {
            if ($hint -and $entry.Path.IndexOf($hint, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            if (-not $regex.IsMatch($entry.Path)) { continue }
            if ($seen.Add($entry.Path)) {
                $found.Add([pscustomobject]@{ Path = $entry.Path; Type = $Rule.targetType; Source = 'index' })
            }
        }
    }

    return ,(ConvertTo-CleanerArray $found)
}

<#
.SYNOPSIS
    若某候选位于另一个候选之下，则丢弃（删父目录即可，避免重复计数与重复操作）。
#>
function Remove-NestedCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Candidates)

    $arr = ConvertTo-CleanerArray $Candidates
    if (-not $arr -or $arr.Count -le 1) { return ,(ConvertTo-CleanerArray $arr) }

    $sorted = $arr | Sort-Object { $_.Path.Length }
    $kept = New-Object System.Collections.ArrayList

    foreach ($c in $sorted) {
        $shadowed = $false
        foreach ($k in $kept) {
            if (Test-PathIsInside -Child $c.Path -Parent $k.Path) { $shadowed = $true; break }
        }
        if (-not $shadowed) { [void]$kept.Add($c) }
    }
    return ,(ConvertTo-CleanerArray $kept)
}

<#
.SYNOPSIS
    执行完整扫描：匹配规则 -> 保护裁决 -> 年龄过滤 -> 体积统计。
#>
function Invoke-CleanerScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)]$Protection,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$DriveLetter,
        [int]$MaxDepth = 6,
        [int]$MinAgeDaysOverride = -1,
        [switch]$SkipRecycleBin
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $candidates = New-Object System.Collections.Generic.List[object]
    $skipped    = New-Object System.Collections.Generic.List[object]
    $linkSkips  = New-Object System.Collections.Generic.List[object]

    Write-CLog "开始建立目录索引（最大深度 $MaxDepth，跳过链接与剪枝目录）..." 'STEP'
    $index = Get-CleanerTreeIndex -RootPath $RootPath -MaxDepth $MaxDepth -PruneNames $Protection.PruneDirNames
    Write-CLog ("索引完成：目录 " + $index.Directories.Count + " 个，文件 " + $index.Files.Count +
        " 个，剪枝 " + $index.Pruned.Count + " 处，耗时 " + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s") 'INFO'

    if ($index.Truncated.Count -gt 0) {
        Write-CLog ("注意：" + $index.Truncated.Count + " 个目录已达到深度上限 " + $MaxDepth +
            " 且仍有子目录，其更深层内容未被索引。如需完整覆盖请提高 -MaxDepth。") 'WARN'
    }

    foreach ($pr in $index.Pruned) {
        if ($pr.Reason -eq 'reparse-point') {
            $linkSkips.Add([pscustomobject]@{
                    Path   = $pr.Path
                    RuleId = '-'
                    Reason = '遍历时跳过目录联接/符号链接，绝不穿过链接删除内容'
                    Code   = 'P_LINK'
                })
        }
    }

    foreach ($rule in $Rules) {
        if ($rule.targetType -eq 'recycleBin') { continue }

        Write-CLog ("匹配规则 [" + $rule.id + "] " + $rule.name) 'DEBUG'
        $raw = Find-RuleCandidates -Rule $rule -Index $index -RootPath $RootPath
        $raw = Remove-NestedCandidate -Candidates $raw

        $ageLimit = $rule.minAgeDays
        if ($MinAgeDaysOverride -ge 0) { $ageLimit = $MinAgeDaysOverride }

        foreach ($cand in $raw) {
            $verdict = Test-CleanerTargetAllowed -Path $cand.Path -RootPath $RootPath `
                -Protection $Protection -TargetType $cand.Type

            if (-not $verdict.Allowed) {
                $entry = [pscustomobject]@{
                    Path     = $cand.Path
                    RuleId   = $rule.id
                    RuleName = $rule.name
                    Reason   = $verdict.Reason
                    Code     = $verdict.Code
                }
                $skipped.Add($entry)
                if ($verdict.Code -eq 'P_LINK') { $linkSkips.Add($entry) }
                Write-CLog ("  跳过 " + $cand.Path + " → " + $verdict.Reason) 'DEBUG'
                continue
            }

            $age = Get-PathAgeDays -Path $cand.Path
            if ($null -ne $age -and $ageLimit -gt 0 -and $age -lt $ageLimit) {
                $skipped.Add([pscustomobject]@{
                        Path     = $cand.Path
                        RuleId   = $rule.id
                        RuleName = $rule.name
                        Reason   = ('最后修改于 ' + $age + ' 天前，未达到 ' + $ageLimit + ' 天阈值，判定为仍在使用中')
                        Code     = 'S_TOO_NEW'
                    })
                continue
            }

            $stats = Get-PathStats -Path $cand.Path -IsFile:($cand.Type -eq 'file')

            $candidates.Add([pscustomobject]@{
                    RuleId    = $rule.id
                    RuleName  = $rule.name
                    Category  = $rule.category
                    Risk      = $rule.risk
                    Path      = $cand.Path
                    Type      = $cand.Type
                    AgeDays   = $age
                    MinAge    = $ageLimit
                    Bytes     = $stats.Bytes
                    Files     = $stats.Files
                    Dirs      = $stats.Dirs
                    Note      = $rule.note
                    IsSpecial = $false
                })
        }
    }

    # 回收站作为特殊目标单独处理（走系统 API，不按路径删除）
    if (-not $SkipRecycleBin) {
        $rbRule = $Rules | Where-Object { $_.targetType -eq 'recycleBin' } | Select-Object -First 1
        if ($rbRule) {
            $rb = Get-RecycleBinStats -DriveLetter $DriveLetter
            $candidates.Add([pscustomobject]@{
                    RuleId    = $rbRule.id
                    RuleName  = $rbRule.name
                    Category  = $rbRule.category
                    Risk      = $rbRule.risk
                    Path      = ($DriveLetter.TrimEnd(':') + ':\$Recycle.Bin')
                    Type      = 'recycleBin'
                    AgeDays   = $null
                    MinAge    = 0
                    Bytes     = $rb.Bytes
                    Files     = $rb.Files
                    Dirs      = $rb.Dirs
                    Note      = $rbRule.note
                    IsSpecial = $true
                })
        }
    }

    $sw.Stop()
    return [pscustomobject]@{
        Root        = $RootPath
        Candidates  = (ConvertTo-CleanerArray $candidates)
        Skipped     = (ConvertTo-CleanerArray $skipped)
        LinkSkips   = (ConvertTo-CleanerArray $linkSkips)
        IndexDirs   = $index.Directories.Count
        IndexFiles  = $index.Files.Count
        PrunedCount = $index.Pruned.Count
        Truncated   = (ConvertTo-CleanerArray $index.Truncated)
        DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}
