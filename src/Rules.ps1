# ============================================================================
#  Rules.ps1 - 规则与保护配置的加载、合并与裁决
#  SafeDriveCleaner
# ============================================================================
#Requires -Version 5.1

<#
.SYNOPSIS
    展开配置中的 {ROOT} / {DRIVE} 占位符与环境变量。
#>
function Expand-CleanerPlaceholder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$DriveLetter
    )

    $rootNoSlash = $RootPath.TrimEnd('\')
    $v = $Value
    $v = $v.Replace('{ROOT}', $rootNoSlash)
    $v = $v.Replace('{DRIVE}', $DriveLetter)
    $v = [System.Environment]::ExpandEnvironmentVariables($v)
    return $v
}

<#
.SYNOPSIS
    读取 rules.default.json + rules.local.json 并合并（按 id 覆盖），返回规则数组。
#>
function Import-CleanerRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RulesPath,
        [string]$LocalRulesPath,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$DriveLetter
    )

    if (-not (Test-Path -LiteralPath $RulesPath)) {
        throw "规则文件不存在: $RulesPath"
    }

    $base = Get-Content -LiteralPath $RulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rules = @()
    foreach ($r in $base.rules) { $rules += $r }

    if ($LocalRulesPath -and (Test-Path -LiteralPath $LocalRulesPath)) {
        $local = Get-Content -LiteralPath $LocalRulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($lr in $local.rules) {
            $existing = $rules | Where-Object { $_.id -eq $lr.id }
            if ($existing) {
                $idx = [array]::IndexOf($rules, $existing[0])
                # 逐字段覆盖：local 中出现的字段生效，未出现的保留默认值
                foreach ($prop in $lr.PSObject.Properties) {
                    if ($prop.Name -eq 'id') { continue }
                    if ($existing[0].PSObject.Properties[$prop.Name]) {
                        $existing[0].PSObject.Properties[$prop.Name].Value = $prop.Value
                    }
                    else {
                        $existing[0] | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
                    }
                }
                $rules[$idx] = $existing[0]
            }
            else {
                $rules += $lr
            }
        }
    }

    # 展开占位符 + 补全缺省字段
    foreach ($r in $rules) {
        $newPatterns = @()
        foreach ($p in $r.patterns) {
            $newPatterns += (Expand-CleanerPlaceholder -Value $p -RootPath $RootPath -DriveLetter $DriveLetter)
        }
        $r.patterns = $newPatterns

        if (-not $r.PSObject.Properties['minAgeDays']) {
            $r | Add-Member -NotePropertyName 'minAgeDays' -NotePropertyValue 0 -Force
        }
        if ((-not $r.PSObject.Properties['targetType']) -or [string]::IsNullOrWhiteSpace($r.targetType)) {
            $r | Add-Member -NotePropertyName 'targetType' -NotePropertyValue 'directory' -Force
        }
        if (-not $r.PSObject.Properties['enabled']) {
            $r | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $true -Force
        }
        if (-not $r.PSObject.Properties['risk']) {
            $r | Add-Member -NotePropertyName 'risk' -NotePropertyValue 'unknown' -Force
        }
        if (-not $r.PSObject.Properties['category']) {
            $r | Add-Member -NotePropertyName 'category' -NotePropertyValue '未分类' -Force
        }
    }

    return , $rules
}

<#
.SYNOPSIS
    读取保护配置并展开占位符。
#>
function Import-CleanerProtection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProtectedPath,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$DriveLetter
    )

    if (-not (Test-Path -LiteralPath $ProtectedPath)) {
        throw "保护配置不存在: $ProtectedPath"
    }

    $cfg = Get-Content -LiteralPath $ProtectedPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $paths = @()
    foreach ($p in $cfg.neverTouchPaths) {
        $expanded = Get-NormalizedPath (Expand-CleanerPlaceholder -Value $p -RootPath $RootPath -DriveLetter $DriveLetter)
        # 防御：neverTouchPaths 的语义是"等于或位于其下"，把根目录写进来会拦下全部候选，
        # 造成"扫描结果为空"的静默失效。根目录本身已由引擎硬编码拒绝（E_ROOT），这里直接剔除。
        if ($expanded.TrimEnd('\') -ieq (Get-NormalizedPath $RootPath).TrimEnd('\')) {
            Write-CLog ('保护配置中的 "' + $p + '" 展开后等于目标根目录，已自动剔除（根目录由引擎直接拒绝，写进保护清单会拦下所有候选）') 'WARN'
            continue
        }
        $paths += $expanded
    }

    return [pscustomobject]@{
        NeverTouchPaths         = $paths
        NeverTouchDirNames      = @($cfg.neverTouchDirectoryNames)
        NeverTouchPathSegments  = @($cfg.neverTouchPathSegments)
        NeverTouchExtensions    = @($cfg.neverTouchExtensions)
        NeverTouchExtExceptions = @($cfg.neverTouchExtExceptions)
        PruneDirNames           = @($cfg.pruneDirectoryNames)
    }
}

<#
.SYNOPSIS
    对单个候选目标做四道保护裁决。
    返回 @{ Allowed = bool; Code = string; Reason = string }
#>
function Test-CleanerTargetAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)]$Protection,
        [string]$TargetType = 'directory'
    )

    $deny = { param($code, $reason) return [pscustomobject]@{ Allowed = $false; Code = $code; Reason = $reason } }

    $norm = Get-NormalizedPath $Path
    $root = Get-NormalizedPath $RootPath

    if (-not $norm) { return (& $deny 'E_PATH' '路径为空或无法解析') }
    if (-not $root -or -not $root.EndsWith('\')) { $root = ($root.TrimEnd('\') + '\') }

    # 1. 必须是目标根之下的路径
    if ($norm.TrimEnd('\') -ieq $root.TrimEnd('\')) {
        return (& $deny 'E_ROOT' '目标是磁盘根目录本身，拒绝操作')
    }
    if (-not $norm.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return (& $deny 'E_OUTSIDE' ('目标不在本次清理范围内（根目录 ' + $root + '）'))
    }

    # 2. 目标自身存在性
    $exists = Test-Path -LiteralPath $norm
    if (-not $exists) { return (& $deny 'E_NOTEXIST' '路径不存在') }

    # 3. 具体保护路径（等于或位于其下）
    foreach ($p in $Protection.NeverTouchPaths) {
        if (Test-PathIsInside -Child $norm -Parent $p -AllowEqual) {
            return (& $deny 'P_PATH' ('命中保护路径 ' + $p))
        }
    }

    # 4. 目标叶子名保护
    $leaf = Split-Path -Leaf $norm
    foreach ($n in $Protection.NeverTouchDirNames) {
        if ($leaf -ieq $n) {
            return (& $deny 'P_NAME' ('目标是受保护的目录/文件名: ' + $leaf))
        }
    }

    # 5. 路径段保护（用户数据区）
    $seg = Test-PathHasProtectedSegment -Path $norm -Segments $Protection.NeverTouchPathSegments
    if ($seg) {
        return (& $deny 'P_SEGMENT' ('路径位于受保护区域: \' + $seg + '\'))
    }

    # 6. 扩展名保护（仅文件）
    if ($TargetType -eq 'file') {
        $ext = [System.IO.Path]::GetExtension($norm)
        $exempt = $false
        $leafName = [System.IO.Path]::GetFileName($norm)
        foreach ($e in $Protection.NeverTouchExtExceptions) {
            if ($leafName -ieq $e) { $exempt = $true; break }
        }
        if ($ext -and -not $exempt) {
            foreach ($e in $Protection.NeverTouchExtensions) {
                if ($ext -ieq $e) {
                    return (& $deny 'P_EXT' ('扩展名受保护: ' + $ext))
                }
            }
        }
    }

    # 7. 重解析点保护：目标本身或其在根之下的任一祖先为 junction / symlink
    if (Test-HasReparseAncestor -Path $norm -StopAt $root) {
        return (& $deny 'P_LINK' '目标是目录联接/符号链接（或位于其下），为防误删已跳过')
    }

    return [pscustomobject]@{ Allowed = $true; Code = 'OK'; Reason = '通过全部保护检查' }
}

<#
.SYNOPSIS
    按 -Categories / -IncludeRule / -ExcludeRule 过滤规则。
#>
function Select-CleanerRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Rules,
        [string[]]$Categories,
        [string[]]$IncludeRule,
        [string[]]$ExcludeRule,
        [switch]$IncludeDisabled
    )

    $out = @()
    foreach ($r in $Rules) {
        if (-not $IncludeDisabled -and -not $r.enabled) { continue }
        if ($IncludeRule -and $IncludeRule.Count -gt 0) {
            if ($IncludeRule -notcontains $r.id) { continue }
        }
        if ($Categories -and $Categories.Count -gt 0) {
            if ($Categories -notcontains $r.category) { continue }
        }
        if ($ExcludeRule -and $ExcludeRule.Count -gt 0) {
            if ($ExcludeRule -contains $r.id) { continue }
        }
        $out += $r
    }
    return , $out
}
