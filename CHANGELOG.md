# 更新日志

本项目的所有重要变更都记录在此文件。

## [1.1.0] - 2026-09-26

新增原生 Windows 桌面应用。安全断言 39 → **48 项**。

### 新增

- **`app\SafeDriveCleaner.App.ps1`** —— WinForms 主界面：选盘符、扫描、分类汇总卡片、候选清单（DataGridView，带勾选/分类筛选/全选）、清理前二次确认（永久删除须输入 `PERMANENT`）、完成后自动重扫、一键打开 HTML 报告。扫描与清理都在后台任务里跑，界面不阻塞，可取消。
- **`app\Worker.ps1`** —— 界面与引擎之间的桥接层。清理时界面只传**路径字符串**，Worker 重新完整扫描并与引擎自身候选集**取交集**，再交给 `Invoke-CleanerClean`（后者对每条再重跑保护裁决）。由此得到一条硬性质：界面只能从引擎算出的候选里**减掉**一些，永远无法让引擎删一个它自己不会产生的目标。
- **`app\SafeDriveCleaner.vbs` / `.cmd`** —— 启动器。`.vbs` 由 Windows Script Host 执行，不闪控制台窗口。
- **`app\assets\app.ico`** —— 蓝底 + 白盾 + 对勾，7 个尺寸（16→256），独立渲染每一层而非放大。
- **`tools\make_icon.py` / `check_icon.py`** —— 纯标准库手写 PNG + ICO 的生成与校验（不依赖 Pillow、不联网）。
- **`tools\New-DesktopEntry.ps1`** —— 创建/移除桌面入口，并把图标复制到纯 ASCII 路径。
- 界面 `-SelfTest`：只构建界面对象树后立即销毁，用于在没有可视桌面环境时验证界面代码能否正常构造。

### 设计取舍（为什么这么做）

- **桌面入口用 `.vbs` 而不是 `.lnk`**：本机 PowerShell 的 COM 实例化被安全策略禁用，`WScript.Shell` 建不了快捷方式；手写 `.lnk` 二进制在含中文的路径下不可靠，且无法在无 GUI 环境验证解析结果。`.vbs` 不需要 COM，双击即用。
- **图标放到 `%LOCALAPPDATA%\SafeDriveCleaner\app.ico`**：外壳解析图标时，路径含中文会导致掉成默认图标，所以必须复制到纯 ASCII 路径再引用。
- **表格用 `DataGridView` 而不是 `ListView`**：前者原生支持按列右对齐、斑马纹、复选框列，全部是标准控件，不需要 owner-draw —— 在没有可视环境可验证的前提下，出错风险最低。
- **界面毫不复制引擎逻辑**：界面只 dot-source `src\Common.ps1` 取 `Format-Size` / `Get-CleanerCount` 两个显示用函数，清理相关的一切仍然只有 `src\` 一份实现。

### 修复（开发过程中发现）

1. **调色板命名为 `$C` 与循环变量 `$c` 冲突** —— PowerShell 变量名大小写不敏感，`foreach ($c in $Candidates)` 会把调色板整个覆盖成候选对象，之后所有 `$C.Bg` 取到 null，赋给 `BackColor` 时抛 `无法将空值转换为类型 System.Drawing.Color`。已重命名为 `$Pal` / `$Fonts`，并在代码里写明原因。
2. **`$PSScriptRoot` 在函数体内不可靠** —— 在 job 反序列化上下文里调用 `Invoke-CleanerAppTask` 时可能为空。改为在加载期把根目录存进 `$script:EngineRoot`，函数内不再重算。
3. **图标校验器输出用了中文** —— 经控制台管道后按 GBK 解码成乱码，导致断言信息完全不可读。改为纯 ASCII 输出。
4. **图标校验改用几何采样** —— 原先按颜色直方图分类，而本图标刻意让对勾与背景渐变深色端同为 `#1D4ED8`，两者无法按颜色区分。改为在预期位置采样（盾牌处必须白、对勾处必须非白、盾牌上下必须是背景、圆角处必须透明），并只在 256 层做几何断言、其余尺寸做结构存在性断言。

## [1.0.1] - 2026-09-26

一轮针对"测试没覆盖到的路径"的代码审查，修掉 6 处问题。全部补了回归断言，安全断言从 31 项增加到 39 项。

### 修复

1. **`targetType` 与实际类型不符时不校验**（`src/Rules.ps1`）
   一条声明为 `directory` 的字面路径规则若指向文件，会被裁决为"通过"，然后以 0 字节的体积被删除；走回收站回退实现（`DeleteDirectory`）时还会直接报错。
   现在裁决阶段新增实际类型校验，不一致返回 `E_TYPE`。→ T10a / T10b

2. **执行前只复查"路径是否存在"，不复查保护裁决**（`src/Cleaner.ps1`）
   扫描到执行之间存在时间窗（用户阅读清单、生成报告）。期间路径可能被换成目录联接，或被换成完全不同的东西。`docs/SAFETY.md` 的 F9 声称"逐条复查"，实际只查了存在性——文档与实现不一致。
   现在每条在真正删除前重跑存在性 + 实际类型 + 完整四道保护裁决。→ T10d（并配 T10d2 对照断言，确保不是"工具空转"）

3. **`-DeleteMethod Auto` 在回收站能力不可用时不中止**（`src/Cleaner.ps1`）
   `RecycleBin` 分支会中止，`Auto` 分支不会，两者行为不一致。虽然任何分支都不会"退化为永久删除"，但没有提前失败。
   现在两条路径统一：探测不到回收站能力即中止。另清理了一处死逻辑（`$effectiveMethod` 永远不可能被赋值为 `'Auto'`）。

4. **过宽白名单无任何提示**（`src/Rules.ps1` + `src/Common.ps1`）
   `{ROOT}\**` 这类模式会匹配根目录下几乎所有条目——虽然用户是显式写的，但这等于架空了"白名单=指向具体东西"的前提。
   现在加载规则时识别并告警，提示补上字面量锚点。→ T10c1–T10c3

5. **`Test-FileLocked` 是死代码**（`src/Cleaner.ps1`）
   函数写好了却从未调用。现在用于文件型目标：删除前检测独占占用，被占用则跳过并给出明确原因，而不是交给删除接口报一个含混的错误。→ T10e

6. **静态检查会校验运行期产物**（`tests/Test-Syntax.ps1`）
   原先会扫描 `tests\.reports\*.json` 与 `tests\sandbox-expectations.json`（均在 `.gitignore` 中）。这意味着一份本地残留的旧产物就能让 CI 无谓地变红。
   现在排除沙箱、报告目录与期望清单，静态检查的作用域收敛到源码。

## [1.0.0] - 2026-09-26

首个可用版本。

### 新增

- 入口脚本 `Clean-DDrive.ps1`，默认 `Scan` 只读模式，`-Mode Clean` 才执行清理
- 白名单规则引擎（`src/Rules.ps1`）：14 条内置规则，支持 `rules.local.json` 按 id 覆盖
- 一次性目录索引 + 内存匹配（`src/Scanner.ps1`），避免每条规则全盘重扫
- 四道保护拦截：具体路径 / 目录名 / 路径段 / 扩展名，无绕过机制
- 重解析点（junction / symlink）双重拒绝：遍历不进入，裁决再拦一次
- 回收站删除（`src/Cleaner.ps1`）：`SHFileOperation` + `FOF_ALLOWUNDO`，无弹窗不阻塞；`Microsoft.VisualBasic.FileIO.FileSystem` 作为回退
- 删除后 `Test-Path` 二次校验，防止「接口报成功但没删掉」
- HTML / JSON 双报告（`src/Reporter.ps1`），HTML 含安全防线记录与还原指引
- 按报告从回收站批量还原（`src/Restore.ps1` + `Restore-FromRecycleBin.ps1`）
- 深度截断告警：因 `-MaxDepth` 未能下探到底时，在日志 / 控制台 / 报告三处告警
- 测试套件：`tests/New-Sandbox.ps1`（沙箱）、`tests/Run-Tests.ps1`（31 项安全断言）、`tests/Test-Syntax.ps1`（语法 + BOM + JSON 检查）

### 开发过程中修复的缺陷

这些都是在自测中被断言抓出来的真实问题，记录在此以免回归。

1. **`.ps1` 缺少 UTF-8 BOM** —— Windows PowerShell 5.1 会把无 BOM 的 UTF-8 脚本按 ANSI 解码，中文变乱码并直接引发语法错误。现全部改为 UTF-8 with BOM，并把 BOM 校验纳入 `Test-Syntax.ps1`。
2. **`-Debug` 参数与 `CmdletBinding` 内置公共参数冲突** —— 声明同名参数会让整个脚本无法运行。入口脚本的详细模式参数改名 `-Trace`。
3. **`neverTouchPaths` 中的裸 `{ROOT}` 拦下全部候选** —— 判定语义是「等于或位于其下」，导致扫描结果恒为空却无任何报错。已从默认配置移除，并在加载时自动剔除同类条目 + 告警。
4. **`.db` 扩展名保护误伤 `Thumbs.db`** —— 缩略图缓存规则永远无法生效。新增 `neverTouchExtExceptions` 文件名级例外。
5. **默认 `MaxDepth = 6` 不足以覆盖真实缓存路径** —— 浏览器缓存约 9 层、JetBrains 约 8 层，会被静默漏掉。默认提高到 10，并新增深度截断告警。测试新增 `T2b` / `T2c` 守住。
6. **`@($List[object]).Count` 抛 `ArgumentException: 参数类型不匹配`** —— PowerShell 5.1 的数组子表达式作用在泛型实参为 `object` 的 `List<T>` 上会失败，而 `List[string]` / `ArrayList` / 普通数组都正常，因此极难察觉。所有集合计数改走 `Get-CleanerCount`。
7. **`New-Object 'object[]' N` 构造的数组被 `ConvertTo-Json` 序列化成 `{"value":[...],"Count":N}`** —— CLR 类型同样是 `System.Object[]`，但带 `PSObject` 包装，导致下游 JSON 消费者读不到数组（同一份报告里用 `@()` + `+=` 构造的数组却是正常格式）。改用泛型 List 收集 + 强转剥离包装，并新增 `T9e` / `T9f` / `T9g` 三项回归守卫。
8. **`Add-Content` 逐行写日志偶发丢行** —— 改为常开 + `AutoFlush` 的 `StreamWriter`。审计型工具的日志不能缺行。
9. **`-Quiet` 模式下进度条仍污染 CI 输出** —— `-Quiet` 时同时设置 `$ProgressPreference = 'SilentlyContinue'`。
