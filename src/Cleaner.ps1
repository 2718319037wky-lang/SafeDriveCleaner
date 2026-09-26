# ============================================================================
#  Cleaner.ps1 - 删除执行层
#  SafeDriveCleaner
#
#  设计要点：
#   1. 默认走「回收站」删除（SHFileOperation + FOF_ALLOWUNDO），可还原；
#   2. 使用 FOF_NOERRORUI | FOF_SILENT | FOF_NOCONFIRMATION，全程无弹窗、不阻塞；
#   3. 若 SHFileOperation 不可用，回退到 Microsoft.VisualBasic.FileIO.FileSystem；
#   4. 永久删除必须显式指定 -DeleteMethod Permanent，且同样需要确认，默认永不使用。
# ============================================================================
#Requires -Version 5.1

$script:ShFileOpReady   = $null
$script:VbFileSystemOk  = $null

# --- SHFileOperation P/Invoke -------------------------------------------------
# 注意：不加 Pack 属性，让 CLR 使用自然对齐，这与 C 编译器在 x64/x86 下的
#       SHFILEOPSTRUCTW 布局一致；加 Pack=1 反而会在 x64 上错位。
$script:ShFileOpTypeDefined = $false

function Initialize-ShFileOperation {
    [CmdletBinding()]
    param()

    if ($script:ShFileOpTypeDefined) { return $true }
    if ($script:ShFileOpReady -eq $false) { return $false }

    $code = @'
using System;
using System.Runtime.InteropServices;

public static class NativeRecycle
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEOPSTRUCT
    {
        public IntPtr hwnd;
        public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        [MarshalAs(UnmanagedType.LPWStr)] public string pTo;
        public ushort fFlags;
        [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszProgressTitle;
    }

    private const uint FO_DELETE = 0x0003;
    private const ushort FOF_SILENT = 0x0004;
    private const ushort FOF_NOCONFIRMATION = 0x0010;
    private const ushort FOF_ALLOWUNDO = 0x0040;
    private const ushort FOF_NOCONFIRMMKDIR = 0x0200;
    private const ushort FOF_NOERRORUI = 0x0400;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = false)]
    private static extern int SHFileOperationW(ref SHFILEOPSTRUCT lpFileOp);

    /// <summary>把单个路径移入回收站。返回 0 表示成功。</summary>
    public static int Recycle(string path, out bool aborted)
    {
        SHFILEOPSTRUCT op = new SHFILEOPSTRUCT();
        op.hwnd = IntPtr.Zero;
        op.wFunc = FO_DELETE;
        op.pFrom = path + "\0\0";
        op.pTo = null;
        op.fFlags = (ushort)(FOF_SILENT | FOF_NOCONFIRMATION | FOF_ALLOWUNDO | FOF_NOCONFIRMMKDIR | FOF_NOERRORUI);
        op.fAnyOperationsAborted = false;
        op.hNameMappings = IntPtr.Zero;
        op.lpszProgressTitle = null;

        int rc = SHFileOperationW(ref op);
        aborted = op.fAnyOperationsAborted;

        if (rc != 0) return rc;
        if (aborted) return -1;
        return 0;
    }
}
'@

    try {
        Add-Type -TypeDefinition $code -ErrorAction Stop
        $script:ShFileOpTypeDefined = $true
        $script:ShFileOpReady = $true
        return $true
    }
    catch {
        Write-CLog ("SHFileOperation 不可用，将使用回退方案：" + $_.Exception.Message) 'WARN'
        $script:ShFileOpReady = $false
        return $false
    }
}

function Test-VbFileSystem {
    [CmdletBinding()]
    param()

    if ($null -ne $script:VbFileSystemOk) { return $script:VbFileSystemOk }
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        $null = [Microsoft.VisualBasic.FileIO.FileSystem]
        $script:VbFileSystemOk = $true
    }
    catch {
        $script:VbFileSystemOk = $false
    }
    return $script:VbFileSystemOk
}

<#
.SYNOPSIS
    探测本机可用的删除策略，返回策略名。
#>
function Get-CleanerDeleteStrategy {
    [CmdletBinding()]
    param([ValidateSet('Auto', 'RecycleBin', 'Permanent')][string]$DeleteMethod = 'Auto')

    if ($DeleteMethod -eq 'Permanent') { return 'Permanent' }
    if (Initialize-ShFileOperation) { return 'ShFileOperation' }
    if (Test-VbFileSystem) { return 'VisualBasic' }
    return 'Unavailable'
}

<#
.SYNOPSIS
    把一个文件/目录移入回收站，返回 @{Success; Strategy; Error}
#>
function Remove-ToRecycleBin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('directory', 'file')][string]$Type = 'directory'
    )

    $strategy = Get-CleanerDeleteStrategy -DeleteMethod 'Auto'

    switch ($strategy) {
        'ShFileOperation' {
            try {
                $aborted = $false
                $rc = [NativeRecycle]::Recycle($Path, [ref]$aborted)
                if ($rc -eq 0) {
                    return [pscustomobject]@{ Success = $true; Strategy = 'SHFileOperation'; Error = $null }
                }
                return [pscustomobject]@{ Success = $false; Strategy = 'SHFileOperation'; Error = ('SHFileOperation 返回错误码 0x' + ('{0:X}' -f $rc)) }
            }
            catch {
                return [pscustomobject]@{ Success = $false; Strategy = 'SHFileOperation'; Error = $_.Exception.Message }
            }
        }

        'VisualBasic' {
            try {
                if ($Type -eq 'file') {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                        $Path,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                        [Microsoft.VisualBasic.FileIO.UICancelOption]::DoNothing)
                }
                else {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                        $Path,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                        [Microsoft.VisualBasic.FileIO.UICancelOption]::DoNothing)
                }
                return [pscustomobject]@{ Success = $true; Strategy = 'VisualBasic'; Error = $null }
            }
            catch {
                return [pscustomobject]@{ Success = $false; Strategy = 'VisualBasic'; Error = $_.Exception.Message }
            }
        }

        default {
            return [pscustomobject]@{
                Success  = $false
                Strategy = 'Unavailable'
                Error    = '本机既无法加载 SHFileOperation，也无法加载 Microsoft.VisualBasic，出于安全考虑拒绝永久删除'
            }
        }
    }
}

<#
.SYNOPSIS
    永久删除（不可还原）。仅在显式指定 -DeleteMethod Permanent 时使用。
#>
function Remove-Permanently {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('directory', 'file')][string]$Type = 'directory'
    )

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return [pscustomobject]@{ Success = $true; Strategy = 'Permanent'; Error = $null }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Strategy = 'Permanent'; Error = $_.Exception.Message }
    }
}

<#
.SYNOPSIS
    清空指定盘的回收站（调用系统 Clear-RecycleBin，只影响该盘）。
#>
function Clear-DriveRecycleBin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [switch]$WhatIfOnly
    )

    $dl = $DriveLetter.TrimEnd(':')

    if ($WhatIfOnly) {
        return [pscustomobject]@{ Success = $true; Strategy = 'WhatIf'; Error = $null }
    }

    try {
        Clear-RecycleBin -DriveLetter $dl -Force -Confirm:$false -ErrorAction Stop
        return [pscustomobject]@{ Success = $true; Strategy = 'Clear-RecycleBin'; Error = $null }
    }
    catch {
        # 回收站本来就是空的时也会抛错，这里做一次区分
        $msg = $_.Exception.Message
        $stats = Get-RecycleBinStats -DriveLetter $dl
        if ($stats.Files -eq 0) {
            return [pscustomobject]@{ Success = $true; Strategy = 'Clear-RecycleBin'; Error = $null }
        }
        return [pscustomobject]@{ Success = $false; Strategy = 'Clear-RecycleBin'; Error = $msg }
    }
}

<#
.SYNOPSIS
    执行清理：遍历候选，逐个删除，返回逐条执行记录。
#>
function Invoke-CleanerClean {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]$Candidates,
        [Parameter(Mandatory)][string]$DriveLetter,
        [ValidateSet('Auto', 'RecycleBin', 'Permanent')][string]$DeleteMethod = 'Auto',
        [switch]$DryRun,

        # 可选：传入根目录与保护配置后，每一条在真正删除前都会重跑一遍完整保护裁决。
        # 强烈建议传入 —— 这是防住"扫描到执行之间路径被掉包"的唯一手段。
        [string]$RootPath,
        $Protection
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $results = New-Object System.Collections.Generic.List[object]

    $effectiveMethod = $DeleteMethod
    if ($DeleteMethod -eq 'Permanent') {
        Write-CLog '删除策略：永久删除（不可还原）' 'WARN'
    }
    else {
        # Auto 与 RecycleBin 走同一条路径：先探测本机能力，探不到就中止。
        # 绝不"退化为永久删除"——那是最不该发生的静默降级。
        $probe = Get-CleanerDeleteStrategy -DeleteMethod 'Auto'
        if ($probe -eq 'Unavailable') {
            Write-CLog '本机无法执行回收站删除（SHFileOperation 与 Microsoft.VisualBasic 均不可用），已中止；不会退化为永久删除' 'ERROR'
            return [pscustomobject]@{
                Results     = (ConvertTo-CleanerArray $results)
                DryRun      = [bool]$DryRun
                Method      = 'Unavailable'
                DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            }
        }
        $effectiveMethod = 'RecycleBin'
        Write-CLog ("删除策略：回收站（可还原），底层实现 = " + $probe) 'INFO'
    }

    $total = $Candidates.Count
    $i = 0
    foreach ($c in $Candidates) {
        $i++
        if ($total -gt 0) {
            Write-Progress -Activity '执行清理' -Status ("[$i/$total] " + $c.Path) `
                -PercentComplete ([int](100 * $i / $total))
        }

        if ($DryRun) {
            $results.Add([pscustomobject]@{
                    Path     = $c.Path
                    RuleId   = $c.RuleId
                    RuleName = $c.RuleName
                    Category = $c.Category
                    Type     = $c.Type
                    Bytes    = $c.Bytes
                    Status   = 'DryRun'
                    Strategy = 'WhatIf'
                    Error    = $null
                })
            continue
        }

        # 删除前复查一：路径是否仍然存在
        $exists = Test-Path -LiteralPath $c.Path
        if (-not $exists -and $c.Type -ne 'recycleBin') {
            $results.Add([pscustomobject]@{
                    Path = $c.Path; RuleId = $c.RuleId; RuleName = $c.RuleName; Category = $c.Category
                    Type = $c.Type; Bytes = [long]0; Status = 'Skipped'; Strategy = '-'
                    Error = '执行前复查发现路径已不存在'
                })
            continue
        }

        # 删除前复查二：整套保护裁决重跑一遍。
        # 扫描到执行之间存在时间窗（用户确认、报告生成），期间路径可能被换成链接、
        # 或被换成别的类型。只查"是否存在"不够 —— 这里把四道保护 + 类型校验全部重跑。
        if ($Protection -and $RootPath -and $c.Type -ne 'recycleBin') {
            $recheck = Test-CleanerTargetAllowed -Path $c.Path -RootPath $RootPath `
                -Protection $Protection -TargetType $c.Type
            if (-not $recheck.Allowed) {
                $results.Add([pscustomobject]@{
                        Path = $c.Path; RuleId = $c.RuleId; RuleName = $c.RuleName; Category = $c.Category
                        Type = $c.Type; Bytes = $c.Bytes; Status = 'Skipped'; Strategy = '-'
                        Error = ('执行前复查未通过保护检查[' + $recheck.Code + ']：' + $recheck.Reason)
                    })
                Write-CLog ('  跳过（执行前复查拦下）' + $c.Path + ' → ' + $recheck.Reason) 'WARN'
                continue
            }
        }

        # 删除前复查三：文件型目标若被其它进程独占，直接跳过并给出明确原因。
        # 目录不做此项（逐文件试探成本太高，且目录内的锁会由删除接口报错兜住）。
        if ($c.Type -eq 'file' -and (Test-FileLocked -Path $c.Path)) {
            $results.Add([pscustomobject]@{
                    Path = $c.Path; RuleId = $c.RuleId; RuleName = $c.RuleName; Category = $c.Category
                    Type = $c.Type; Bytes = $c.Bytes; Status = 'Skipped'; Strategy = '-'
                    Error = '文件被其它进程占用，已跳过'
                })
            Write-CLog ('  跳过（文件被占用）' + $c.Path) 'WARN'
            continue
        }

        $res = $null
        if ($c.Type -eq 'recycleBin') {
            $res = Clear-DriveRecycleBin -DriveLetter $DriveLetter
        }
        elseif ($effectiveMethod -eq 'Permanent') {
            $res = Remove-Permanently -Path $c.Path -Type $c.Type
        }
        else {
            $res = Remove-ToRecycleBin -Path $c.Path -Type $c.Type
        }

        # 对回收站删除做二次校验，避免"报成功但没删掉"
        $status = if ($res.Success) { 'Deleted' } else { 'Failed' }
        if ($res.Success -and $c.Type -ne 'recycleBin' -and (Test-Path -LiteralPath $c.Path)) {
            $status = 'Failed'
            $res = [pscustomobject]@{ Success = $false; Strategy = $res.Strategy; Error = '接口报告成功，但路径仍然存在' }
        }

        $results.Add([pscustomobject]@{
                Path     = $c.Path
                RuleId   = $c.RuleId
                RuleName = $c.RuleName
                Category = $c.Category
                Type     = $c.Type
                Bytes    = $c.Bytes
                Status   = $status
                Strategy = $res.Strategy
                Error    = $res.Error
            })

        if ($status -eq 'Deleted') {
            Write-CLog ("  已清理 " + $c.Path + "  (" + (Format-Size $c.Bytes) + ")") 'OK'
        }
        else {
            Write-CLog ("  失败 " + $c.Path + " → " + $res.Error) 'WARN'
        }
    }

    Write-Progress -Activity '执行清理' -Completed
    $sw.Stop()

    return [pscustomobject]@{
        Results     = (ConvertTo-CleanerArray $results)
        DryRun      = [bool]$DryRun
        Method      = $effectiveMethod
        DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}
