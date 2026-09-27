# 更新日志

本项目的所有重要变更都记录在此文件。

## [1.1.2] - 2026-09-27

### 打包成「下载即用」的桌面 App 分发包

把现有桌面 App 打包成分发 zip + 一键启动 + 桌面入口，附用户视角的 README-APP.md。

- **`tools\make_dist.ps1`** —— 打包工具：拷贝必备文件到 `dist\stage-App-v<Version>\`、用 `System.IO.Compression.ZipFile` 压成 `SafeDriveCleaner-App-v<Version>.zip`、自检（解压列文件、所有 .ps1 BOM、app.ico 7 尺寸齐全）、输出 SHA256。`dist\` 加入 `.gitignore`。
- **`SafeDriveCleaner.cmd`**（zip 根目录）—— wrapper：从解压根目录双击即用，默认 `-Drive D -AutoScan`，找不到 PowerShell 时弹错说明。
- **`Install.cmd`**（zip 根目录）—— 一键创建桌面入口，等价于 `powershell -File tools\New-DesktopEntry.ps1 -AppDir %HERE%app`。
- **`README-APP.md`** —— 用户视角：三步上手、选盘、还原、系统需求、卸载、排错表。
- **`app\assets\app.ico`** —— 盾牌+对勾图标，7 尺寸（16/24/32/48/64/128/256），纯标准库 PNG/ICO 生成器（`tools\make_icon.py`）。

**修复**

- **`app\SafeDriveCleaner.vbs`** —— 原本是简单的复制粘贴式桌面入口，**有 bug**：启动时 `here = fso.GetParentFolderName(WScript.ScriptFullName)` 拿到的是桌面目录，**根本找不到 `SafeDriveCleaner.App.ps1`**。改为 vbs 模板 + 路径注入：`{{SDC_APP_DIR}}` 占位符由 `New-DesktopEntry.ps1` 替换为绝对路径。
- **`app\SafeDriveCleaner.cmd` / `app\SafeDriveCleaner.vbs`** —— 显式传 `-Drive D -AutoScan` 让「下载即用」的行为在启动器里明确；找不到 PowerShell / App.ps1 时弹 msgbox 而不是闪一下就走。
- **`tools\New-DesktopEntry.ps1`** —— 接受强制参数 `-AppDir`（不再瞎猜）；替换 `{{SDC_APP_DIR}}` 写桌面 vbs；交付自检里加占位符已替换的二次断言；非 ASCII 路径警告（PowerShell 没事，但图标关联可能失效）。
- **`tests\Test-Syntax.ps1`** —— `Test-IsGeneratedArtifact` 加上 `dist\stage-*` 排除：make_dist 拷出的副本与源码逐字节一致，不该让版本号唯一性检查误判成「两处」。
- **`tests\Test-Ui.ps1`** —— jsdom 缺失时本意是 SKIP，但脚本里 `$ErrorActionPreference='Stop'` 让 `node -e "require.resolve('jsdom')"` 的 stderr 触发 NativeCommandError 直接 exit 1。改为探针时临时切到 `'Continue'`，让 jsdom 缺失正确走 SKIP。

### 新增「可清理容量占该盘总容量的百分比」指标

新增「可清理容量占该盘总容量的百分比」指标，四处口径一致：同一组公共助手函数算出，不各写一份。

### 新增

- **三个公共助手**（`src\Common.ps1`）：
  - `Get-CleanerVolumeTotalBytes` —— 从任意路径取所在卷总容量，取不到返回 `$null`（绝不返回 0，避免"除以 0"被当成"占比 0%"）；
  - `Get-CleanerSharePercent` —— 算占比，分母无效（`$null` / 0）时返回 `$null` 而不是 0；
  - `Format-Percent` —— 展示层格式化，`$null` 显示占位符 `—`，不显示误导性的 `0.0%`。
- **HTML / JSON 报告**（`src\Reporter.ps1`）—— 概览卡片与 JSON 字段新增「可清理占比」（`CleanablePercent`）与卷总容量（`DriveTotalBytes`）。
- **桌面版**（`app\SafeDriveCleaner.App.ps1`）—— 统计卡从 5 张扩到 6 张，新增「占总容量」；数据由 `app\Worker.ps1` 从引擎结果带出。
- **CLI 汇总行**（`Clean-DDrive.ps1`）—— 扫描完成那句从「可清理 X」扩为「可清理 X · 占本盘 Y%」。

### 测试

- `T9h–T9j`：卷容量探测成功路径、报告 JSON 字段与卡片渲染（数值与 JSON 一致）、占比随输入变化（排除写死/恒定的假实现）。
- `T9k2 / T9k3`：占比格式化边界 —— 分母无效（`$null` / 0）返回 `$null`、显示占位符 `—`，绝不出现误导性的 `0.0%`。
  其中刻意**不**断言「占比必须 > 0」—— 几 KB 的沙箱装在 931 GB 的盘上，真实占比本来就是 0.0%；要防的是"恒为常量的假绿灯"，由 T9i2 的对照断言承担。

## [1.1.1] - 2026-09-27

新增单文件界面原型 `app/ui.html`，并把它的状态机纳入自动测试。顺带修掉两处界面缺陷与一处版本号漂移。

### 新增

- **`app\ui.html`** —— 单文件、零依赖的界面原型，双击即可在浏览器打开，用于在不安装任何东西也不接触本机文件的前提下预览完整交互：扫描 → 分类筛选/排序 → 勾选 → 口令确认 → 清理 → 逐条还原。全部为模拟数据，不访问文件系统、不发网络请求（唯一的 `url()` 是内联 `data:` 图标）。交互语义与桌面版对齐：**已处理路径切规则不复活**、**报告以扫描快照为准**。
- **`tests\Test-Ui.ps1` + `tests\ui\smoke.js`** —— 在 jsdom 里把 ui.html 的内联脚本真跑起来，驱动 94 项状态机断言。jsdom 为可选依赖，缺失时脚本以 SKIP 退出，不影响其它测试（`npm install jsdom --no-save` 启用）。
- **静态检查新增「内联 JavaScript 语法检查」** —— 用 `node --check` 解析 HTML 内联脚本。语法写错会让整页静默失效（按钮点了没反应），而 HTML 本身仍能正常打开，所以必须单独解析一次。
- **静态检查新增「版本号单一来源检查」** —— 断言全仓库版本字面量恰好一处且位于 `src\Common.ps1`。
- CI 增加 jsdom 安装与界面状态机验证步骤；失败产物同时上传 `.transcript.txt` 与 `.ui-smoke.txt`。

### 修复

1. **清理 / 还原后侧栏候选徽标不刷新**（`app/ui.html`）
   `doClean` 与 `restoreOne` 都只刷新了统计卡片、候选表、报告与安全防线，漏了导航徽标 —— 清掉几条之后侧栏数字仍是旧值。
   根因是"刷新清单"散落在七八处且各写一份。现在统一收敛到一个 `refreshAll()`，任何改变候选集或清理记录的操作都走它。→ T45 / T57

2. **切换盘符后旧盘候选残留**（`app/ui.html`）
   换盘只把 `S.scanned` 置回 `false`，却没有清空 `S.candidates`、没有丢弃扫描快照、也没有刷新徽标。结果主区显示「还没有扫描结果」，侧栏却仍挂着上一个盘的候选数 —— 界面自相矛盾，且 `S.candidates` 里留着已失效的数据。
   现在换盘等同回到未扫描状态：清候选、丢快照、刷新全部面板。→ T84–T88

3. **版本号三处各写一份，已经漂移**（`src\Common.ps1` / `Clean-DDrive.ps1` / `app\*.ps1` / `src\Reporter.ps1`）
   CLI 停在 `1.0.1`，桌面版已是 `1.1.0`，而 `New-CleanerReportObject` 的参数默认值还硬编码着 `1.0.0` —— 任何不显式传 `-Version` 的调用都会在报告里写上一个过期版本号。
   现在版本号只在 `src\Common.ps1` 定义一次，其余位置一律取用；并由静态检查断言这一点（这条守卫在加进来时当场就抓出了 `Reporter.ps1` 那处）。

### 验证方式

除 94 项状态机断言外，界面还用无头 Chrome 在 4 个状态下截图并做像素级校验：

- 零运行时错误（注入错误收集器后 `--dump-dom`，`ERRDUMP>><<` 为空）
- 内联 `onclick="runScan()"` 在真实浏览器中确实生效（jsdom 的 `outside-only` 模式测不到这条路径）
- `:root` 里 12 个非 hover 设计令牌全部在实际像素中命中，含 `#2563EB` 按钮、`#EEF3FF` 选中态、`#B91C1C` 高风险标记

> 一个记录在案的渲染陷阱：`backdrop-filter` 在 headless + SwiftShader 下会把整层一起模糊（截图里连弹窗文字都是糊的）。关掉它即恢复清晰 —— 属截图伪影，不是页面缺陷。遮罩本身正确：出现量最高的 `#9197a5` 与 `#1c4399` 正是 `rgba(16,24,40,.42)` 叠在 `#EEF3FF` 与 `#2563EB` 上的计算结果。

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
