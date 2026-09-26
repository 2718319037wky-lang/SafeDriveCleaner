# SafeDriveCleaner

白名单驱动的 Windows 磁盘安全清理工具。用 PowerShell 写，**默认只读**，真正执行时走回收站，随时可还原。

## 它解决什么问题

大多数「一键清理」脚本是黑名单式的：先全盘扫，把不认识的都当垃圾。问题是——**你不认识的东西，恰恰可能是你最不该删的东西**。仓库目录、数据库、虚拟机镜像、正在编辑的工程文件，都可能因为「不在排除名单里」而被干掉。

SafeDriveCleaner 反过来做：**只有 `config/rules.default.json` 里显式列出的路径才会成为候选**。不存在「因为没被排除所以被删掉」这种情况。

## 安全设计

| 机制 | 说明 |
|---|---|
| **默认只读** | 不加 `-Mode Clean`，永远不删任何东西。第一次跑就是一次纯扫描 + 出报告。 |
| **白名单制** | 规则文件里没有的路径，永远不会进入候选列表。 |
| **四道保护拦截** | 具体路径 / 目录名 / 路径段 / 扩展名，**没有任何绕过机制**——规则写错了也删不到受保护内容。 |
| **绝不跟随链接** | 目录联接（junction）与符号链接一律跳过。避免 `D:\cache -> C:\Users\...` 这种链接导致跨盘误删。 |
| **回收站删除** | 底层调 `SHFileOperation` + `FOF_ALLOWUNDO`，全程无弹窗、不阻塞。删错了可以还原。 |
| **年龄阈值** | 每条规则带 `minAgeDays`，只清理「最后修改早于 N 天」的内容，避免删掉正在使用的缓存。 |
| **深度截断告警** | 若因 `-MaxDepth` 限制没能下探到底，会明确告警而不是静默漏报。 |
| **四份留痕** | 控制台、日志、JSON 报告、HTML 报告，每一条操作都可事后审计。 |

## 快速开始

```powershell
# 1) 先只读扫描（什么都不删），生成 HTML 报告
.\Clean-DDrive.ps1

# 2) 演练清理流程，逐条展示将要删除的内容，但不实际删除
.\Clean-DDrive.ps1 -Mode Clean -DryRun

# 3) 确认无误后真正执行（交互式输入 YES 确认，删除到回收站）
.\Clean-DDrive.ps1 -Mode Clean
```

只清理某几类：

```powershell
# 只清浏览器缓存和缩略图缓存
.\Clean-DDrive.ps1 -Mode Clean -Categories 浏览器缓存,缩略图缓存

# 清 D 盘但跳过崩溃转储（你正在排查崩溃问题时）
.\Clean-DDrive.ps1 -Mode Clean -ExcludeRule sys-crashdumps

# 非交互执行（自动化用，务必先 Scan + DryRun 验证过）
.\Clean-DDrive.ps1 -Mode Clean -Yes
```

## 主要参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Drive` | `D` | 目标盘符 |
| `-RootPath` | — | 直接指定根目录，用于测试或清理非盘符目录树 |
| `-Mode` | `Scan` | `Scan` 只读 / `Clean` 执行清理 |
| `-Categories` | 全部 | 按分类筛选规则 |
| `-IncludeRule` / `-ExcludeRule` | — | 按规则 id 定向包含 / 排除 |
| `-MinAgeDays` | 各规则自定 | 覆盖所有规则的年龄阈值，`0` 表示不限制 |
| `-MaxDepth` | `10` | 目录索引最大深度。真实缓存路径很深（浏览器缓存约 9 层），默认值不能太小 |
| `-DeleteMethod` | `Auto` | `Auto`/`RecycleBin` 走回收站；`Permanent` 永久删除（需额外输入 `PERMANENT` 确认） |
| `-DryRun` | — | 走完整流程但不真删 |
| `-Yes` | — | 跳过交互确认（自动化用） |
| `-SkipRecycleBin` | — | 跳过「本盘回收站」这条规则 |
| `-Quiet` / `-Trace` | — | 安静模式 / 详细追踪模式（`-Trace` 不能叫 `-Debug`，会和内置公共参数冲突） |

## 内置规则

共 14 条，全部集中在 `config/rules.default.json`，可自由增删改：

| 分类 | 覆盖内容 |
|---|---|
| 系统临时 | `\Temp` `\tmp` `\Windows\Temp` |
| 崩溃转储 | `\CrashDumps` `\Windows\LiveKernelReports` |
| 缩略图缓存 | `Thumbs.db` `ehthumbs.db` `IconCache.db` |
| 包管理器缓存 | npm / yarn / pnpm、pip / conda / poetry / uv、Gradle / Maven、NuGet、Cargo / Go / Composer |
| IDE 缓存 | JetBrains（caches / index / log / tmp）、VS Code（CachedData 等）、Visual Studio ComponentModelCache |
| 浏览器缓存 | Chrome / Edge / Brave / Chromium 的 Cache、Code Cache、GPUCache、Service Worker CacheStorage；Firefox 的 cache2 |
| 回收站 | 指定盘的回收站（风险标记为 high，执行前请先打开回收站看一眼） |

**规则格式**：

```json
{
  "id": "pkg-node",
  "name": "npm / yarn / pnpm 缓存",
  "category": "包管理器缓存",
  "enabled": true,
  "targetType": "directory",
  "minAgeDays": 7,
  "risk": "medium",
  "patterns": ["{ROOT}\\**\\npm-cache"],
  "note": "仅缓存，不影响 node_modules。"
}
```

- `{ROOT}` = 目标根目录，`{DRIVE}` = 盘符，环境变量（`%TEMP%` 等）同样可用
- `patterns` 支持 `*` `?` `**`（`**` 跨任意层级目录）
- `targetType`：`directory` / `file` / `recycleBin`

**本地覆盖**：新建 `config/rules.local.json`，按 `id` 覆盖默认规则或追加新规则。该文件已在 `.gitignore` 中。

## 保护清单

`config/protected.default.json` 是最后一道防线，四道拦截互不干扰、无绕过机制：

1. `neverTouchPaths` —— 目标等于该路径或位于其下 → 拦截
2. `neverTouchDirectoryNames` —— 目标自身最后一级名字命中 → 拦截
3. `neverTouchPathSegments` —— 路径中出现该目录段（`\Documents\` 等用户数据区）→ 拦截
4. `neverTouchExtensions` —— 文件扩展名命中 → 拦截

两处值得说明的设计：

- **不要把裸 `{ROOT}` 写进 `neverTouchPaths`**。判定语义是「等于或位于其下」，写进去等于拦下全部候选，会让扫描结果永远为空。引擎已加防御：检测到这种情况会自动剔除并告警。
- **`neverTouchExtExceptions`** 是文件名级例外（`Thumbs.db` 等三个），不是规则级绕过。因为 `.db` 在扩展名保护名单里，而缩略图缓存恰好叫 `Thumbs.db`，不做例外的话缩略图规则永远不生效。

## 报告与还原

每次运行都会在 `reports\` 下生成：

- `safedrivecleaner-<时间戳>.html` —— 人类可读，含分类汇总、清理明细、**安全防线记录**（哪些路径被保护规则拦下）
- `safedrivecleaner-<时间戳>.json` —— 机器可读，供脚本消费
- `safedrivecleaner-<时间戳>.log` —— 完整运行日志（含 `-Trace` 的调试信息）
- `latest.html` —— 最新报告的副本

> [`docs/example-report.html`](docs/example-report.html) 是用测试沙箱生成的示例报告，可直接打开预览效果。里面能看到「安全防线记录」一节长什么样 —— 它列出所有被保护规则拦下的路径，是审查保护规则是否合理的最快入口。

还原（仅当使用回收站删除时）：

```powershell
.\Restore-FromRecycleBin.ps1 -ReportPath .\reports\safedrivecleaner-20260926-220000.json -DryRun
.\Restore-FromRecycleBin.ps1 -ReportPath .\reports\safedrivecleaner-20260926-220000.json
```

> 自动还原依赖 Windows 本地化的「还原」动词，存在语言环境差异。任何一条失败都不影响其它条目；失败时请直接打开资源管理器「回收站」按文件名手动还原 —— 报告里记录了每一条的完整原始路径。

## 测试

```powershell
# 静态检查：语法 + UTF-8 BOM + JSON 合法性（不执行任何清理逻辑，CI 安全）
.\tests\Test-Syntax.ps1

# 安全断言测试：在沙箱目录树上完整跑一遍扫描 / 预演 / 删除
.\tests\Run-Tests.ps1
```

`Run-Tests.ps1` 会构建一个模拟「D 盘」的沙箱（`tests\.sandbox`），内含 13 个应当被命中的缓存目标，以及 12 个**必须活下来**的诱饵（`.git`、`node_modules`、`Documents`、`.sqlite`、`.vhdx` 等），外加两个指向沙箱外的 junction。共 39 项断言，其中最关键的是：

- `T1` Scan 模式零删除零新增（比对完整文件映射）
- `T3` 12 个受保护诱饵一个都没进候选
- `T8b` 清理后沙箱外（junction 指向）的内容零变化
- `T8c` 确实删除了白名单内容（防「空转也算通过」的假绿灯）
- `T10d` 执行前复查会重跑保护裁决（防住扫描到执行之间路径被掉包）
- `T10e` 被独占的文件被跳过且保留

## 已知限制

- 仅支持 Windows（依赖 `SHFileOperation` 与回收站语义）。需 Windows PowerShell 5.1 或 PowerShell 7。
- 深层 `**` 规则靠一次性目录索引实现；盘越大、`-MaxDepth` 越大，扫描越慢。建议先用 `-Categories` 缩小范围试跑。
- 扩展名保护是启发式的（比如 `.zip` 一律不碰），会漏掉一些本来可以安全清理的压缩缓存 —— 这是刻意的保守取舍。
- 回收站还原依赖 Shell 动词的本地化名称，可能在某些语言环境下找不到「还原」动作。
- 不做注册表清理、不做卸载残留清理 —— 那类操作与系统耦合面太大，与本项目「可控可还原」的定位不符。

## 许可

[MIT](LICENSE)
