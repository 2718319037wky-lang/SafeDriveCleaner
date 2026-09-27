' SafeDriveCleaner 静默启动器（模板）
'
' 这是模板文件：里面的占位符由 tools\New-DesktopEntry.ps1
' 在生成桌面入口时替换为 SafeDriveCleaner.App.ps1 所在的真实路径。
' 如果你直接双击本文件，请先确认占位符已被替换（解压后从 app 目录双击即可）。
'
' 为什么用 .vbs 而不是 .lnk：
'   本机 PowerShell 的 COM 实例化被安全策略禁用（WScript.Shell 建不了快捷方式），
'   而手写 .lnk 二进制在含中文的路径下不可靠。.vbs 由 Windows Script Host 直接执行，
'   不需要 COM 建对象，天然双击即用。
'
' 作用：以隐藏窗口方式启动 PowerShell 界面，避免闪一下黑框。
'
' 用法：
'   双击本文件即可：默认扫 D 盘，开窗口后自动启动扫描。
'   也可以拖一个盘符到本文件图标上（首字母有效，例如 "D" 或 "E:"）。
'
' 故障排查：
'   * 若启动后只闪一下就消失：右键 → 用 PowerShell 手动跑 .\SafeDriveCleaner.App.ps1 看错误
'   * 若弹出 PowerShell 错误：确认 PowerShell 5.1 已安装（Win10/11 自带，Win7 需装 KB3191566）

Option Explicit

Dim shell, fso, appDir, ps, cmd, driveArg, errMsg

Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

' 占位符 —— 这里是 SafeDriveCleaner.App.ps1 所在的目录（绝对路径，末尾带反斜杠）
appDir = "{{SDC_APP_DIR}}"

' 默认 D 盘；接受用户拖放的首字母
driveArg = "D"
If WScript.Arguments.Count > 0 Then
    Dim a
    a = Trim(WScript.Arguments(0))
    If Len(a) > 0 Then
        Dim ch
        ch = Left(a, 1)
        If ch Like "[A-Za-z]" Then driveArg = UCase(ch)
    End If
End If

ps = "powershell.exe"

' 1) 启动前先检查 ps 是否存在
On Error Resume Next
Dim probe
probe = shell.Exec("where " & ps).StdOut.ReadAll
If Err.Number <> 0 Or InStr(LCase(probe), LCase(ps)) = 0 Then
    MsgBox "找不到 PowerShell。" & vbCrLf & vbCrLf & _
           "SafeDriveCleaner 需要 Windows PowerShell 5.1。" & vbCrLf & _
           "Windows 10 / 11 自带；Windows 7 需手动安装。" & vbCrLf & vbCrLf & _
           "详情见 README-APP.md。", _
           vbCritical, "SafeDriveCleaner"
    WScript.Quit 1
End If
On Error Goto 0

' 2) 检查 App.ps1 是否存在（占位符未被替换 / 路径失效）
Dim appScript
appScript = appDir & "SafeDriveCleaner.App.ps1"
If Not fso.FileExists(appScript) Then
    MsgBox "找不到 SafeDriveCleaner.App.ps1：" & vbCrLf & appScript & vbCrLf & vbCrLf & _
           "如果你运行的是桌面入口，请检查 SafeDriveCleaner 是否已被移动或卸载。" & vbCrLf & _
           "如果是首次安装，请改双击 zip 包根目录里的 SafeDriveCleaner.cmd。", _
           vbCritical, "SafeDriveCleaner"
    WScript.Quit 1
End If

' 3) 显式传 -Drive / -AutoScan，意图清晰
cmd = ps & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden" & _
      " -File """ & appScript & """" & _
      " -Drive " & driveArg & _
      " -AutoScan"

' 0 = 隐藏窗口, False = 不等待
shell.Run cmd, 0, False