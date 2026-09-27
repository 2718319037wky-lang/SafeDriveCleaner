#Requires -Version 5.1
<#
.SYNOPSIS
    SafeDriveCleaner 桌面版 —— WinForms 主界面。

.DESCRIPTION
    界面本身**不含任何删除逻辑**。所有扫描与清理都通过 app\Worker.ps1 调用
    src\ 下那套已通过 39 项安全断言的引擎，并且：

      * 清理时界面只把**勾选的路径字符串**交给 Worker；
      * Worker 会重新完整扫描一遍，再与勾选结果取交集；
      * Invoke-CleanerClean 内部还会对每一条重跑完整保护裁决。

    因此界面能做的只有"从引擎算出的候选里减掉一些"，
    永远无法让引擎去删一个它自己不会产生的目标。

.PARAMETER Drive
    启动时默认选中的盘符。留空则自动选 D（不存在则选第一个固定盘）。

.PARAMETER SelfTest
    自检模式：只构建整个界面对象树然后立刻销毁，不显示窗口。
    用于在没有可视桌面环境时验证界面代码能否正常构造。
#>
[CmdletBinding()]
param(
    [string]$Drive = '',
    [switch]$AutoScan,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$script:AppRoot = Split-Path -Parent $PSScriptRoot           # SafeDriveCleaner\
$script:WorkerPath = Join-Path $PSScriptRoot 'Worker.ps1'

# 只为显示用的格式化函数（Format-Size / Get-CleanerCount），不含清理逻辑
. (Join-Path $script:AppRoot 'src\Common.ps1')
$script:CleanerQuiet = $true
$script:Version = $script:CleanerVersion   # 版本号单一来源，见 src\Common.ps1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[void][System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ---------------------------------------------------------------------------
# 主题
# ---------------------------------------------------------------------------
# 注意：PowerShell 变量名大小写不敏感。
# 调色板刻意命名为 $Pal / $Fonts 而不是 $C / $F ——
# 后者会被 foreach ($c ...) / ($f ...) 这类循环变量覆盖掉，造成极难定位的空值异常。
$Pal = @{
    Bg       = [System.Drawing.Color]::FromArgb(246, 247, 249)
    Card     = [System.Drawing.Color]::White
    Border   = [System.Drawing.Color]::FromArgb(224, 228, 233)
    Text     = [System.Drawing.Color]::FromArgb(31, 35, 40)
    Muted    = [System.Drawing.Color]::FromArgb(107, 114, 128)
    Accent   = [System.Drawing.Color]::FromArgb(37, 99, 235)
    AccentHv = [System.Drawing.Color]::FromArgb(29, 78, 216)
    OK       = [System.Drawing.Color]::FromArgb(4, 120, 87)
    Warn     = [System.Drawing.Color]::FromArgb(180, 83, 9)
    Danger   = [System.Drawing.Color]::FromArgb(185, 28, 28)
    Stripe   = [System.Drawing.Color]::FromArgb(250, 251, 252)
}

$fontName = 'Microsoft YaHei UI'
try { $null = New-Object System.Drawing.Font($fontName, 9) }
catch { $fontName = 'Segoe UI' }

$Fonts = @{
    Base   = New-Object System.Drawing.Font($fontName, 9)
    Small  = New-Object System.Drawing.Font($fontName, 8.5)
    Title  = New-Object System.Drawing.Font($fontName, 15, [System.Drawing.FontStyle]::Bold)
    Stat   = New-Object System.Drawing.Font($fontName, 14, [System.Drawing.FontStyle]::Bold)
    Button = New-Object System.Drawing.Font($fontName, 9)
}

$script:Job = $null
$script:TaskKind = ''
$script:Candidates = @()
$script:ScanResult = $null
$script:IsBusy = $false
$script:AllPaths = @()

# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------
function New-FlatButton {
    param(
        [string]$Text,
        [int]$Width = 96,
        [System.Drawing.Color]$Back,
        [System.Drawing.Color]$Fore,
        [System.Drawing.Color]$Hover
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Width = $Width
    $b.Height = 30
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Back
    $b.ForeColor = $Fore
    $b.Font = $Fonts.Button
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Hover -ne [System.Drawing.Color]::Empty) {
        $b.FlatAppearance.MouseOverBackColor = $Hover
    }
    $b.FlatAppearance.MouseDownBackColor = $Back
    return $b
}

function Set-Status {
    param([string]$Text, [string]$Tone = 'muted')
    $script:lblStatus.Text = $Text
    switch ($Tone) {
        'ok' { $script:lblStatus.ForeColor = $Pal.OK }
        'warn' { $script:lblStatus.ForeColor = $Pal.Warn }
        'err' { $script:lblStatus.ForeColor = $Pal.Danger }
        default { $script:lblStatus.ForeColor = $Pal.Muted }
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-FixedDrives {
    $out = @()
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            try {
                if ($d.DriveType -eq [System.IO.DriveType]::Fixed -and $d.IsReady) {
                    $out += $d.Name.Substring(0, 1)
                }
            }
            catch { }
        }
    }
    catch { }
    return , $out
}

function Format-CellSize {
    param($Bytes)
    if ($null -eq $Bytes) { return '' }
    return (Format-Size ([double]$Bytes))
}

# ---------------------------------------------------------------------------
# 主窗口
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'SafeDriveCleaner · 磁盘安全清理'
$form.Size = New-Object System.Drawing.Size(1020, 720)
$form.MinimumSize = New-Object System.Drawing.Size(900, 600)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Pal.Bg
$form.Font = $Fonts.Base
$form.ForeColor = $Pal.Text

$icoPath = Join-Path $PSScriptRoot 'assets\app.ico'
if (Test-Path -LiteralPath $icoPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($icoPath) } catch { }
}

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 5
$root.BackColor = $Pal.Bg
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 70)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 56)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 92)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 84)))
$form.Controls.Add($root)

# --- 第 0 行：标题 ---
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock = 'Fill'
$pnlHeader.BackColor = $Pal.Bg
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'SafeDriveCleaner'
$lblTitle.Font = $Fonts.Title
$lblTitle.ForeColor = $Pal.Text
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(20, 12)
$pnlHeader.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = '白名单驱动的磁盘安全清理 · 默认只读扫描 · 四道保护拦截 · 绝不跟随目录联接'
$lblSub.Font = $Fonts.Small
$lblSub.ForeColor = $Pal.Muted
$lblSub.AutoSize = $true
$lblSub.Location = New-Object System.Drawing.Point(22, 42)
$pnlHeader.Controls.Add($lblSub)

$lblBadge = New-Object System.Windows.Forms.Label
$lblBadge.Text = '  安全模式  '
$lblBadge.Font = New-Object System.Drawing.Font($fontName, 9, [System.Drawing.FontStyle]::Bold)
$lblBadge.ForeColor = [System.Drawing.Color]::White
$lblBadge.BackColor = $Pal.OK
$lblBadge.AutoSize = $true
$lblBadge.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
$lblBadge.Anchor = 'Top,Right'
$lblBadge.Location = New-Object System.Drawing.Point(880, 16)
$pnlHeader.Controls.Add($lblBadge)
$pnlHeader.Add_Resize({ $script:lblBadge.Left = $script:pnlHeader.ClientSize.Width - $script:lblBadge.Width - 20 })
$script:pnlHeader = $pnlHeader
$script:lblBadge = $lblBadge
[void]$root.Controls.Add($pnlHeader, 0, 0)

# --- 第 1 行：工具栏 ---
$pnlTool = New-Object System.Windows.Forms.Panel
$pnlTool.Dock = 'Fill'
$pnlTool.BackColor = $Pal.Card
$lblDrive = New-Object System.Windows.Forms.Label
$lblDrive.Text = '驱动器'
$lblDrive.AutoSize = $true
$lblDrive.ForeColor = $Pal.Muted
$lblDrive.Location = New-Object System.Drawing.Point(20, 18)
$pnlTool.Controls.Add($lblDrive)

$cboDrive = New-Object System.Windows.Forms.ComboBox
$cboDrive.DropDownStyle = 'DropDownList'
$cboDrive.Width = 70
$cboDrive.Location = New-Object System.Drawing.Point(72, 14)
$pnlTool.Controls.Add($cboDrive)

$lblDepth = New-Object System.Windows.Forms.Label
$lblDepth.Text = '扫描深度'
$lblDepth.AutoSize = $true
$lblDepth.ForeColor = $Pal.Muted
$lblDepth.Location = New-Object System.Drawing.Point(162, 18)
$pnlTool.Controls.Add($lblDepth)

$numDepth = New-Object System.Windows.Forms.NumericUpDown
$numDepth.Minimum = 2
$numDepth.Maximum = 30
$numDepth.Value = 10
$numDepth.Width = 54
$numDepth.Location = New-Object System.Drawing.Point(220, 14)
$pnlTool.Controls.Add($numDepth)

$btnScan = New-FlatButton -Text '开始扫描' -Width 104 -Back $Pal.Accent -Fore ([System.Drawing.Color]::White) -Hover $Pal.AccentHv
$btnScan.Location = New-Object System.Drawing.Point(292, 12)
$pnlTool.Controls.Add($btnScan)

$btnCancel = New-FlatButton -Text '取消' -Width 68 -Back ([System.Drawing.Color]::FromArgb(233, 236, 239)) -Fore $Pal.Text -Hover ([System.Drawing.Color]::FromArgb(222, 226, 230))
$btnCancel.Location = New-Object System.Drawing.Point(404, 12)
$btnCancel.Enabled = $false
$pnlTool.Controls.Add($btnCancel)

$btnReport = New-FlatButton -Text '打开报告' -Width 92 -Back ([System.Drawing.Color]::FromArgb(233, 236, 239)) -Fore $Pal.Text -Hover ([System.Drawing.Color]::FromArgb(222, 226, 230))
$btnReport.Location = New-Object System.Drawing.Point(480, 12)
$btnReport.Enabled = $false
$pnlTool.Controls.Add($btnReport)

$script:btnReport = $btnReport
$script:cboDrive = $cboDrive
$script:numDepth = $numDepth
$script:btnScan = $btnScan
$script:btnCancel = $btnCancel
[void]$root.Controls.Add($pnlTool, 0, 1)

# --- 第 2 行：统计卡片 ---
$pnlStats = New-Object System.Windows.Forms.Panel
$pnlStats.Dock = 'Fill'
$pnlStats.BackColor = $Pal.Bg
$stats = New-Object System.Windows.Forms.TableLayoutPanel
$stats.Dock = 'Fill'
$stats.ColumnCount = 5
$stats.RowCount = 1
$stats.Padding = New-Object System.Windows.Forms.Padding(14, 6, 14, 6)
for ($i = 0; $i -lt 5; $i++) {
    [void]$stats.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 20)))
}
$pnlStats.Controls.Add($stats)

function New-StatCard {
    param([string]$Key)
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'
    $p.BackColor = $Pal.Card
    $p.Margin = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
    $k = New-Object System.Windows.Forms.Label
    $k.Text = $Key
    $k.Font = $Fonts.Small
    $k.ForeColor = $Pal.Muted
    $k.AutoSize = $true
    $k.Location = New-Object System.Drawing.Point(12, 10)
    $p.Controls.Add($k)
    $v = New-Object System.Windows.Forms.Label
    $v.Text = '—'
    $v.Font = $Fonts.Stat
    $v.ForeColor = $Pal.Text
    $v.AutoSize = $true
    $v.Location = New-Object System.Drawing.Point(11, 30)
    $p.Controls.Add($v)
    $p.Tag = $v
    return $p
}

$keys = @('可清理总量', '候选条目', '保护拦截', '索引规模', '未使用天数过滤')
$cards = @()
for ($i = 0; $i -lt $keys.Count; $i++) {
    $c = New-StatCard -Key $keys[$i]
    $cards += $c
    [void]$stats.Controls.Add($c, $i, 0)
}
$script:valTotal = $cards[0].Tag
$script:valCand = $cards[1].Tag
$script:valProt = $cards[2].Tag
$script:valIndex = $cards[3].Tag
$script:valSkip = $cards[4].Tag
[void]$root.Controls.Add($pnlStats, 0, 2)

# --- 第 3 行：候选表格 ---
$pnlGrid = New-Object System.Windows.Forms.Panel
$pnlGrid.Dock = 'Fill'
$pnlGrid.BackColor = $Pal.Bg
$pnlGrid.Padding = New-Object System.Windows.Forms.Padding(18, 0, 18, 0)

$dgv = New-Object System.Windows.Forms.DataGridView
$dgv.Dock = 'Fill'
$dgv.BackgroundColor = $Pal.Card
$dgv.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$dgv.GridColor = $Pal.Border
$dgv.AllowUserToAddRows = $false
$dgv.AllowUserToDeleteRows = $false
$dgv.AllowUserToResizeRows = $false
$dgv.RowHeadersVisible = $false
$dgv.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgv.MultiSelect = $true
$dgv.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::None
$dgv.EnableHeadersVisualStyles = $false
$dgv.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::Single
$dgv.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(241, 243, 245)
$dgv.ColumnHeadersDefaultCellStyle.ForeColor = $Pal.Text
$dgv.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(241, 243, 245)
$dgv.ColumnHeadersDefaultCellStyle.SelectionForeColor = $Pal.Text
$dgv.ColumnHeadersHeight = 34
$dgv.ColumnHeadersHeightSizeMode = 'DisableResizing'
$dgv.RowTemplate.Height = 28
$dgv.DefaultCellStyle.BackColor = $Pal.Card
$dgv.DefaultCellStyle.ForeColor = $Pal.Text
$dgv.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
$dgv.DefaultCellStyle.SelectionForeColor = $Pal.Text
$dgv.AlternatingRowsDefaultCellStyle.BackColor = $Pal.Stripe
$dgv.AlternatingRowsDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(219, 234, 254)

$colCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colCheck.HeaderText = '选择'
$colCheck.Width = 46
$colCheck.SortMode = 'NotSortable'
$colCheck.FalseValue = $false
$colCheck.TrueValue = $true
[void]$dgv.Columns.Add($colCheck)

function Add-TextColumn {
    param([string]$Header, [int]$Width, [string]$Align = 'Left', [bool]$Fill = $false)
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.HeaderText = $Header
    $col.ReadOnly = $true
    $col.SortMode = 'NotSortable'
    if ($Fill) {
        $col.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
        $col.FillWeight = 100
    }
    else {
        $col.Width = $Width
    }
    if ($Align -eq 'Right') {
        $col.DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
        $col.HeaderCell.Style.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
    }
    else {
        $col.DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleLeft
    }
    return $col
}

[void]$dgv.Columns.Add((Add-TextColumn -Header '路径' -Width 0 -Fill $true))
[void]$dgv.Columns.Add((Add-TextColumn -Header '分类' -Width 108))
[void]$dgv.Columns.Add((Add-TextColumn -Header '体积' -Width 88 -Align 'Right'))
[void]$dgv.Columns.Add((Add-TextColumn -Header '文件数' -Width 68 -Align 'Right'))
[void]$dgv.Columns.Add((Add-TextColumn -Header '未使用(天)' -Width 88 -Align 'Right'))
[void]$dgv.Columns.Add((Add-TextColumn -Header '风险' -Width 66))
$pnlGrid.Controls.Add($dgv)
$script:dgv = $dgv
[void]$root.Controls.Add($pnlGrid, 0, 3)

# --- 第 4 行：底部操作栏 ---
$pnlBottom = New-Object System.Windows.Forms.Panel
$pnlBottom.Dock = 'Fill'
$pnlBottom.BackColor = $Pal.Card

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = '就绪。点击「开始扫描」——扫描是只读的，不会删除任何文件。'
$lblStatus.AutoSize = $true
$lblStatus.ForeColor = $Pal.Muted
$lblStatus.Font = $Fonts.Small
$lblStatus.Location = New-Object System.Drawing.Point(20, 12)
$pnlBottom.Controls.Add($lblStatus)
$script:lblStatus = $lblStatus

$prg = New-Object System.Windows.Forms.ProgressBar
$prg.Style = 'Marquee'
$prg.MarqueeAnimationSpeed = 0
$prg.Width = 220
$prg.Height = 6
$prg.Location = New-Object System.Drawing.Point(20, 38)
$pnlBottom.Controls.Add($prg)
$script:prg = $prg

$btnAll = New-FlatButton -Text '全选' -Width 62 -Back ([System.Drawing.Color]::FromArgb(233, 236, 239)) -Fore $Pal.Text -Hover ([System.Drawing.Color]::FromArgb(222, 226, 230))
$btnAll.Location = New-Object System.Drawing.Point(20, 52)
$pnlBottom.Controls.Add($btnAll)

$btnNone = New-FlatButton -Text '全不选' -Width 68 -Back ([System.Drawing.Color]::FromArgb(233, 236, 239)) -Fore $Pal.Text -Hover ([System.Drawing.Color]::FromArgb(222, 226, 230))
$btnNone.Location = New-Object System.Drawing.Point(88, 52)
$pnlBottom.Controls.Add($btnNone)

$cboCat = New-Object System.Windows.Forms.ComboBox
$cboCat.DropDownStyle = 'DropDownList'
$cboCat.Width = 148
$cboCat.Location = New-Object System.Drawing.Point(164, 55)
[void]$cboCat.Items.Add('全部分类')
$cboCat.SelectedIndex = 0
$pnlBottom.Controls.Add($cboCat)
$script:cboCat = $cboCat

$lblSel = New-Object System.Windows.Forms.Label
$lblSel.Text = '已选 0 项 · 0 B'
$lblSel.AutoSize = $true
$lblSel.Font = New-Object System.Drawing.Font($fontName, 10, [System.Drawing.FontStyle]::Bold)
$lblSel.ForeColor = $Pal.Text
$lblSel.Location = New-Object System.Drawing.Point(336, 57)
$pnlBottom.Controls.Add($lblSel)
$script:lblSel = $lblSel

$cboMethod = New-Object System.Windows.Forms.ComboBox
$cboMethod.DropDownStyle = 'DropDownList'
$cboMethod.Width = 132
[void]$cboMethod.Items.Add('回收站（可还原）')
[void]$cboMethod.Items.Add('永久删除（不可还原）')
$cboMethod.SelectedIndex = 0
$pnlBottom.Controls.Add($cboMethod)
$script:cboMethod = $cboMethod

$btnClean = New-FlatButton -Text '清理选中项' -Width 118 -Back ([System.Drawing.Color]::FromArgb(220, 226, 232)) -Fore $Pal.Muted -Hover ([System.Drawing.Color]::FromArgb(210, 216, 222))
$btnClean.Enabled = $false
$pnlBottom.Controls.Add($btnClean)
$script:btnClean = $btnClean

$pnlBottom.Add_Resize({
        $w = $script:pnlBottom.ClientSize.Width
        $script:btnClean.Left = $w - $script:btnClean.Width - 20
        $script:btnClean.Top = 50
        $script:cboMethod.Left = $script:btnClean.Left - $script:cboMethod.Width - 10
        $script:cboMethod.Top = 55
    })
$script:pnlBottom = $pnlBottom
[void]$root.Controls.Add($pnlBottom, 0, 4)

# ---------------------------------------------------------------------------
# 逻辑
# ---------------------------------------------------------------------------
function Update-SelectionSummary {
    $n = 0
    $bytes = [long]0
    foreach ($row in $script:dgv.Rows) {
        if ($row.Cells[0].Value -eq $true) {
            $n++
            $cand = $row.Tag
            if ($cand) { $bytes += [long]$cand.Bytes }
        }
    }
    $script:lblSel.Text = ('已选 ' + $n + ' 项 · ' + (Format-Size ([double]$bytes)))

    $enabled = (-not $script:IsBusy) -and ($n -gt 0)
    $script:btnClean.Enabled = $enabled
    if ($enabled) {
        if ($script:cboMethod.SelectedIndex -eq 1) {
            $script:btnClean.BackColor = $Pal.Danger
            $script:btnClean.ForeColor = [System.Drawing.Color]::White
            $script:btnClean.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(153, 27, 27)
        }
        else {
            $script:btnClean.BackColor = $Pal.Accent
            $script:btnClean.ForeColor = [System.Drawing.Color]::White
            $script:btnClean.FlatAppearance.MouseOverBackColor = $Pal.AccentHv
        }
    }
    else {
        $script:btnClean.BackColor = [System.Drawing.Color]::FromArgb(220, 226, 232)
        $script:btnClean.ForeColor = $Pal.Muted
    }
}

function Set-Busy {
    param([bool]$Busy)
    $script:IsBusy = $Busy
    $script:btnScan.Enabled = -not $Busy
    $script:cboDrive.Enabled = -not $Busy
    $script:numDepth.Enabled = -not $Busy
    $script:cboMethod.Enabled = -not $Busy
    $script:btnCancel.Enabled = $Busy
    $script:prg.MarqueeAnimationSpeed = if ($Busy) { 30 } else { 0 }
    Update-SelectionSummary
}

function Fill-Grid {
    param($Candidates, [string]$CategoryFilter = '全部分类')

    $script:dgv.SuspendLayout()
    $script:dgv.Rows.Clear()
    foreach ($c in $Candidates) {
        if ($CategoryFilter -ne '全部分类' -and $c.Category -ne $CategoryFilter) { continue }
        $age = '—'
        if ($null -ne $c.AgeDays) { $age = [string]$c.AgeDays }
        $risk = [string]$c.Risk
        if ($risk -eq 'low') { $risk = '低' }
        elseif ($risk -eq 'medium') { $risk = '中' }
        elseif ($risk -eq 'high') { $risk = '高' }

        $idx = $script:dgv.Rows.Add()
        $row = $script:dgv.Rows[$idx]
        $row.Tag = $c
        $row.Cells[0].Value = $false
        $row.Cells[1].Value = [string]$c.Path
        $row.Cells[2].Value = [string]$c.Category
        $row.Cells[3].Value = (Format-CellSize $c.Bytes)
        $row.Cells[4].Value = [string]$c.Files
        $row.Cells[5].Value = $age
        $row.Cells[6].Value = $risk
        $row.Cells[1].ToolTipText = [string]$c.Path
    }
    $script:dgv.ResumeLayout()
    Update-SelectionSummary
}

function Set-CategoryFilter {
    $sel = [string]$script:cboCat.SelectedItem
    $script:cboCat.Items.Clear()
    [void]$script:cboCat.Items.Add('全部分类')
    $cats = @()
    foreach ($c in $script:Candidates) {
        if ($cats -notcontains $c.Category) { $cats += $c.Category }
    }
    foreach ($c in ($cats | Sort-Object)) { [void]$script:cboCat.Items.Add($c) }
    $i = $script:cboCat.Items.IndexOf($sel)
    if ($i -lt 0) { $i = 0 }
    $script:cboCat.SelectedIndex = $i
}

function Show-ConfirmDialog {
    param([int]$Count, [long]$Bytes, [string]$RootPath, [string]$Method)

    $permanent = ($Method -eq 'Permanent')
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '确认清理'
    $dlg.Size = New-Object System.Drawing.Size(560, 340)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $Pal.Bg
    $dlg.Font = $Fonts.Base

    $head = New-Object System.Windows.Forms.Label
    $head.Text = if ($permanent) { '即将永久删除，此操作不可还原' } else { '即将把下列内容移入回收站' }
    $head.Font = New-Object System.Drawing.Font($fontName, 12, [System.Drawing.FontStyle]::Bold)
    $head.ForeColor = if ($permanent) { $Pal.Danger } else { $Pal.Warn }
    $head.AutoSize = $true
    $head.Location = New-Object System.Drawing.Point(20, 18)
    $dlg.Controls.Add($head)

    $body = New-Object System.Windows.Forms.Label
    $body.AutoSize = $false
    $body.Size = New-Object System.Drawing.Size(500, 96)
    $body.Location = New-Object System.Drawing.Point(20, 52)
    $body.ForeColor = $Pal.Text
    $lines = @()
    $lines += ('目标根目录：' + $RootPath)
    $lines += ('清理条目：' + $Count + ' 项，合计 ' + (Format-Size ([double]$Bytes)))
    $lines += ('删除方式：' + $(if ($permanent) { '永久删除（无法通过回收站还原）' } else { '移入回收站（可还原）' }))
    $lines += ''
    if ($permanent) {
        $lines += '永久删除后无法恢复。若不确定，请改用回收站方式。'
    }
    else {
        $lines += '内容会进回收站，删错了可以在回收站里还原。'
    }
    $body.Text = ($lines -join "`r`n")
    $dlg.Controls.Add($body)

    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(20, 168)
    $hint.ForeColor = $Pal.Muted
    $hint.Font = $Fonts.Small
    $hint.Text = if ($permanent) { '请输入 PERMANENT 以确认（大写或小写均可）：' } else { '请输入 YES 以确认：' }
    $dlg.Controls.Add($hint)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(20, 192)
    $txt.Width = 500
    $txt.Font = New-Object System.Drawing.Font('Consolas', 11)
    $dlg.Controls.Add($txt)

    $ok = New-FlatButton -Text $(if ($permanent) { '永久删除' } else { '确认清理' }) -Width 110 `
        -Back $(if ($permanent) { $Pal.Danger } else { $Pal.Accent }) -Fore ([System.Drawing.Color]::White) `
        -Hover $(if ($permanent) { [System.Drawing.Color]::FromArgb(153, 27, 27) } else { $Pal.AccentHv })
    $ok.Location = New-Object System.Drawing.Point(410, 240)
    $ok.Enabled = $false
    $dlg.Controls.Add($ok)

    $no = New-FlatButton -Text '取消' -Width 84 -Back ([System.Drawing.Color]::FromArgb(233, 236, 239)) -Fore $Pal.Text -Hover ([System.Drawing.Color]::FromArgb(222, 226, 230))
    $no.Location = New-Object System.Drawing.Point(316, 240)
    $dlg.Controls.Add($no)

    $need = if ($permanent) { 'PERMANENT' } else { 'YES' }
    $txt.Add_TextChanged({ $script:dlgOkButton.Enabled = ($script:dlgTextBox.Text.Trim() -eq $script:dlgNeed) })
    $script:dlgOkButton = $ok
    $script:dlgTextBox = $txt
    $script:dlgNeed = $need

    $ok.Add_Click({ $script:dlgResult = $true; $script:dlgForm.Close() })
    $no.Add_Click({ $script:dlgResult = $false; $script:dlgForm.Close() })
    $script:dlgForm = $dlg
    $script:dlgResult = $false

    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $no
    [void]$dlg.ShowDialog($form)
    return [bool]$script:dlgResult
}

function Start-Task {
    param(
        [ValidateSet('Scan', 'Clean')][string]$Kind,
        [string[]]$OnlyPaths,
        [string]$DeleteMethod
    )

    $drive = [string]$script:cboDrive.SelectedItem
    if (-not $drive) { [void][System.Windows.Forms.MessageBox]::Show('请先选择驱动器。', 'SafeDriveCleaner'); return }
    $rootPath = $drive + ':\'
    if (-not (Test-Path -LiteralPath $rootPath)) {
        [void][System.Windows.Forms.MessageBox]::Show(('根目录不可访问：' + $rootPath), 'SafeDriveCleaner')
        return
    }

    $task = @{
        RootPath       = $rootPath
        DriveLetter    = $drive
        Mode           = $Kind
        MaxDepth       = [int]$script:numDepth.Value
        MinAgeDays     = -1
        DeleteMethod   = if ($DeleteMethod) { $DeleteMethod } else { 'RecycleBin' }
        OutDir         = (Join-Path $script:AppRoot 'reports')
        SkipRecycleBin = $false
    }
    if ($OnlyPaths -and @($OnlyPaths).Count -gt 0) { $task['OnlyPaths'] = $OnlyPaths }

    $script:TaskKind = $Kind
    $script:Job = Start-Job -ScriptBlock {
        param($workerPath, $t)
        . $workerPath
        Invoke-CleanerAppTask @t
    } -ArgumentList $script:WorkerPath, $task

    Set-Busy $true
    if ($script:timer) { $script:timer.Start() }
    if ($Kind -eq 'Scan') {
        Set-Status ('正在扫描 ' + $rootPath + ' …（只读，不会删除任何文件）') 'muted'
    }
    else {
        Set-Status ('正在清理 ' + $rootPath + ' …') 'muted'
    }
}

function Complete-Task {
    $kind = $script:TaskKind
    $res = $null
    try {
        $res = Receive-Job -Job $script:Job -ErrorAction Stop
    }
    catch {
        Set-Status ('后台任务异常：' + $_.Exception.Message) 'err'
    }
    finally {
        Remove-Job -Job $script:Job -Force -ErrorAction SilentlyContinue
        $script:Job = $null
        Set-Busy $false
    }

    if (-not $res) { Set-Status '后台任务没有返回结果。' 'err'; return }

    if (-not $res.Ok) {
        Set-Status ('失败：' + $res.Error) 'err'
        [void][System.Windows.Forms.MessageBox]::Show($res.Error, 'SafeDriveCleaner', 'OK', 'Error')
        return
    }

    if ($kind -eq 'Scan') {
        $script:ScanResult = $res
        $script:Candidates = @($res.Candidates)
        Set-CategoryFilter
        Fill-Grid -Candidates $script:Candidates -CategoryFilter ([string]$script:cboCat.SelectedItem)

        $script:valTotal.Text = Format-Size ([double]$res.TotalBytes)
        $script:valCand.Text = [string]$res.CandidateCount
        $script:valProt.Text = [string](Get-CleanerCount $res.ProtectionHits)
        $script:valIndex.Text = ('' + $res.IndexDirs + ' / ' + $res.IndexFiles)

        $tooNew = Get-CleanerCount $res.TooNew
        $script:valSkip.Text = [string]$tooNew

        if ($res.CandidateCount -eq 0) {
            Set-Status ('扫描完成，' + $res.DurationSec + ' 秒。未发现符合白名单规则的可清理目标。') 'ok'
        }
        else {
            Set-Status ('扫描完成，' + $res.DurationSec + ' 秒。共 ' + $res.CandidateCount + ' 项候选，可清理 ' +
                (Format-Size ([double]$res.TotalBytes)) + '。') 'ok'
        }

        if ($res.TruncatedCount -gt 0) {
            Set-Status ('注意：有 ' + $res.TruncatedCount + ' 个目录达到深度上限未继续下探，可能漏掉更深的缓存，建议提高扫描深度后重扫。') 'warn'
        }
        if ($res.HtmlReport) { $script:btnReport.Enabled = $true }
    }
    else {
        $script:btnReport.Enabled = [bool]$res.HtmlReport
        $msg = '清理完成：成功 ' + $res.DeletedCount + ' 项，释放 ' + (Format-Size ([double]$res.DeletedBytes))
        if ($res.FailedCount -gt 0) { $msg += '，失败 ' + $res.FailedCount + ' 项' }
        if ($res.SkippedCount -gt 0) { $msg += '，跳过 ' + $res.SkippedCount + ' 项' }
        $msg += '。'
        Set-Status $msg 'ok'

        if ($res.RequestedCount -ne $res.MatchedCount) {
            $msg += "`r`n`r`n注意：请求清理 $($res.RequestedCount) 项，其中 $($res.RequestedCount - $res.MatchedCount) 项不在引擎当前候选集中，已被忽略。"
        }
        [void][System.Windows.Forms.MessageBox]::Show($msg, 'SafeDriveCleaner', 'OK', 'Information')

        # 清理后自动重扫，让界面反映真实状态
        Start-Task -Kind 'Scan'
    }
}

# ---------------------------------------------------------------------------
# 事件
# ---------------------------------------------------------------------------
$script:dgv.Add_CurrentCellDirtyStateChanged({
        if ($script:dgv.IsCurrentCellDirty) { $script:dgv.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
    })
$script:dgv.Add_CellValueChanged({ Update-SelectionSummary })
$script:dgv.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -ge 0) {
            $cand = $script:dgv.Rows[$e.RowIndex].Tag
            if ($cand) {
                $parent = Split-Path -Parent ([string]$cand.Path)
                $target = if (Test-Path -LiteralPath ([string]$cand.Path)) { [string]$cand.Path } else { $parent }
                if (Test-Path -LiteralPath $target) { Start-Process explorer.exe -ArgumentList ('"' + $target + '"') }
            }
        }
    })

$btnAll.Add_Click({
        foreach ($row in $script:dgv.Rows) { $row.Cells[0].Value = $true }
        Update-SelectionSummary
    })
$btnNone.Add_Click({
        foreach ($row in $script:dgv.Rows) { $row.Cells[0].Value = $false }
        Update-SelectionSummary
    })
$cboCat.Add_SelectedIndexChanged({
        Fill-Grid -Candidates $script:Candidates -CategoryFilter ([string]$script:cboCat.SelectedItem)
    })
$cboMethod.Add_SelectedIndexChanged({ Update-SelectionSummary })
$btnScan.Add_Click({ Start-Task -Kind 'Scan' })
$btnCancel.Add_Click({
        if ($script:Job) {
            Stop-Job -Job $script:Job -ErrorAction SilentlyContinue
            Set-Status '已取消。' 'warn'
            Set-Busy $false
            Remove-Job -Job $script:Job -Force -ErrorAction SilentlyContinue
            $script:Job = $null
        }
    })
$script:btnReport.Add_Click({
        $p = $null
        if ($script:ScanResult -and $script:ScanResult.HtmlReport) { $p = [string]$script:ScanResult.HtmlReport }
        if (-not $p) { $p = Join-Path $script:AppRoot 'reports\latest.html' }
        if (Test-Path -LiteralPath $p) { Start-Process $p } else { Set-Status '还没有可打开的报告。' 'warn' }
    })

$script:btnClean.Add_Click({
        $selected = @()
        foreach ($row in $script:dgv.Rows) {
            if ($row.Cells[0].Value -eq $true) {
                $cand = $row.Tag
                if ($cand) { $selected += [string]$cand.Path }
            }
        }
        if ($selected.Count -eq 0) { Set-Status '没有选中任何条目。' 'warn'; return }

        $bytes = [long]0
        foreach ($row in $script:dgv.Rows) {
            if ($row.Cells[0].Value -eq $true -and $row.Tag) { $bytes += [long]$row.Tag.Bytes }
        }

        $method = if ($script:cboMethod.SelectedIndex -eq 1) { 'Permanent' } else { 'RecycleBin' }
        $drive = [string]$script:cboDrive.SelectedItem
        if (Show-ConfirmDialog -Count $selected.Count -Bytes $bytes -RootPath ($drive + ':\') -Method $method) {
            Start-Task -Kind 'Clean' -OnlyPaths $selected -DeleteMethod $method
        }
        else {
            Set-Status '已取消，未做任何删除。' 'warn'
        }
    })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
        if ($script:Job -and $script:Job.State -in @('Completed', 'Failed', 'Stopped')) {
            $script:timer.Stop()
            Complete-Task
        }
    })
$script:timer = $timer
$form.Add_Shown({
        $script:timer.Start()
        if ($script:AutoScan) { Start-Task -Kind 'Scan' }
    })
$form.Add_FormClosing({
        if ($script:Job) { Stop-Job -Job $script:Job -ErrorAction SilentlyContinue; Remove-Job -Job $script:Job -Force -ErrorAction SilentlyContinue }
    })

# ---------------------------------------------------------------------------
# 初始化
# ---------------------------------------------------------------------------
$drives = Get-FixedDrives
foreach ($d in $drives) { [void]$cboDrive.Items.Add($d) }
if ($cboDrive.Items.Count -eq 0) {
    [void][System.Windows.Forms.MessageBox]::Show('没有检测到可用的固定磁盘。', 'SafeDriveCleaner')
    exit 1
}
$want = $Drive
if (-not $want) { $want = if ($drives -contains 'D') { 'D' } else { $drives[0] } }
$idx = $cboDrive.Items.IndexOf($want)
if ($idx -lt 0) { $idx = 0 }
$cboDrive.SelectedIndex = $idx

$script:AutoScan = [bool]$AutoScan

if ($SelfTest) {
    # 自检：构建完毕后立即销毁，不进入消息循环
    $ok = $true
    $notes = @()
    try {
        $notes += ('form ok, controls=' + $form.Controls.Count)
        $notes += ('grid cols=' + $script:dgv.Columns.Count + ' rows=' + $script:dgv.Rows.Count)
        $notes += ('drives=' + ($drives -join ','))
        $notes += ('selected drive=' + [string]$script:cboDrive.SelectedItem)
        $notes += ('worker exists=' + (Test-Path -LiteralPath $script:WorkerPath))
        $notes += 'SELFTEST OK'
    }
    catch {
        $ok = $false
        $notes += ('SELFTEST FAILED: ' + $_.Exception.Message)
    }
    $form.Dispose()
    $notes | Set-Content -LiteralPath (Join-Path $env:TEMP '_gui_selftest.txt') -Encoding utf8
    if (-not $ok) { exit 1 }
    exit 0
}

[void]$form.ShowDialog()
$form.Dispose()
