#Requires -Version 5.1
<#
.SYNOPSIS
    SafeDriveCleaner 安全断言测试。
    在沙箱目录树上完整跑一遍扫描 / 预演 / 永久删除，验证：
      T1  Scan 模式绝不删除任何文件
      T2  白名单内目标被正确识别为候选
      T3  用户数据、代码仓库、数据库、虚拟机镜像等诱饵一个都不能是候选
      T4  目录联接（junction）不被跟随，沙箱外内容零损失
      T5  未达年龄阈值的"新鲜缓存"被跳过
      T6  磁盘根目录被硬性拒绝
      T7  Clean + DryRun 不删除任何文件
      T8  Clean + Permanent 只删白名单目标，其余原封不动
#>
[CmdletBinding()]
param(
    [switch]$KeepSandbox
)

$ErrorActionPreference = 'Stop'
$root     = Split-Path -Parent $PSScriptRoot
$srcDir   = Join-Path $root 'src'
$entry    = Join-Path $root 'Clean-DDrive.ps1'
$sandbox  = Join-Path $PSScriptRoot '.sandbox'
$outDir   = Join-Path $PSScriptRoot '.reports'
$expectFile = Join-Path $PSScriptRoot 'sandbox-expectations.json'
$localRules = Join-Path $PSScriptRoot 'rules.local-test.json'
$transcript = Join-Path $PSScriptRoot '.transcript.txt'

# 脚本末尾会 exit，若在宿主进程中直接调用会连带结束宿主、丢失控制台输出；
# 因此同时落一份 transcript，保证任何调用方式下结果都可追溯。
Remove-Item -LiteralPath $transcript -ErrorAction SilentlyContinue
try { Start-Transcript -Path $transcript -Force | Out-Null }
catch { Write-Host '（未能启动 transcript，将只输出到控制台）' -ForegroundColor DarkGray }

foreach ($f in @('Common.ps1', 'Rules.ps1', 'Scanner.ps1', 'Cleaner.ps1', 'Reporter.ps1', 'Restore.ps1')) {
    . (Join-Path $srcDir $f)
}
$script:CleanerQuiet = $true

$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Test-Assert {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail = ''
    )
    if ($Condition) {
        $script:Pass++
        Write-Host ('  [PASS] ' + $Name) -ForegroundColor Green
    }
    else {
        $script:Fail++
        $script:Failures.Add($Name + ' :: ' + $Detail)
        Write-Host ('  [FAIL] ' + $Name + '  ' + $Detail) -ForegroundColor Red
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=== ' + $Title + ' ===') -ForegroundColor Cyan
}

# --- 沙箱工具 ---------------------------------------------------------------
function Remove-PathSafe {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }

    $links = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        try { $di = [System.IO.DirectoryInfo]::new($cur) } catch { continue }
        try {
            foreach ($sd in $di.GetDirectories()) {
                if ($sd.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $links.Add($sd.FullName) }
                else { $stack.Push($sd.FullName) }
            }
        }
        catch { }
    }
    # 先摘掉 junction（绝不跟随），再删目录树
    foreach ($l in $links) {
        try { [System.IO.Directory]::Delete($l, $false) } catch { }
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    生成"文件相对路径 -> 字节数"的完整映射，用于精确比较是否发生过任何变化。
    不跟随重解析点。
#>
function Get-FileMap {
    param([Parameter(Mandatory)][string]$Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        try { $di = [System.IO.DirectoryInfo]::new($cur) } catch { continue }
        try {
            foreach ($f in $di.GetFiles()) {
                $map[$f.FullName] = $f.Length
            }
        }
        catch { }
        try {
            foreach ($sd in $di.GetDirectories()) {
                if ($sd.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push($sd.FullName)
            }
        }
        catch { }
    }
    return $map
}

function Compare-FileMap {
    param($Before, $After, [string]$Label)

    $removed = New-Object System.Collections.Generic.List[string]
    $added = New-Object System.Collections.Generic.List[string]
    foreach ($k in $Before.Keys) { if (-not $After.ContainsKey($k)) { $removed.Add($k) } }
    foreach ($k in $After.Keys) { if (-not $Before.ContainsKey($k)) { $added.Add($k) } }

    return [pscustomobject]@{
        Removed = $removed
        Added   = $added
        Label   = $Label
        Clean   = ($removed.Count -eq 0 -and $added.Count -eq 0)
    }
}

function Invoke-Entry {
    param([Parameter(Mandatory)][hashtable]$Args)
    $splat = @{}
    foreach ($k in $Args.Keys) { $splat[$k] = $Args[$k] }
    $out = & $entry @splat *>&1 | Out-String
    return $out
}

function Get-LatestReport {
    $f = Get-ChildItem -LiteralPath $outDir -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { return $null }
    return (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# ===========================================================================
Write-Host ''
Write-Host '############################################################' -ForegroundColor White
Write-Host ' SafeDriveCleaner 安全断言测试' -ForegroundColor White
Write-Host '############################################################' -ForegroundColor White

# --- 准备 ------------------------------------------------------------------
Remove-PathSafe -Path $sandbox
Remove-PathSafe -Path (Join-Path $PSScriptRoot '.outside-target')
Remove-PathSafe -Path (Join-Path $PSScriptRoot '.linked-target')
Remove-PathSafe -Path $outDir

Write-Host ''
Write-Host '>>> 构建沙箱' -ForegroundColor DarkCyan
& (Join-Path $PSScriptRoot 'New-Sandbox.ps1') -SandboxPath $sandbox | Out-Null

$expect = Get-Content -LiteralPath $expectFile -Raw -Encoding UTF8 | ConvertFrom-Json

$commonArgs = @{
    RootPath       = $sandbox
    Drive          = 'T'
    SkipRecycleBin = $true
    OutDir         = $outDir
    LocalRulesPath = $localRules
    Quiet          = $true
}

# --- T1 / T2 / T3 / T5: 扫描 -------------------------------------------------
Write-Section 'T1-T5 只读扫描（Mode=Scan）'

$before = Get-FileMap -Path $sandbox
Invoke-Entry -Args ($commonArgs + @{ Mode = 'Scan' }) | Out-Null
$after = Get-FileMap -Path $sandbox

$diff = Compare-FileMap -Before $before -After $after -Label 'scan'
Test-Assert -Name 'T1 Scan 模式零删除、零新增' -Condition $diff.Clean `
    -Detail ('删除 ' + $diff.Removed.Count + ' 个 / 新增 ' + $diff.Added.Count + ' 个')

$report = Get-LatestReport
Test-Assert -Name 'T1b 扫描报告已生成且为 scan 类型' -Condition ($null -ne $report -and $report.ReportKind -eq 'scan') `
    -Detail '未找到 JSON 报告或类型不对'

if ($report) {
    $candPaths = @()
    foreach ($it in $report.Items) { $candPaths += $it.Path }

    $missed = @()
    foreach ($p in $expect.mustBeCandidates) {
        $hit = $false
        foreach ($cp in $candPaths) { if ($cp -ieq $p) { $hit = $true; break } }
        if (-not $hit) { $missed += $p }
    }
    Test-Assert -Name ('T2 白名单目标全部被识别为候选（共 ' + @($expect.mustBeCandidates).Count + ' 项）') `
        -Condition ($missed.Count -eq 0) -Detail ('漏掉: ' + ($missed -join ' | '))

    $leaked = @()
    foreach ($p in $expect.mustBeProtected) {
        foreach ($cp in $candPaths) {
            # 候选不得等于、也不得包含受保护路径
            if ($cp -ieq $p -or (Test-PathIsInside -Child $p -Parent $cp)) { $leaked += ($cp + ' ⊃ ' + $p); break }
        }
    }
    Test-Assert -Name ('T3 受保护诱饵一个都没有进入候选（共 ' + @($expect.mustBeProtected).Count + ' 项）') `
        -Condition ($leaked.Count -eq 0) -Detail ($leaked -join ' | ')

    $linkLeaked = @()
    foreach ($p in $expect.mustBeBlockedByLink) {
        foreach ($cp in $candPaths) { if ($cp -ieq $p) { $linkLeaked += $cp; break } }
    }
    Test-Assert -Name 'T4a 目录联接本身不是候选' -Condition ($linkLeaked.Count -eq 0) -Detail ($linkLeaked -join ' | ')

    $linkBlocked = 0
    foreach ($s in $report.ProtectionHits) { if ($s.Code -eq 'P_LINK') { $linkBlocked++ } }
    Test-Assert -Name 'T4b 存在被 P_LINK 拦截的记录（字面规则直指链接）' -Condition ($linkBlocked -ge 1) `
        -Detail ('P_LINK 命中 ' + $linkBlocked + ' 次')

    $tooNewCodes = @()
    foreach ($s in $report.SkippedTooNew) { $tooNewCodes += $s.Path }
    $freshDir = Join-Path $sandbox 'fresh\npm-cache'
    $freshHit = $false
    foreach ($p in $tooNewCodes) { if ($p -ieq $freshDir) { $freshHit = $true; break } }
    Test-Assert -Name 'T5 未达年龄阈值的"新鲜缓存"被跳过' -Condition $freshHit -Detail ('实际跳过: ' + ($tooNewCodes -join ' | '))

    Test-Assert -Name 'T3b 保护拦截总数大于 0（安全防线确实在工作）' `
        -Condition ((Get-CleanerCount $report.ProtectionHits) -gt 0) -Detail ('拦截数 = ' + (Get-CleanerCount $report.ProtectionHits))

    # 深度覆盖：真实缓存路径很深，默认 MaxDepth 必须够用，否则会静默漏掉缓存
    $truncN = Get-CleanerCount $report.Truncated
    Test-Assert -Name 'T2b 未发生深度截断（默认 MaxDepth 足以覆盖深层缓存）' `
        -Condition ($truncN -eq 0) -Detail ('截断数 = ' + $truncN)

    $chromeCache = Join-Path $sandbox 'Users\tester\AppData\Local\Google\Chrome\User Data\Default\Cache'
    $deepHit = $false
    foreach ($cp in $candPaths) { if ($cp -ieq $chromeCache) { $deepHit = $true; break } }
    Test-Assert -Name 'T2c 9 层深的浏览器缓存路径能进入候选' -Condition $deepHit `
        -Detail ('未命中: ' + $chromeCache)
}

# --- T6: 保护裁决单元测试 ---------------------------------------------------
Write-Section 'T6 保护裁决单元测试'

$protection = Import-CleanerProtection -ProtectedPath (Join-Path $root 'config\protected.default.json') `
    -RootPath $sandbox -DriveLetter 'T'

$v1 = Test-CleanerTargetAllowed -Path $sandbox -RootPath $sandbox -Protection $protection -TargetType 'directory'
Test-Assert -Name 'T6a 根目录被拒绝 (E_ROOT)' -Condition ($v1.Code -eq 'E_ROOT') -Detail ('实际 ' + $v1.Code)

$v2 = Test-CleanerTargetAllowed -Path (Join-Path $sandbox 'npm-cache') -RootPath $sandbox -Protection $protection -TargetType 'directory'
Test-Assert -Name 'T6b junction 被拒绝 (P_LINK)' -Condition ($v2.Code -eq 'P_LINK') -Detail ('实际 ' + $v2.Code + ' / ' + $v2.Reason)

    $v3 = Test-CleanerTargetAllowed -Path (Join-Path $sandbox 'data\app.sqlite') `
        -RootPath $sandbox -Protection $protection -TargetType 'file'
    Test-Assert -Name 'T6c 受保护扩展名被拒绝 (P_EXT)' -Condition ($v3.Code -eq 'P_EXT') -Detail ('实际 ' + $v3.Code)

    $v3b = Test-CleanerTargetAllowed -Path (Join-Path $sandbox 'Users\tester\Documents\important.docx') `
        -RootPath $sandbox -Protection $protection -TargetType 'file'
    Test-Assert -Name 'T6c2 用户文档里的文件被拒绝（扩展名或路径段，二者任一即可）' `
        -Condition ($v3b.Code -in @('P_EXT', 'P_SEGMENT', 'P_NAME')) -Detail ('实际 ' + $v3b.Code)

$v4 = Test-CleanerTargetAllowed -Path (Join-Path $sandbox 'Users\tester\Documents') `
    -RootPath $sandbox -Protection $protection -TargetType 'directory'
Test-Assert -Name 'T6d 用户文档目录被拒绝 (P_NAME/P_SEGMENT)' `
    -Condition ($v4.Code -eq 'P_NAME' -or $v4.Code -eq 'P_SEGMENT') -Detail ('实际 ' + $v4.Code)

$v5 = Test-CleanerTargetAllowed -Path (Join-Path $sandbox '..\..\Windows\System32') `
    -RootPath $sandbox -Protection $protection -TargetType 'directory'
Test-Assert -Name 'T6e 沙箱外路径被拒绝 (E_OUTSIDE/P_PATH)' `
    -Condition ($v5.Code -eq 'E_OUTSIDE' -or $v5.Code -eq 'P_PATH') -Detail ('实际 ' + $v5.Code)

$v6 = Test-CleanerTargetAllowed -Path (Join-Path $sandbox 'Temp') -RootPath $sandbox -Protection $protection -TargetType 'directory'
Test-Assert -Name 'T6f 合法白名单目标被放行 (OK)' -Condition ($v6.Code -eq 'OK') -Detail ('实际 ' + $v6.Code)

$v7 = Test-CleanerTargetAllowed -Path (Join-Path $sandbox 'projects\myapp\node_modules') `
    -RootPath $sandbox -Protection $protection -TargetType 'directory'
Test-Assert -Name 'T6g node_modules 被拒绝' -Condition (-not $v7.Allowed) -Detail ('实际 ' + $v7.Code)

# --- T7: Clean + DryRun -----------------------------------------------------
Write-Section 'T7 清理预演（Mode=Clean -DryRun）'

$before7 = Get-FileMap -Path $sandbox
Invoke-Entry -Args ($commonArgs + @{ Mode = 'Clean'; DryRun = $true; Yes = $true }) | Out-Null
$after7 = Get-FileMap -Path $sandbox
$diff7 = Compare-FileMap -Before $before7 -After $after7 -Label 'dryrun'
Test-Assert -Name 'T7 DryRun 不删除任何文件' -Condition $diff7.Clean `
    -Detail ('删除 ' + $diff7.Removed.Count + ' 个 / 新增 ' + $diff7.Added.Count + ' 个')

# --- T8: Clean + Permanent --------------------------------------------------
Write-Section 'T8 实际清理（Mode=Clean -DeleteMethod Permanent）'

$outsideBefore = Get-FileMap -Path (Join-Path $PSScriptRoot '.outside-target')
$linkedBefore = Get-FileMap -Path (Join-Path $PSScriptRoot '.linked-target')
$before8 = Get-FileMap -Path $sandbox

Invoke-Entry -Args ($commonArgs + @{ Mode = 'Clean'; DeleteMethod = 'Permanent'; Yes = $true }) | Out-Null

$after8 = Get-FileMap -Path $sandbox
$diff8 = Compare-FileMap -Before $before8 -After $after8 -Label 'clean'

$keepIntact = $true
$keepDetail = @()
foreach ($p in $expect.mustBeProtected) {
    if (-not (Test-Path -LiteralPath $p)) { $keepIntact = $false; $keepDetail += $p }
}
Test-Assert -Name 'T8a 所有受保护诱饵在清理后依然存在' -Condition $keepIntact -Detail ($keepDetail -join ' | ')

$outsideAfter = Get-FileMap -Path (Join-Path $PSScriptRoot '.outside-target')
$linkedAfter = Get-FileMap -Path (Join-Path $PSScriptRoot '.linked-target')
$dOut = Compare-FileMap -Before $outsideBefore -After $outsideAfter -Label 'outside'
$dLink = Compare-FileMap -Before $linkedBefore -After $linkedAfter -Label 'linked'
Test-Assert -Name 'T8b 沙箱外（junction 指向）的内容零变化' -Condition ($dOut.Clean -and $dLink.Clean) `
    -Detail ('outside 变化 ' + $dOut.Removed.Count + '/' + $dOut.Added.Count + '，linked 变化 ' + $dLink.Removed.Count + '/' + $dLink.Added.Count)

$deletedSomething = ($diff8.Removed.Count -gt 0)
Test-Assert -Name 'T8c 确实删除了白名单内的内容（工具不是空转）' -Condition $deletedSomething `
    -Detail ('删除 ' + $diff8.Removed.Count + ' 个文件')

$freshStillThere = Test-Path -LiteralPath (Join-Path $sandbox 'fresh\npm-cache\_cacache\newblob')
Test-Assert -Name 'T8d 未达年龄阈值的缓存清理后仍然存在' -Condition $freshStillThere -Detail 'fresh/npm-cache 被误删'

$keepMeThere = Test-Path -LiteralPath (Join-Path $sandbox 'KeepMe\keep.bin')
Test-Assert -Name 'T8e 与规则无关的普通目录未被触碰' -Condition $keepMeThere -Detail 'KeepMe 被误删'

# --- T10: 类型校验 / 过宽模式 / 执行前复查 -----------------------------------
Write-Section 'T10 类型校验、过宽白名单告警与执行前复查（TOCTOU 防护）'

# T10a/b: 规则声明的 targetType 必须与目标实际类型一致
$vA = Test-CleanerTargetAllowed -Path (Join-Path $sandbox 'data\app.sqlite') `
    -RootPath $sandbox -Protection $protection -TargetType 'directory'
Test-Assert -Name 'T10a 规则声明目录、目标实际是文件 → 拒绝 (E_TYPE)' `
    -Condition ($vA.Code -eq 'E_TYPE') -Detail ('实际 ' + $vA.Code + ' / ' + $vA.Reason)

$vB = Test-CleanerTargetAllowed -Path (Join-Path $sandbox 'KeepMe') `
    -RootPath $sandbox -Protection $protection -TargetType 'file'
Test-Assert -Name 'T10b 规则声明文件、目标实际是目录 → 拒绝 (E_TYPE)' `
    -Condition ($vB.Code -eq 'E_TYPE') -Detail ('实际 ' + $vB.Code + ' / ' + $vB.Reason)

# T10c: 过宽白名单判定
Test-Assert -Name 'T10c1 {ROOT}\** 被判为过宽模式' `
    -Condition (Test-CleanerPatternIsOverlyBroad -Pattern ($sandbox + '\**') -RootPath $sandbox) `
    -Detail '未识别出过宽模式'
Test-Assert -Name 'T10c2 {ROOT}\**\npm-cache 不算过宽（有字面量锚点）' `
    -Condition (-not (Test-CleanerPatternIsOverlyBroad -Pattern ($sandbox + '\**\npm-cache') -RootPath $sandbox)) `
    -Detail '误报'
Test-Assert -Name 'T10c3 纯字面路径不算过宽' `
    -Condition (-not (Test-CleanerPatternIsOverlyBroad -Pattern ($sandbox + '\Temp') -RootPath $sandbox)) `
    -Detail '误报'

# T10d: 执行前复查必须重跑完整保护裁决
$t10dir = Join-Path $sandbox 't10-protected-after-scan'
New-Item -ItemType Directory -Path $t10dir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $t10dir 'f.txt') -Value 'x' -Encoding UTF8

$protBlock = [pscustomobject]@{
    NeverTouchPaths         = (@($protection.NeverTouchPaths) + @($t10dir))
    NeverTouchDirNames      = $protection.NeverTouchDirNames
    NeverTouchPathSegments  = $protection.NeverTouchPathSegments
    NeverTouchExtensions    = $protection.NeverTouchExtensions
    NeverTouchExtExceptions = $protection.NeverTouchExtExceptions
    PruneDirNames           = $protection.PruneDirNames
}
$candD = [pscustomobject]@{
    RuleId = 't10'; RuleName = 'T10 复查'; Category = 'TEST'; Risk = 'low'
    Path = $t10dir; Type = 'directory'; AgeDays = 1; MinAge = 0
    Bytes = 1; Files = 1; Dirs = 0; Note = ''; IsSpecial = $false
}
$resD = Invoke-CleanerClean -Candidates @($candD) -DriveLetter 'T' -DeleteMethod 'Permanent' `
    -RootPath $sandbox -Protection $protBlock
$rD = $resD.Results[0]
Test-Assert -Name 'T10d 执行前复查重跑保护裁决：新命中保护的候选被跳过且文件仍在' `
    -Condition ($rD.Status -eq 'Skipped' -and (Test-Path -LiteralPath $t10dir)) `
    -Detail ('status=' + $rD.Status + ' 仍存在=' + (Test-Path -LiteralPath $t10dir) + ' err=' + $rD.Error)

# 对照：同一候选在不加保护时必须能被正常删除，否则 T10d 可能只是"工具空转"
$t10dir2 = Join-Path $sandbox 't10-clean-target'
New-Item -ItemType Directory -Path $t10dir2 -Force | Out-Null
Set-Content -LiteralPath (Join-Path $t10dir2 'f.txt') -Value 'x' -Encoding UTF8
$candD2 = [pscustomobject]@{
    RuleId = 't10'; RuleName = 'T10 复查'; Category = 'TEST'; Risk = 'low'
    Path = $t10dir2; Type = 'directory'; AgeDays = 1; MinAge = 0
    Bytes = 1; Files = 1; Dirs = 0; Note = ''; IsSpecial = $false
}
$resD2 = Invoke-CleanerClean -Candidates @($candD2) -DriveLetter 'T' -DeleteMethod 'Permanent' `
    -RootPath $sandbox -Protection $protection
$rD2 = $resD2.Results[0]
Test-Assert -Name 'T10d2 对照：未命中保护的候选仍能正常删除（证明 T10d 不是空转）' `
    -Condition ($rD2.Status -eq 'Deleted' -and -not (Test-Path -LiteralPath $t10dir2)) `
    -Detail ('status=' + $rD2.Status + ' 仍存在=' + (Test-Path -LiteralPath $t10dir2) + ' err=' + $rD2.Error)

# T10e: 被独占的文件应被跳过并保留
$lockPath = Join-Path $sandbox 't10-locked.txt'
Set-Content -LiteralPath $lockPath -Value 'x' -Encoding UTF8
$fs = $null
try {
    $fs = [System.IO.File]::Open($lockPath,
        [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $candE = [pscustomobject]@{
        RuleId = 't10'; RuleName = 'T10 占用'; Category = 'TEST'; Risk = 'low'
        Path = $lockPath; Type = 'file'; AgeDays = 1; MinAge = 0
        Bytes = 1; Files = 1; Dirs = 0; Note = ''; IsSpecial = $false
    }
    $resE = Invoke-CleanerClean -Candidates @($candE) -DriveLetter 'T' -DeleteMethod 'Permanent' `
        -RootPath $sandbox -Protection $protection
    $rE = $resE.Results[0]
    Test-Assert -Name 'T10e 被其它进程独占的文件被跳过且保留下来' `
        -Condition ($rE.Status -eq 'Skipped' -and (Test-Path -LiteralPath $lockPath)) `
        -Detail ('status=' + $rE.Status + ' 仍存在=' + (Test-Path -LiteralPath $lockPath) + ' err=' + $rE.Error)
}
finally {
    if ($fs) { $fs.Close(); $fs.Dispose() }
}

# --- T11: 桌面界面（Worker 桥接层）安全性 ------------------------------------
Write-Section 'T11 界面桥接层：只能收窄候选集，不能扩张'

. (Join-Path $root 'app\Worker.ps1')

$guiSandbox = Join-Path $PSScriptRoot '.gui-sandbox'
Remove-PathSafe -Path $guiSandbox

# 局部助手：New-Sandbox.ps1 里的 New-BigFile 等不会外泄到本脚本作用域
function New-GuiTestFile {
    param([string]$Path, [int]$KB = 8)
    $d = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] ($KB * 1024)))
}

$gTemp = Join-Path $guiSandbox 'Temp'
$gNpm = Join-Path $guiSandbox 'cache\npm-cache'
$gDocs = Join-Path $guiSandbox 'Users\tester\Documents'
New-GuiTestFile -Path (Join-Path $gTemp 'junk.tmp') -KB 24
New-GuiTestFile -Path (Join-Path $gNpm '_cacache\blob') -KB 48
New-GuiTestFile -Path (Join-Path $gDocs 'important.docx') -KB 1

$gOld = (Get-Date).AddDays(-45)
Get-ChildItem -LiteralPath $guiSandbox -Recurse -Force -File | ForEach-Object { try { $_.LastWriteTime = $gOld; $_.CreationTime = $gOld } catch { } }
$gDirs = Get-ChildItem -LiteralPath $guiSandbox -Recurse -Force -Directory | Sort-Object { $_.FullName.Split('\').Count } -Descending
foreach ($d in $gDirs) { try { $d.LastWriteTime = $gOld; $d.CreationTime = $gOld } catch { } }
$gRootInfo = [System.IO.DirectoryInfo]::new($guiSandbox); $gRootInfo.LastWriteTime = $gOld; $gRootInfo.CreationTime = $gOld

$gCommon = @{
    RootPath = $guiSandbox
    DriveLetter = 'T'
    MaxDepth = 10
    OutDir = $outDir
    SkipRecycleBin = $true
}

# T11a: Worker 扫描结果应与引擎自身扫描一致
$wScan = Invoke-CleanerAppTask @gCommon -Mode 'Scan'
Test-Assert -Name 'T11a1 Worker 扫描成功' -Condition ($wScan.Ok) -Detail ('Ok=' + $wScan.Ok + ' err=' + $wScan.Error)

$wPaths = @()
foreach ($c in $wScan.Candidates) { $wPaths += [string]$c.Path }
$hasTemp = $false; $hasNpm = $false; $hasDocs = $false
foreach ($p in $wPaths) {
    if ($p -ieq $gTemp) { $hasTemp = $true }
    if ($p -ieq $gNpm) { $hasNpm = $true }
    if ($p -ieq $gDocs) { $hasDocs = $true }
}
Test-Assert -Name 'T11a2 Worker 候选集包含白名单目标' -Condition ($hasTemp -and $hasNpm) -Detail ('temp=' + $hasTemp + ' npm=' + $hasNpm)
Test-Assert -Name 'T11a3 Worker 候选集不含受保护诱饵（Documents）' -Condition (-not $hasDocs) -Detail 'Documents 进了候选集'

# T11b: 越权路径必须被并集逻辑丢弃
$system32 = Join-Path $env:SystemRoot 'System32'
$only = @($gTemp, $system32, $gDocs)
$wClean = Invoke-CleanerAppTask @gCommon -Mode 'Clean' -OnlyPaths $only -DeleteMethod 'Permanent'

$wTempGone = -not (Test-Path -LiteralPath (Join-Path $gTemp 'junk.tmp'))
$wDocsAlive = Test-Path -LiteralPath (Join-Path $gDocs 'important.docx')
$wSystemAlive = Test-Path -LiteralPath $system32

Test-Assert -Name 'T11b1 界面传入的越权路径被并集逻辑丢弃（请求 3 项、实际命中 1 项）' `
    -Condition ($wClean.RequestedCount -eq 3 -and $wClean.MatchedCount -eq 1) `
    -Detail ('requested=' + $wClean.RequestedCount + ' matched=' + $wClean.MatchedCount)
Test-Assert -Name 'T11b2 白名单目标确实被删掉了（工具不是空转）' -Condition $wTempGone -Detail 'Temp 未被清理'
Test-Assert -Name 'T11b3 界面无法借越权路径删到系统目录' -Condition $wSystemAlive -Detail 'System32 受影响'
Test-Assert -Name 'T11b4 界面无法借越权路径删到受保护诱饵' -Condition $wDocsAlive -Detail 'Documents 被删了'

# T11c: Worker 仍会产出报告
Test-Assert -Name 'T11c Worker 产出了 HTML 报告' `
    -Condition ($wClean.HtmlReport -and (Test-Path -LiteralPath $wClean.HtmlReport)) `
    -Detail ('HtmlReport=' + $wClean.HtmlReport)

# T11d: 只传受保护路径时应当一项都命中不了
$wClean2 = Invoke-CleanerAppTask @gCommon -Mode 'Clean' -OnlyPaths @($gDocs, $system32) -DeleteMethod 'Permanent'
Test-Assert -Name 'T11d 只传受保护路径时命中 0 项且诱饵完好' `
    -Condition ($wClean2.MatchedCount -eq 0 -and (Test-Path -LiteralPath (Join-Path $gDocs 'important.docx'))) `
    -Detail ('matched=' + $wClean2.MatchedCount)

Remove-PathSafe -Path $guiSandbox

# --- 报告 -------------------------------------------------------------------
Write-Section 'T9 报告产物'

$html = Get-ChildItem -LiteralPath $outDir -Filter '*.html' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
Test-Assert -Name 'T9a HTML 报告已生成' -Condition ($null -ne $html) -Detail '未找到 HTML 报告'

if ($html) {
    $htmlText = Get-Content -LiteralPath $html.FullName -Raw -Encoding UTF8
    Test-Assert -Name 'T9b HTML 报告非空且含结论区块' `
        -Condition ($htmlText.Length -gt 2000 -and $htmlText.Contains('安全防线记录')) `
        -Detail ('长度 ' + $htmlText.Length)
}

$latest = Join-Path $outDir 'latest.html'
Test-Assert -Name 'T9c latest.html 已生成' -Condition (Test-Path -LiteralPath $latest) -Detail '未找到 latest.html'

$log = Get-ChildItem -LiteralPath $outDir -Filter '*.log' -ErrorAction SilentlyContinue | Select-Object -First 1
Test-Assert -Name 'T9d 运行日志已生成' -Condition ($null -ne $log) -Detail '未找到日志文件'

# 回归守卫：PS 5.1 下用 New-Object 'object[]' N 构造的数组会被序列化成
# {"value":[...],"Count":N}，下游 JSON 消费者会读不到数组。这里守住它。
$jsonFile = Get-ChildItem -LiteralPath $outDir -Filter '*.json' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($jsonFile) {
    $rawJson = Get-Content -LiteralPath $jsonFile.FullName -Raw -Encoding UTF8
    Test-Assert -Name 'T9e JSON 报告里的数组字段没有被 {value,Count} 包装' `
        -Condition (-not ($rawJson -match '"value"\s*:')) `
        -Detail '发现 {"value":...} 包装，说明集合被 PSObject 包住了，下游读不到数组'
}
else {
    Test-Assert -Name 'T9e JSON 报告存在' -Condition $false -Detail '未找到 JSON 报告'
}

$lst = New-Object System.Collections.Generic.List[object]
[void]$lst.Add([pscustomobject]@{ a = 1 })
$convJson = @{ k = (ConvertTo-CleanerArray $lst) } | ConvertTo-Json -Compress -Depth 4
Test-Assert -Name 'T9f ConvertTo-CleanerArray 的输出能被序列化为标准数组' `
    -Condition ($convJson -eq '{"k":[{"a":1}]}') -Detail ('实际 ' + $convJson)

$emptyJson = @{ k = (ConvertTo-CleanerArray (New-Object System.Collections.Generic.List[object])) } | ConvertTo-Json -Compress
Test-Assert -Name 'T9g 空集合归一化后序列化为 []' `
    -Condition ($emptyJson -eq '{"k":[]}') -Detail ('实际 ' + $emptyJson)

# 「可清理容量占该盘总容量」的百分比。
# 沙箱位于 D: 上，所以卷容量应当能取到；断言百分比确实等于 round(可清理/卷容量*100, 1)，
# 而不是只断言字段存在（那种断言字段恒为空也能过）。
if ($jsonFile) {
    $rep = Get-Content -LiteralPath $jsonFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $volTotal = Get-CleanerVolumeTotalBytes -Path $rep.RootPath
    Test-Assert -Name 'T9h 报告记录了该盘总容量' `
        -Condition ($null -ne $rep.DriveTotalBytes -and [long]$rep.DriveTotalBytes -gt 0) `
        -Detail ('DriveTotalBytes = ' + $rep.DriveTotalBytes + '  卷探测 = ' + $volTotal)

    # 独立复算（不调用被测助手），确保不是「用同一个实现算出来自己跟自己比」
    $wantPct = [math]::Round([double]$rep.TotalBytes / [double]$rep.DriveTotalBytes * 100, 1)
    Test-Assert -Name 'T9i 占比 = 可清理容量 / 该盘总容量（一位小数）' `
        -Condition ($null -ne $rep.CleanablePercent -and [double]$rep.CleanablePercent -eq $wantPct) `
        -Detail ('报告 ' + $rep.CleanablePercent + '  独立复算 ' + $wantPct)
    Test-Assert -Name 'T9i1 记录到的卷容量是个合理的量级（1GB ~ 100TB）' `
        -Condition ([double]$rep.DriveTotalBytes -gt 1GB -and [double]$rep.DriveTotalBytes -lt 100TB) `
        -Detail ('DriveTotalBytes = ' + $rep.DriveTotalBytes)

    # 反空转对照：占比必须随输入变化，不是写死的常量。
    # 注意别写成「报告里的值必须 > 0」—— 沙箱跑在真实的 D: 盘上，
    # 几 KB 的沙箱占 931 GB，四舍五入后本来就是 0.0%，那种断言是错的。
    $pA = Get-CleanerSharePercent -Part 25 -Total 100
    $pB = Get-CleanerSharePercent -Part 1 -Total 3
    $pC = Get-CleanerSharePercent -Part 0 -Total 100
    Test-Assert -Name 'T9i2 占比随输入变化（排除写死/恒定的假实现）' `
        -Condition ($pA -eq 25 -and $pB -eq 33.3 -and $pC -eq 0) `
        -Detail ('25/100=' + $pA + '  1/3=' + $pB + '  0/100=' + $pC)

    if ($html) {
        Test-Assert -Name 'T9j HTML 报告里有「占该盘容量」卡片，且数值与 JSON 一致' `
            -Condition ($htmlText.Contains('占该盘容量') -and $htmlText.Contains((Format-Percent $rep.CleanablePercent))) `
            -Detail ('找不到卡片或数值，期望 ' + (Format-Percent $rep.CleanablePercent))
    }
}

# 卷容量取不到时的契约：返回 $null，绝不返回 0 —— 否则报告会写成「占该盘 0.0%」，
# 看着像个正常数字，实际是没测出来。显示层统一退化为 "—"。
Test-Assert -Name 'T9k2 卷容量无效时占比返回 $null（不出现除零或 0%）' `
    -Condition ($null -eq (Get-CleanerSharePercent -Part 100 -Total $null) -and
        $null -eq (Get-CleanerSharePercent -Part 100 -Total 0)) `
    -Detail 'Total 为 $null / 0 时应返回 $null'
Test-Assert -Name 'T9k3 Format-Percent 对 $null 显示占位符而不是 0.0%' `
    -Condition ((Format-Percent $null) -eq '—' -and (Format-Percent 4.7) -eq '4.7%') `
    -Detail ('null -> ' + (Format-Percent $null) + '  4.7 -> ' + (Format-Percent 4.7))

# --- 收尾 -------------------------------------------------------------------
Write-Host ''
Write-Host '############################################################' -ForegroundColor White
$total = $script:Pass + $script:Fail
if ($script:Fail -eq 0) {
    Write-Host (" 全部通过：$($script:Pass)/$total") -ForegroundColor Green
}
else {
    Write-Host (" 通过 $($script:Pass)/$total，失败 $($script:Fail)") -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host ('   - ' + $f) -ForegroundColor Red }
}
Write-Host '############################################################' -ForegroundColor White
Write-Host ''

if (-not $KeepSandbox) {
    Write-Host '清理沙箱...' -ForegroundColor DarkGray
    Remove-PathSafe -Path $sandbox
    Remove-PathSafe -Path (Join-Path $PSScriptRoot '.outside-target')
    Remove-PathSafe -Path (Join-Path $PSScriptRoot '.linked-target')
}

try { Stop-Transcript | Out-Null } catch { }

if ($script:Fail -gt 0) { exit 1 }
exit 0
