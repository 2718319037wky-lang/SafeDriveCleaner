# ============================================================================
#  Common.ps1 - 公共基础函数
#  SafeDriveCleaner / 白名单驱动的 Windows 磁盘安全清理工具
# ============================================================================
#Requires -Version 5.1

$script:CleanerLogFile   = $null
$script:CleanerLogWriter = $null
$script:CleanerDebug     = $false
$script:CleanerQuiet     = $false

function Set-CleanerLogFile {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $script:CleanerLogFile = $Path

    # 用常开 + AutoFlush 的 StreamWriter，而不是每次 Add-Content。
    # 后者每写一行都要开关一次文件，实测会偶发丢行 —— 对审计型工具不可接受。
    try {
        $enc = New-Object System.Text.UTF8Encoding($true)
        $sw = New-Object System.IO.StreamWriter($Path, $false, $enc)
        $sw.AutoFlush = $true
        $script:CleanerLogWriter = $sw
    }
    catch {
        $script:CleanerLogWriter = $null
    }
}

function Close-CleanerLogFile {
    [CmdletBinding()]
    param()

    if ($script:CleanerLogWriter) {
        try {
            $script:CleanerLogWriter.Flush()
            $script:CleanerLogWriter.Dispose()
        }
        catch { }
        $script:CleanerLogWriter = $null
    }
}

function Write-CLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'SKIP', 'DEBUG', 'STEP', 'HEAD')]
        [string]$Level = 'INFO',
        [Parameter(Position = 2)][ConsoleColor]$Color
    )

    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[' + $ts + '] [' + $Level.PadRight(5) + '] ' + $Message

    # 日志文件始终完整记录（含 DEBUG），便于事后审计
    if ($script:CleanerLogWriter) {
        try { $script:CleanerLogWriter.WriteLine($line) } catch { }
    }
    elseif ($script:CleanerLogFile) {
        Add-Content -LiteralPath $script:CleanerLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }

    # 控制台输出按级别过滤
    $show = $true
    if ($Level -eq 'DEBUG' -and -not $script:CleanerDebug) { $show = $false }
    if ($script:CleanerQuiet -and $Level -notin @('WARN', 'ERROR', 'HEAD')) { $show = $false }
    if (-not $show) { return }

    if (-not $PSBoundParameters.ContainsKey('Color')) {
        switch ($Level) {
            'WARN'  { $Color = 'Yellow' }
            'ERROR' { $Color = 'Red' }
            'OK'    { $Color = 'Green' }
            'SKIP'  { $Color = 'DarkGray' }
            'DEBUG' { $Color = 'DarkGray' }
            'STEP'  { $Color = 'Cyan' }
            'HEAD'  { $Color = 'White' }
            default { $Color = 'Gray' }
        }
    }
    Write-Host $line -ForegroundColor $Color
}

<#
.SYNOPSIS
    安全地统计任意集合的元素个数。

.NOTES
    绝对不要用 @($x).Count 来数集合。在 Windows PowerShell 5.1 上，
    数组子表达式作用在 List[object] 上会直接抛 ArgumentException: 参数类型不匹配；
    而 List[string] / ArrayList / 普通数组都正常 —— 这个坑只在泛型实参为 object 时出现，
    非常隐蔽（已由 tests/Test-Syntax.ps1 记录说明）。
#>
function Get-CleanerCount {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return 0 }
    if ($Value -is [string]) { return 1 }
    if ($Value -is [System.Collections.ICollection]) { return [int]$Value.Count }
    if ($Value -is [System.Collections.IEnumerable]) {
        $n = 0
        foreach ($item in $Value) { $n++ }
        return $n
    }
    return 1
}

<#
.SYNOPSIS
    把任意集合安全地归一化成 object[]。

.NOTES
    两个已实测的 PowerShell 5.1 陷阱，本函数同时规避：

    1) 不要用 @($x).Count 数集合。
       数组子表达式作用在 List[object] 上会抛 ArgumentException: 参数类型不匹配；
       List[string] / ArrayList / 普通数组都正常，所以这个坑只在泛型实参为 object 时出现。

    2) 不要用 New-Object 'object[]' N 构造结果数组。
       PS 5.1 下 New-Object 返回的数组带 PSObject 包装，CLR 类型同样是 System.Object[]，
       但 ConvertTo-Json 会把它序列化成 {"value":[...],"Count":N} 而不是 [...]，
       导致下游 JSON 消费者读不到数组（同一份报告里用 @()+= 构造的数组却是正常的）。
       这里改用泛型 List 收集 + 强转剥离包装。

    所有对外返回集合的函数都应在返回处调用本函数，
    这样调用方无论写 for / foreach / @() / .Count 都不会踩坑。
#>
function ConvertTo-CleanerArray {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return , @() }
    if ($Value -is [string]) { return , @($Value) }

    if ($Value -is [System.Collections.IEnumerable]) {
        $tmp = New-Object System.Collections.Generic.List[object]
        foreach ($i in $Value) { [void]$tmp.Add($i) }
        return , ([object[]]$tmp.ToArray())
    }

    return , (@($Value))
}

function Format-Size {
    [CmdletBinding()]
    param([double]$Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

<#
.SYNOPSIS
    把路径规范化为绝对路径，去掉末尾反斜杠（盘符根除外）。
#>
function Get-NormalizedPath {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $p = [System.Environment]::ExpandEnvironmentVariables($Path)
    $p = $p.Replace('/', '\').Trim()
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }

    # 纯盘符：D / D: / D:\  ->  D:\
    if ($p -match '^[A-Za-z]:\\*$') { return ($p.Substring(0, 2) + '\') }

    try { $p = [System.IO.Path]::GetFullPath($p) } catch { return $p.TrimEnd('\') }

    while ($p.Length -gt 3 -and $p.EndsWith('\')) { $p = $p.Substring(0, $p.Length - 1) }
    if ($p.Length -eq 2 -and $p[1] -eq ':') { $p += '\' }
    return $p
}

<#
.SYNOPSIS
    判断 $Child 是否位于 $Parent 之下（或被 $Parent 包含）。
#>
function Test-PathIsInside {
    [CmdletBinding()]
    param(
        [string]$Child,
        [string]$Parent,
        [switch]$AllowEqual
    )

    $c = Get-NormalizedPath $Child
    $p = Get-NormalizedPath $Parent
    if (-not $c -or -not $p) { return $false }

    if ($c.TrimEnd('\') -ieq $p.TrimEnd('\')) { return [bool]$AllowEqual }

    $prefix = $p
    if (-not $prefix.EndsWith('\')) { $prefix += '\' }
    return $c.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

<#
.SYNOPSIS
    判断路径中的目录段是否命中保护段（例如 \Documents\ 、\Desktop\ ）。
    用于拦截"目标本身名字无害、但整体位于用户数据区"的误配置规则。
#>
function Test-PathHasProtectedSegment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Segments
    )

    if (-not $Segments -or $Segments.Count -eq 0) { return $null }

    $norm = Get-NormalizedPath $Path
    if (-not $norm) { return $null }
    $padded = '\' + $norm.TrimEnd('\') + '\'

    foreach ($seg in $Segments) {
        if ([string]::IsNullOrWhiteSpace($seg)) { continue }
        if ($padded.IndexOf('\' + $seg.Trim('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $seg
        }
    }
    return $null
}

<#
.SYNOPSIS
    判断路径（或其某个祖先，止于 $StopAt）是否为重解析点（junction / symlink）。
    这是本工具最重要的安全防线之一：绝不穿过 junction / symlink 删除目标。
#>
function Test-HasReparseAncestor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$StopAt
    )

    $cur  = Get-NormalizedPath $Path
    $stop = (Get-NormalizedPath $StopAt).TrimEnd('\')
    if (-not $cur -or -not $stop) { return $false }

    $guard = 0
    while ($cur -and $guard -lt 64) {
        $guard++
        try {
            $attrs = [System.IO.File]::GetAttributes($cur)
            if ($attrs -band [System.IO.FileAttributes]::ReparsePoint) { return $true }
        }
        catch {
            # 无法读取属性（不存在 / 无权限）时不在此处阻断，交由存在性检查处理
        }

        if ($cur.TrimEnd('\') -ieq $stop) { break }
        $parent = Split-Path -Parent $cur
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ieq $cur) { break }
        $cur = Get-NormalizedPath $parent
    }
    return $false
}

<#
.SYNOPSIS
    把 glob 通配模式转换为 .NET 正则。支持 * ? **（跨目录）。
#>
function ConvertTo-GlobRegex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [switch]$IgnoreCase
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('^')

    $pat = $Pattern.Replace('/', '\')
    $i = 0
    while ($i -lt $pat.Length) {
        $c = $pat[$i]
        if ($c -eq '*') {
            if (($i + 1) -lt $pat.Length -and $pat[$i + 1] -eq '*') {
                if (($i + 2) -lt $pat.Length -and $pat[$i + 2] -eq '\') {
                    [void]$sb.Append('(?:.*\\)?')   # **\ 匹配"零层或多层目录"
                    $i += 3
                    continue
                }
                [void]$sb.Append('.*')
                $i += 2
                continue
            }
            [void]$sb.Append('[^\\]*')
            $i++
            continue
        }
        if ($c -eq '?') {
            [void]$sb.Append('[^\\]')
            $i++
            continue
        }
        [void]$sb.Append([System.Text.RegularExpressions.Regex]::Escape([string]$c))
        $i++
    }

    [void]$sb.Append('$')

    $opts = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    if ($IgnoreCase) { $opts = $opts -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
    return [System.Text.RegularExpressions.Regex]::new($sb.ToString(), $opts)
}

<#
.SYNOPSIS
    从 glob 模式中提取最长的纯文本片段，用作匹配前的快速预筛（性能优化）。
#>
function Get-GlobLiteralHint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Pattern)

    $best = ''
    foreach ($seg in $Pattern.Split('\')) {
        if ($seg -match '[\*\?\[]') { continue }
        if ($seg.Length -gt $best.Length) { $best = $seg }
    }
    return $best
}

<#
.SYNOPSIS
    检查文件是否被其他进程占用（独占打开测试）。清理前预检，避免半途失败与系统弹窗。
#>
function Test-FileLocked {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $fs = [System.IO.File]::Open($Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
        $fs.Close()
        $fs.Dispose()
        return $false
    }
    catch { return $true }
}

<#
.SYNOPSIS
    判断一条 glob 模式是否"除根目录外全是通配符"（例如 {ROOT}\**）。
    这类模式会匹配根目录下的几乎所有条目，是最容易写出的过宽白名单，值得告警。
#>
function Test-CleanerPatternIsOverlyBroad {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Pattern,
        [Parameter(Mandatory)][string]$RootPath
    )

    if ([string]::IsNullOrWhiteSpace($Pattern)) { return $false }
    if ($Pattern -notmatch '[\*\?]') { return $false }

    $root = (Get-NormalizedPath $RootPath).TrimEnd('\')
    $rest = $Pattern.Replace('/', '\')
    if ($rest.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rest = $rest.Substring($root.Length)
    }
    $rest = $rest.Trim('\')

    # 去掉根目录前缀后，如果只剩通配符和分隔符，就是"匹配一切"
    if ([string]::IsNullOrWhiteSpace($rest)) { return $false }
    return [bool]($rest -match '^[\*\\\?]+$')
}

function Get-PathAgeDays {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [math]::Round(((Get-Date) - $item.LastWriteTime).TotalDays, 1)
    }
    catch { return $null }
}
