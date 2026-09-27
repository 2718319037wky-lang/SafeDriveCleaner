# SafeDriveCleaner · 清理 D 盘

白名单驱动的 Windows 磁盘安全清理工具，**默认只读扫描**，确认后才删。
删除默认走回收站，**可一键还原**。

> 适合用来清：D 盘上 npm/pip/Gradle/NuGet/Cargo/VS Code/JetBrains/Chrome/Edge/Firefox 等
> 「能重建就能放心删」的缓存。
>
> **不会**碰：你的源代码、文档、照片、视频、数据库、密钥、压缩包、虚拟机磁盘、回收站
> 之外的工作文件 —— 这些都被四道保护拦截显式排除（见 `docs/SAFETY.md`）。

---

## 三步上手

1. **解压**：把 `SafeDriveCleaner-App-v*.zip` 解压到任意目录。
   推荐放到纯英文路径，例如 `D:\Tools\SafeDriveCleaner`。
   *（中文路径 PowerShell 也能跑，但桌面图标的关联在某些 Windows 上可能失效。）*

2. **双击 `SafeDriveCleaner.cmd`**：默认扫 D 盘，开窗口后自动开始扫描。
   第一次扫描可能要 20 ~ 60 秒（取决于盘大小），界面有进度条。

3. **看清单 → 勾选 → 点「清理所选」→ 输入 `YES`**：被清理的内容会进回收站。
   后悔了？清完后看「清理报告」标签页，每条都有「还原」按钮。

### 想从桌面启动？

跑一次 `Install.cmd`，它会把图标放到 `%LOCALAPPDATA%\SafeDriveCleaner\`、
把启动文件拷到你的桌面上。之后双击桌面图标即可。

---

## 选别的盘

应用顶部的 **目标盘** 下拉框列出所有固定磁盘（Fixed / 移动硬盘 / 回收站规则自动隐藏非固定盘）。
切换盘符等同重新启动一次扫描。

启动时也可拖一个盘符到 `SafeDriveCleaner.cmd` 图标上，例如 `E` 或 `E:`，
窗口会直接以那个盘为目标。

---

## 怎么还原

| 路径 | 操作 |
|---|---|
| 桌面 App · 清理报告标签页 | 每条已删除记录旁有「还原」按钮，逐条还原 |
| 命令行 | `powershell -File Restore-FromRecycleBin.ps1 -Report <导出json报告>` |
| 资源管理器 | 打开回收站，按文件名还原 |

「还原」走 Windows Shell 的回收站还原动作，原位置原文件名。

---

## 安全设计（一句话版）

- **白名单制**：只有 `config\rules.default.json` 里显式列出的路径才会成为候选。
- **四道保护拦截**：具体路径 / 目录名 / 路径段 / 扩展名，无绕过机制。
- **不跟随链接**：目录联接与符号链接一律跳过，避免跨盘误删。
- **年龄阈值**：只清「最后修改早于 N 天」的项目，避免删掉正在用的缓存。
- **执行前复查**：清理前对每条重跑存在性 + 实际类型 + 完整保护裁决。

详见 `docs\SAFETY.md`。

---

## 系统需求

- Windows 10 或 11（Windows 7 也能装 PowerShell 5.1，但官方只测过 Win10+）
- PowerShell 5.1（Win10 自带；可在 PowerShell 里跑 `$PSVersionTable.PSVersion` 看）
- .NET Framework 4.5+（Win10 自带）
- 约 5 MB 磁盘空间

---

## 卸载

1. **删除解压目录**（例如 `D:\Tools\SafeDriveCleaner`）
2. **删除桌面入口**：跑 `powershell -File tools\New-DesktopEntry.ps1 -Remove`
   或直接到桌面上右键删 `SafeDriveCleaner.vbs`
3. **删除图标缓存**：`%LOCALAPPDATA%\SafeDriveCleaner\app.ico`

**清理器不会写注册表**（除了 `%LOCALAPPDATA%\SafeDriveCleaner\` 里的图标），
卸载就是删文件。

---

## 反馈 / 排错

| 现象 | 排查 |
|---|---|
| 双击 .cmd 后窗口一闪就消失 | 在 PowerShell 里手动跑 `.\app\SafeDriveCleaner.App.ps1 -SelfTest` 看错误 |
| 弹出「找不到 PowerShell」 | Win10/11 自带；Win7 装 KB3191566 补丁 |
| 弹出「找不到 SafeDriveCleaner.App.ps1」 | 说明 .vbs 里的路径被改坏了，重新跑 `Install.cmd` |
| 桌面图标显示成默认图标 | 图标路径含中文。重新装到纯英文路径 |
| 扫描很慢 | 第一次全盘索引要时间；可在顶栏「最大深度」调小（默认 10）|
| 候选里没看到我想清的目录 | 检查 `config\rules.default.json` 是否覆盖；可在设置里加 local 规则 |
| 误删了还能还原吗 | 默认走回收站可以；Permanent 模式不可还原，开关在确认弹窗里 |

更多排错思路见 `docs\SAFETY.md` 末尾的「失效模式分析」。

---

## 命令行（备份入口）

如果不想要界面，只想跑脚本：

```powershell
# 默认扫 D 盘，只读
.\Clean-DDrive.ps1

# 演练清理（不实际删除）
.\Clean-DDrive.ps1 -Mode Clean -DryRun

# 真清理并移到回收站
.\Clean-DDrive.ps1 -Mode Clean -Yes
```

---

## 许可

见 `LICENSE`。本工具**永久删除**模式以外的所有操作都可还原。