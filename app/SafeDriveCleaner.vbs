' SafeDriveCleaner 静默启动器
'
' 为什么用 .vbs 而不是 .lnk：
'   本机 PowerShell 的 COM 实例化被安全策略禁用（WScript.Shell 建不了快捷方式），
'   而手写 .lnk 二进制在含中文的路径下不可靠、也无法在无 GUI 环境验证解析结果。
'   .vbs 由 Windows Script Host 直接执行，不需要 COM 建对象，天然双击即用。
'
' 作用：以隐藏窗口方式启动 PowerShell 界面，避免闪一下黑框。
' 用法：双击本文件即可；也可以把盘符当参数传进来，例如 SafeDriveCleaner.vbs D

Option Explicit

Dim shell, fso, here, cmd, extra
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)

extra = ""
If WScript.Arguments.Count > 0 Then
    Dim a
    a = WScript.Arguments(0)
    If Len(a) > 0 Then extra = " -Drive """ & Left(a, 1) & """"
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden" & _
      " -File """ & here & "\SafeDriveCleaner.App.ps1""" & extra

' 0 = 隐藏窗口, False = 不等待
shell.Run cmd, 0, False
