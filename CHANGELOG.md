# 更新日志

本项目的所有重要变更都记录在此文件。

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
