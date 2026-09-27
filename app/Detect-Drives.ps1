#Requires -Version 5.1
<#
.SYNOPSIS
    枚举本机真实存在的驱动器，生成 app/ui.html 可直接消费的 drives.json。

.DESCRIPTION
    只输出 IsReady = $true 的驱动器。不存在的盘符、空光驱、未插卡的读卡器
    一律不写出 —— 界面据此「只标存在的盘，没有的不标」。

    用法：
        .\Detect-Drives.ps1                    # 写到同目录的 drives.json
        .\Detect-Drives.ps1 -OutPath X.json    # 自定义输出路径

    产出后通过本地 HTTP 服务打开 app/ui.html，界面启动会自动读取该文件；
    若直接双击 ui.html（file://），浏览器会拒绝读取该文件，界面退化为
    「页面所在盘」这一条真实检测结果，仍然不会列出不存在的盘。

.PARAMETER OutPath
    输出 JSON 路径，默认为脚本所在目录下的 drives.json。

.EXAMPLE
    .\Detect-Drives.ps1
    检测本机驱动器并写出 drives.json。
#>
[CmdletBinding()]
param(
    [string]$OutPath
)

$ErrorActionPreference = 'Stop'
if (-not $OutPath) { $OutPath = Join-Path $PSScriptRoot 'drives.json' }

function ConvertTo-DriveKind {
    param([System.IO.DriveInfo]$D)
    switch ($D.DriveType) {
        ([System.IO.DriveType]::Fixed)     { return 'fixed' }
        ([System.IO.DriveType]::Removable) { return 'removable' }
        ([System.IO.DriveType]::Network)   { return 'network' }
        ([System.IO.DriveType]::CDRom)     { return 'cdrom' }
        ([System.IO.DriveType]::Ram)       { return 'ram' }
        default                            { return 'unknown' }
    }
}

$drives = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[string]

foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
    $name = [string]$d.Name                       # 形如 "D:\"
    if ($name.Length -lt 2) { continue }
    $letter = $name.Substring(0, 1).ToUpperInvariant()
    if ($letter -notmatch '^[A-Z]$') { continue }

    $ready = $false
    try { $ready = [bool]$d.IsReady } catch { $ready = $false }
    if (-not $ready) {
        # 关键：未就绪的（不存在的盘 / 空光驱 / 未插卡读卡器）不输出
        $k = 'unknown'
        try { $k = (ConvertTo-DriveKind -D $d) } catch { }
        $skipped.Add($letter + ':\ (' + $k + ')')
        continue
    }

    $total  = [long]0
    $free   = [long]0
    $label  = ''
    $format = ''
    try { $total  = [long]$d.TotalSize }          catch { }
    try { $free   = [long]$d.AvailableFreeSpace } catch { }
    try { $label  = [string]$d.VolumeLabel }      catch { }
    try { $format = [string]$d.DriveFormat }      catch { }

    $drives.Add([pscustomobject]@{
        letter     = $letter
        root       = $letter + ':\'
        kind       = (ConvertTo-DriveKind -D $d)
        label      = $label
        format     = $format
        totalBytes = $total
        freeBytes  = $free
    })
}

# ---------------------------------------------------------------------------
# 手工拼 JSON。
# 不要用 ConvertTo-Json 序列化整个对象：PS 5.1 下「只有 1 个元素的数组」
# 会被序列化成对象而不是数组，下游 Array.isArray 直接判否（本项目踩过同款坑）。
# ---------------------------------------------------------------------------
$utf8n = New-Object System.Text.UTF8Encoding($false)
$enc   = { param($v) ($v | ConvertTo-Json -Compress) }

$itemJson = @()
foreach ($x in $drives) { $itemJson += ('  ' + (& $enc $x)) }
$arrJson  = if ($itemJson.Count -eq 0) { '[]' } else { "[`r`n" + ($itemJson -join ",`r`n") + "`r`n]" }

$json = @"
{
  "schemaVersion": "1.0",
  "source": "detected",
  "generatedAt": $(& $enc ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))),
  "host": $(& $enc ([string]$env:COMPUTERNAME)),
  "drives": $arrJson
}
"@

[System.IO.File]::WriteAllText($OutPath, $json, $utf8n)

# 同时写出 drives.js。这一份才是「双击 ui.html 即可用」的关键：
# file:// 下 fetch('drives.json') 会被 CORS 拒掉，但普通脚本标签能正常加载同目录文件。
# 这里刻意用 UTF-8 **带 BOM**：外部脚本的编码若无法从 HTTP 头判定，浏览器可能按
# 文档/系统编码去猜，卷标里的中文就会乱码。JSON 那份仍用无 BOM（很多解析器不容忍）。
$jsPath = [System.IO.Path]::ChangeExtension($OutPath, 'js')
[System.IO.File]::WriteAllText($jsPath, ('window.__SDC_DRIVES__ = ' + $json + ';' + "`r`n"), $utf8b)

Write-Host ''
Write-Host ('检测到 ' + $drives.Count + ' 个可用驱动器') -ForegroundColor Cyan
foreach ($x in $drives) {
    $cap = '可用 ' + [math]::Round($x.freeBytes / 1GB, 1) + ' GB / ' + [math]::Round($x.totalBytes / 1GB, 1) + ' GB'
    $tag = if ($x.label) { '  ' + $x.label } else { '' }
    Write-Host ('  ' + $x.root.PadRight(5) + $x.kind.PadRight(11) + $cap + $tag)
}
if ($skipped.Count -gt 0) {
    Write-Host ''
    Write-Host ('已跳过 ' + $skipped.Count + ' 个未就绪项（不会写进 JSON）：' + ($skipped -join ', ')) -ForegroundColor DarkGray
}
Write-Host ''
Write-Host ('已写出 → ' + $OutPath) -ForegroundColor Green
Write-Host ('已写出 → ' + $jsPath) -ForegroundColor Green
