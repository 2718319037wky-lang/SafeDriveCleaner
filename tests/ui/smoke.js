'use strict';
/*
 * app/ui.html 的无头验证（jsdom 层）
 *
 * 为什么需要它：ui.html 的交互逻辑全写在内联 <script> 里，没有构建步骤、没有类型检查。
 * 语法错了会被 Test-Syntax.ps1 挡住，但"语法正确、逻辑错"这一类只有真的跑起来才会暴露。
 *
 * 覆盖：安装期无异常 -> 只读扫描 -> 选择/反选 -> 确认弹窗口令校验 -> 清理 -> 还原 ->
 *       规则开关 -> 再次扫描，并断言几处关键不变量：
 *   1) 已清理的路径在切换规则后不复活
 *   2) 报告以「扫描快照」为准，不随清理而变空
 *   3) 两种空态（"所有规则都已停用" vs "候选已全部处理完毕" vs "未发现可清理目标"）能正确区分
 *   4) 清理/还原/换盘后，侧栏徽标与统计卡片必须同步刷新
 *
 * 依赖：jsdom（可选）。缺了就让 tests/Test-Ui.ps1 跳过，不影响其它测试。
 * 用法：node tests/ui/smoke.js <报告输出路径>
 *      （路径含中文时务必用命令行传参，别写进脚本字面量——PS 5.1 会按 ANSI 解码导致路径失效）
 */
const fs = require('fs');
const path = require('path');

const REPORT = process.argv[2] || path.join(process.env.TEMP || '.', 'ui-smoke.txt');
const HTML = path.resolve(__dirname, '..', '..', 'app', 'ui.html');

const { JSDOM } = require('jsdom');

/* ------------------------------------------------------------------ 极简断言收集器 */
const passes = [];
const fails = [];
function ok(name, cond, extra) {
  if (cond) { passes.push(name); }
  else {
    const detail = extra === undefined ? '' : '  <-- ' + JSON.stringify(extra);
    fails.push(name + detail);
  }
}

/* ------------------------------------------------------------------ 启动宿主 */
function boot(htmlPath, opts) {
  opts = opts || {};
  const raw = fs.readFileSync(htmlPath, 'utf8');
  const i = raw.indexOf('<script>');
  const j = raw.lastIndexOf('</script>');
  if (i < 0 || j < 0 || j < i) throw new Error('inline <script> not found in ' + htmlPath);
  const code = raw.slice(i + 8, j);
  /* 把脚本从 HTML 里摘掉，避免 jsdom 自己执行它（我们用 eval 精确控制执行时机） */
  const html = raw.slice(0, i) + raw.slice(j);

  const dom = new JSDOM(html, { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' });
  const w = dom.window;

  /* 驱动器检测：注入一份确定的检测结果，让断言不依赖本机真实盘符。
     ui.html 优先读 window.__SDC_DRIVES__（对应真实的 app/drives.js）。
     传 opts.drives === null 可模拟「三路探测全部失败」。 */
  w.__SDC_DRIVES__ = (opts.drives === null) ? undefined : (opts.drives || {
    schemaVersion: '1.0', source: 'detected', generatedAt: '2026-01-01 00:00:00', host: 'TEST-PC',
    drives: [
      { letter: 'C', root: 'C:\\', kind: 'fixed', label: '系统', format: 'NTFS', totalBytes: 512 * 1073741824, freeBytes: 64 * 1073741824 },
      { letter: 'D', root: 'D:\\', kind: 'fixed', label: '数据', format: 'NTFS', totalBytes: 931 * 1073741824, freeBytes: 319 * 1073741824 },
      { letter: 'E', root: 'E:\\', kind: 'removable', label: 'U盘', format: 'exFAT', totalBytes: 119 * 1073741824, freeBytes: 58 * 1073741824 }
    ]
  });

  /* jsdom 不提供 fetch。给一个必定失败的桩：injected 数据已经命中，
     走的正是「同目录 drives.js 已提供、无需联网」这条真实路径。 */
  w.fetch = function () { return Promise.reject(new Error('no network in smoke test')); };

  /* reduce-motion 打开：countUp 直接落值、doClean 的等待归零 —— 让断言确定性优先。
     动画与视觉状态由 tools/ 下的无头截图验证覆盖。 */
  const reduce = opts.reduceMotion !== false;
  w.matchMedia = function () {
    return {
      matches: reduce, media: '', onchange: null,
      addEventListener: function () {}, removeEventListener: function () {},
      addListener: function () {}, removeListener: function () {}
    };
  };

  /* 捕获定时器：同步测试里真实定时器不会触发，必须手动按延迟顺序推进 */
  const timers = [];
  w.setTimeout = function (fn, ms) { timers.push({ fn: fn, ms: ms || 0 }); return timers.length; };
  w.clearTimeout = function () {};
  w.setInterval = function () { return 0; };
  w.clearInterval = function () {};

  w.Element.prototype.getBoundingClientRect = function () {
    return { left: 0, top: 0, right: 1400, bottom: 900, width: 1400, height: 900, x: 0, y: 0 };
  };
  Object.defineProperty(w.HTMLElement.prototype, 'offsetWidth', { get: function () { return 1200; }, configurable: true });
  Object.defineProperty(w.HTMLElement.prototype, 'offsetHeight', { get: function () { return 800; }, configurable: true });

  const runtimeErrors = [];
  /* 探针：ui.html 的脚本是裸的顶层代码（未包 IIFE，因为 HTML 里用了内联 onclick
     依赖全局函数），所以把探针直接追加到同一段脚本尾部即可共享同一词法作用域。 */
  const probeCode = [
    'window.__probe = {',
    ' S:S, RULES:RULES, RULE_BY_ID:RULE_BY_ID, ALL_CANDIDATES:ALL_CANDIDATES,',
    ' PROT_HITS:PROT_HITS, LINK_SKIPS:LINK_SKIPS, TOO_NEW:TOO_NEW, TRUNCATED:TRUNCATED,',
    ' VIEWS:VIEWS, fmtSize:fmtSize, fmtNum:fmtNum,',
    ' DRV:DRV, DRIVE_KIND:DRIVE_KIND, driveAt:driveAt, selectDrive:selectDrive, dp:dp,',
    ' detectDrives:detectDrives, renderDrivePicker:renderDrivePicker, applyDrive:applyDrive,',
    ' openDrivePop:openDrivePop, closeDrivePop:closeDrivePop,',
    ' runScan:runScan, finishScan:finishScan, rebuildCandidates:rebuildCandidates,',
    ' makeSnapshot:makeSnapshot, doClean:doClean, restoreOne:restoreOne,',
    ' openConfirm:openConfirm, closeModal:closeModal, show:show,',
    ' renderCandidates:renderCandidates, renderReport:renderReport, renderDefense:renderDefense,',
    ' renderRules:renderRules, updStats:updStats, updDrive:updDrive, updNavBadges:updNavBadges,',
    ' view:function(){return curView;}',
    '};'
  ].join('');

  let bootError = null;
  try { w.eval(code + '\n;' + probeCode + '\n'); } catch (e) { bootError = e; }

  function flush(max) {
    const cap = max || 900;
    let guard = 0;
    while (timers.length && guard++ < cap) {
      timers.sort(function (a, b) { return a.ms - b.ms; });
      const t = timers.shift();
      try { t.fn(); } catch (e) { runtimeErrors.push(String((e && e.message) || e)); }
    }
    return guard;
  }

  return { dom: dom, w: w, doc: w.document, timers: timers, flush: flush, errors: runtimeErrors, probe: w.__probe, bootError: bootError };
}

function text(doc, id) { const e = doc.getElementById(id); return e ? e.textContent : '<missing:' + id + '>'; }
function inner(doc, id) { const e = doc.getElementById(id); return e ? e.innerHTML : '<missing:' + id + '>'; }
function fire(w, el, type) { el.dispatchEvent(new w.Event(type, { bubbles: true, cancelable: true })); }
function setInput(w, el, v) { el.value = v; fire(w, el, 'input'); }
function sum(a, f) { return a.reduce(function (s, x) { return s + f(x); }, 0); }

/* ================================================================== A：主流程 */
const r = boot(HTML);
const doc = r.doc;
const w = r.w;

ok('T1  内联脚本求值期无异常（含启动期全部 render* 调用）', !r.bootError, r.bootError && String(r.bootError.message));
ok('T2  探针已注入，可读到全局词法作用域状态', !!r.probe);

if (r.bootError || !r.probe) {
  finish();
} else {
  const P = r.probe;
  const S = P.S;

  ok('T3  规则数 14 条且初始全部启用',
    P.RULES.length === 14 && P.RULES.every(function (x) { return x.enabled; }),
    { n: P.RULES.length, on: P.RULES.filter(function (x) { return x.enabled; }).length });
  ok('T4  初始未扫描、候选为空', S.scanned === false && S.candidates.length === 0);
  ok('T5  导航徽标初始为 0 / 14 of 14',
    text(doc, 'nb-cand') === '0' && text(doc, 'nb-defense') === '0' && text(doc, 'nb-rules') === '14/14',
    { cand: text(doc, 'nb-cand'), def: text(doc, 'nb-defense'), rules: text(doc, 'nb-rules') });
  ok('T6  初始视图为 candidates，标题栏已填充',
    P.view() === 'candidates' && text(doc, 'tb-h1') === P.VIEWS.candidates.h);
  ok('T7  未扫描时候选区展示空态引导（含 onclick="runScan()"）',
    inner(doc, 'cand-stage').indexOf('还没有扫描结果') >= 0 && inner(doc, 'cand-stage').indexOf('runScan()') >= 0);
  ok('T8  未扫描时报告视图为空态', inner(doc, 'report-stage').indexOf('还没有报告') >= 0);
  ok('T9  统计卡片未扫描时全为占位符',
    text(doc, 'st-total') === '—' && text(doc, 'st-cand') === '—' && text(doc, 'st-prot') === '—');

  ok('T10 启动时登记了一次自动扫描定时器', r.timers.length === 1 && r.timers[0].ms === 520,
    r.timers.map(function (t) { return t.ms; }));
  r.flush();

  ok('T11 扫描结束后 scanned=true / scanning=false', S.scanned === true && S.scanning === false);
  ok('T12 推进过程中未捕获到运行时异常', r.errors.length === 0, r.errors.slice(0, 5));

  const expectCand = P.ALL_CANDIDATES.filter(function (c) {
    return P.RULE_BY_ID[c.ruleId].enabled && !S.cleanedPaths.has(c.path);
  }).length;
  ok('T13 候选数 = 白名单命中数（规则全开、无已清理）',
    S.candidates.length === expectCand, { got: S.candidates.length, want: expectCand });
  ok('T14 候选路径唯一（无重复条目）',
    new Set(S.candidates.map(function (c) { return c.path; })).size === S.candidates.length);
  ok('T15 扫描后选中集清空（不会继承上一次选择）', S.selected.size === 0);

  const snap = S.scanSnapshot;
  ok('T16 扫描快照已生成，count 与候选数一致', !!snap && snap.count === S.candidates.length,
    snap && { snapCount: snap.count, cand: S.candidates.length });
  ok('T17 快照 total 等于候选体积之和（逐字节）',
    snap && snap.total === sum(S.candidates, function (c) { return c.bytes; }),
    snap && { snapTotal: snap.total, sum: sum(S.candidates, function (c) { return c.bytes; }) });
  ok('T18 快照分类汇总按体积降序，且分类数等于去重分类数',
    snap && snap.cats.length === new Set(S.candidates.map(function (c) { return c.category; })).size &&
    snap.cats.every(function (c, i) { return i === 0 || snap.cats[i - 1].b >= c.b; }),
    snap && snap.cats.map(function (c) { return c.k + ':' + c.b; }));
  ok('T19 快照 rules 字段 = 启用规则数',
    snap && snap.rules === P.RULES.filter(function (x) { return x.enabled; }).length);

  ok('T20 候选表渲染行数 = 候选数', doc.querySelectorAll('#tbody tr').length === S.candidates.length,
    { rows: doc.querySelectorAll('#tbody tr').length, cand: S.candidates.length });
  ok('T21 表格 7 列（复选框/路径/分类/体积/文件数/未使用天数/风险）',
    doc.querySelectorAll('#tbody tr:first-child td').length === 7 &&
    doc.querySelectorAll('.tbl thead tr th').length === 7,
    { td: doc.querySelectorAll('#tbody tr:first-child td').length, th: doc.querySelectorAll('.tbl thead tr th').length });
  ok('T22 统计卡片落到实际数值', text(doc, 'st-cand') === P.fmtNum(S.candidates.length) && text(doc, 'st-total') === P.fmtSize(snap.total),
    { cand: text(doc, 'st-cand'), total: text(doc, 'st-total') });
  ok('T23 统计副标题说明白名单命中数', text(doc, 'st-total-s') === '白名单命中 ' + S.candidates.length + ' 项',
    text(doc, 'st-total-s'));
  ok('T24 导航徽标：候选数与安全防线数同步',
    text(doc, 'nb-cand') === String(S.candidates.length) &&
    text(doc, 'nb-defense') === String(P.PROT_HITS.length + P.LINK_SKIPS.length + P.TOO_NEW.length + P.TRUNCATED.length),
    { cand: text(doc, 'nb-cand'), def: text(doc, 'nb-defense') });
  ok('T25 已扫描且有候选时底部操作栏可见', doc.getElementById('actionbar').hidden === false);
  ok('T26 反空转对照：有候选时不会误显示"所有规则都已停用"',
    inner(doc, 'cand-stage').indexOf('所有规则都已停用') < 0);

  /* --- 全选 / 反选 / 清空 --- */
  doc.getElementById('btn-all').click();
  ok('T27 全选后选中数 = 候选数，清理按钮可用',
    S.selected.size === S.candidates.length && doc.getElementById('btn-clean').disabled === false,
    { sel: S.selected.size, cand: S.candidates.length });
  doc.getElementById('btn-invert').click();
  ok('T28 反选后选中集为空（全选再反选应归零）', S.selected.size === 0);
  doc.getElementById('btn-all').click();
  doc.getElementById('btn-none').click();
  ok('T29 清空选择后清理按钮禁用', S.selected.size === 0 && doc.getElementById('btn-clean').disabled === true);

  /* --- 确认弹窗 --- */
  P.openConfirm();
  ok('T30 无选中时打开确认弹窗应被拒绝（弹窗不渲染）', inner(doc, 'modalRoot') === '');

  S.selected.add(S.candidates[0].id);
  S.selected.add(S.candidates[1].id);
  P.openConfirm();
  ok('T31 有选中时弹窗渲染出输入框与确认按钮', !!doc.getElementById('mInput') && !!doc.getElementById('mOk'));
  ok('T32 确认按钮初始禁用（未输入口令）', doc.getElementById('mOk').disabled === true);
  ok('T33 弹窗列出目标条数与根目录',
    inner(doc, 'modalRoot').indexOf('2 项') >= 0 && inner(doc, 'modalRoot').indexOf('目标根目录') >= 0);

  setInput(w, doc.getElementById('mInput'), 'no');
  ok('T34 输入错误口令：按钮保持禁用且输入框标记为错误',
    doc.getElementById('mOk').disabled === true && doc.getElementById('mInput').classList.contains('bad'));
  setInput(w, doc.getElementById('mInput'), 'yes');
  ok('T35 口令大小写不敏感：输入 yes 即解锁', doc.getElementById('mOk').disabled === false);
  setInput(w, doc.getElementById('mInput'), 'YES');
  ok('T36 输入 YES 保持解锁且错误标记清除',
    doc.getElementById('mOk').disabled === false && !doc.getElementById('mInput').classList.contains('bad'));

  doc.getElementById('method').value = 'permanent';
  fire(w, doc.getElementById('method'), 'change');
  P.closeModal();
  P.openConfirm();
  ok('T37 永久删除模式要求输入 PERMANENT', inner(doc, 'modalRoot').indexOf('PERMANENT') >= 0);
  setInput(w, doc.getElementById('mInput'), 'YES');
  ok('T38 永久删除模式下 YES 不足以解锁（口令必须升级）', doc.getElementById('mOk').disabled === true);
  setInput(w, doc.getElementById('mInput'), 'PERMANENT');
  ok('T39 永久删除模式下输入 PERMANENT 解锁', doc.getElementById('mOk').disabled === false);
  doc.getElementById('method').value = 'recycle';
  fire(w, doc.getElementById('method'), 'change');
  P.closeModal();

  /* --- 执行清理（回收站） --- */
  const sel2 = S.candidates.slice(0, 2);
  const freed = sum(sel2, function (c) { return c.bytes; });
  const beforeUsed = S.driveUsedGB;
  const beforeCand = S.candidates.length;
  const beforeSnapTotal = S.scanSnapshot.total;
  S.selected.clear();
  sel2.forEach(function (c) { S.selected.add(c.id); });
  P.doClean(sel2, false, false);
  r.flush();

  ok('T40 清理后候选数按选中数减少', S.candidates.length === beforeCand - sel2.length,
    { before: beforeCand, after: S.candidates.length, n: sel2.length });
  ok('T41 被清理路径登记进 cleanedPaths（切规则时不复活）',
    sel2.every(function (c) { return S.cleanedPaths.has(c.path); }));
  ok('T42 清理记录追加到 S.cleaned 头部且状态为「已删除」',
    S.cleaned.length >= sel2.length && S.cleaned[0].status === '已删除' && S.cleaned[0].method === 'recycle',
    { n: S.cleaned.length, s0: S.cleaned[0] && S.cleaned[0].status });
  ok('T43 选中集被清空，避免重复清理', S.selected.size === 0);
  ok('T44 已用空间按释放量精确减少',
    Math.abs((beforeUsed - S.driveUsedGB) - freed / (1024 * 1024 * 1024)) < 1e-9,
    { delta: beforeUsed - S.driveUsedGB, want: freed / (1024 * 1024 * 1024) });
  ok('T45 清理后侧栏候选徽标同步刷新（不残留旧数字）',
    text(doc, 'nb-cand') === String(S.candidates.length),
    { badge: text(doc, 'nb-cand'), cand: S.candidates.length });
  ok('T46 清理后统计卡片与候选数一致',
    text(doc, 'st-cand') === P.fmtNum(S.candidates.length) && text(doc, 'st-total-s') === '白名单命中 ' + S.candidates.length + ' 项',
    { st: text(doc, 'st-cand'), sub: text(doc, 'st-total-s') });

  P.rebuildCandidates();
  ok('T47 关键：切换规则重建候选时，已清理路径不复活',
    S.candidates.length === beforeCand - sel2.length &&
    sel2.every(function (c) { return !S.candidates.some(function (x) { return x.path === c.path; }); }),
    { cand: S.candidates.length });

  ok('T48 关键：清理后扫描快照 total 不变（报告不随清理变空）',
    S.scanSnapshot.total === beforeSnapTotal, { now: S.scanSnapshot.total, before: beforeSnapTotal });
  P.renderReport();
  ok('T49 关键：清理后报告仍显示扫描时的合计体积',
    inner(doc, 'report-stage').indexOf(P.fmtSize(beforeSnapTotal)) >= 0);
  ok('T50 反空转对照：报告不会误报"未命中任何白名单目标"',
    inner(doc, 'report-stage').indexOf('本次扫描未命中任何白名单目标') < 0);
  ok('T51 报告清理明细出现还原入口（回收站方式才可还原）',
    doc.querySelectorAll('#report-stage [data-restore]').length > 0,
    doc.querySelectorAll('#report-stage [data-restore]').length);

  /* --- 还原 --- */
  const recId = S.cleaned[0].id;
  const recPath = S.cleaned[0].path;
  const usedBeforeRestore = S.driveUsedGB;
  const candBeforeRestore = S.candidates.length;
  P.restoreOne(recId);
  ok('T52 还原后记录状态变为「已还原」', S.cleaned.find(function (x) { return x.id === recId; }).status === '已还原');
  ok('T53 还原后该路径从 cleanedPaths 移除（可再次成为候选）', !S.cleanedPaths.has(recPath));
  ok('T54 还原后条目回到候选清单', S.candidates.length === candBeforeRestore + 1,
    { before: candBeforeRestore, after: S.candidates.length });
  ok('T55 还原后已用空间回补', S.driveUsedGB > usedBeforeRestore);
  ok('T56 还原后候选按体积降序保持有序',
    S.candidates.every(function (c, i) { return i === 0 || S.candidates[i - 1].bytes >= c.bytes; }));
  ok('T57 还原后侧栏候选徽标同步刷新',
    text(doc, 'nb-cand') === String(S.candidates.length),
    { badge: text(doc, 'nb-cand'), cand: S.candidates.length });

  /* --- 规则开关与两种空态的区分 --- */
  const ruleCount = P.RULES.length;
  S.selected.clear();
  S.candidates.slice(0, 2).forEach(function (c) { S.selected.add(c.id); });
  doc.getElementById('btn-rules-none').click();
  ok('T58 停用全部规则后候选为空、选中集清空', S.candidates.length === 0 && S.selected.size === 0);
  ok('T59 停用全部规则时文案为「所有规则都已停用」（与「未命中」区分开）',
    inner(doc, 'cand-stage').indexOf('所有规则都已停用') >= 0, inner(doc, 'cand-stage').slice(0, 120));
  ok('T60 导航徽标变为 0/' + ruleCount, text(doc, 'nb-rules') === '0/' + ruleCount, text(doc, 'nb-rules'));
  doc.getElementById('btn-rules-all').click();
  ok('T61 重新启用全部规则后候选恢复，且已清理路径仍不出现',
    S.candidates.length === P.ALL_CANDIDATES.length - S.cleanedPaths.size,
    { cand: S.candidates.length, all: P.ALL_CANDIDATES.length, cleaned: S.cleanedPaths.size });
  ok('T62 规则全开后有候选时不会误显示「所有规则都已停用」',
    inner(doc, 'cand-stage').indexOf('所有规则都已停用') < 0);

  S.selected.clear();
  S.candidates.forEach(function (c) { S.selected.add(c.id); });
  const allSel = S.candidates.slice();
  P.doClean(allSel, false, false);
  r.flush();
  ok('T63 清空全部候选后 candidate 为空且 cleanedPaths 覆盖全部命中',
    S.candidates.length === 0 && S.cleanedPaths.size === P.ALL_CANDIDATES.length,
    { cand: S.candidates.length, cleaned: S.cleanedPaths.size });
  ok('T64 全部处理完的文案与「未发现可清理目标」区分开',
    inner(doc, 'cand-stage').indexOf('候选已全部处理完毕') >= 0 &&
    inner(doc, 'cand-stage').indexOf('未发现可清理目标') < 0);
  ok('T65 全部处理完后提供跳转报告的入口（onclick="show(\'report\')"）',
    inner(doc, 'cand-stage').indexOf("show('report')") >= 0);
  ok('T66 全部处理完后操作栏隐藏（不留全禁用按钮的空壳）',
    doc.getElementById('actionbar').hidden === true);

  /* --- 安全防线视图 --- */
  P.renderDefense();
  const nDef = P.PROT_HITS.length + P.LINK_SKIPS.length + P.TOO_NEW.length + P.TRUNCATED.length;
  ok('T67 安全防线列出全部保护拦截条目',
    doc.querySelectorAll('#def-list .hit').length === P.PROT_HITS.length,
    { got: doc.querySelectorAll('#def-list .hit').length, want: P.PROT_HITS.length });
  ok('T68 安全防线列出联接跳过 / 年龄过滤 / 深度截断',
    doc.querySelectorAll('#def-other .hit').length === nDef - P.PROT_HITS.length,
    { got: doc.querySelectorAll('#def-other .hit').length, want: nDef - P.PROT_HITS.length });
  ok('T69 深度截断条目带明确告警文案（不静默漏报）',
    inner(doc, 'def-other').indexOf('不静默漏报') >= 0);

  /* --- 视图切换 --- */
  P.show('rules');
  ok('T70 切换到规则视图后标题与徽标同步', P.view() === 'rules' && text(doc, 'tb-h1') === P.VIEWS.rules.h);
  P.show('safety');
  ok('T71 切换到安全说明视图', P.view() === 'safety' && text(doc, 'tb-h1') === P.VIEWS.safety.h);
  P.show('candidates');
  ok('T72 切回候选视图', P.view() === 'candidates');
}

/* ================================================================== B：演练 / 永久删除 */
{
  const rb = boot(HTML);
  const docb = rb.doc;
  const Pb = rb.probe;
  ok('T73 第二个实例同样无求值期异常', !rb.bootError, rb.bootError && String(rb.bootError.message));
  if (Pb) {
    rb.flush();
    const Sb = Pb.S;
    const sel = Sb.candidates.slice(0, 3);
    const candBefore = Sb.candidates.length;
    const cleanedBefore = Sb.cleanedPaths.size;
    const usedBefore = Sb.driveUsedGB;

    Sb.selected.clear();
    sel.forEach(function (c) { Sb.selected.add(c.id); });
    Pb.doClean(sel, false, true);
    rb.flush();
    ok('T74 演练模式：候选集不变', Sb.candidates.length === candBefore,
      { before: candBefore, after: Sb.candidates.length });
    ok('T75 演练模式：cleanedPaths 不变（不会误标为已处理）', Sb.cleanedPaths.size === cleanedBefore);
    ok('T76 演练模式：已用空间不变', Sb.driveUsedGB === usedBefore);
    ok('T77 演练模式：记录状态为「预演」而非「已删除」',
      Sb.cleaned.length === sel.length && Sb.cleaned.every(function (x) { return x.status === '预演'; }),
      Sb.cleaned.map(function (x) { return x.status; }));
    ok('T78 演练模式的记录不提供还原按钮（没东西可还原）',
      docb.querySelectorAll('#report-stage [data-restore]').length === 0,
      docb.querySelectorAll('#report-stage [data-restore]').length);

    const sel2 = Sb.candidates.slice(0, 2);
    Sb.selected.clear();
    sel2.forEach(function (c) { Sb.selected.add(c.id); });
    Pb.doClean(sel2, true, false);
    rb.flush();
    ok('T79 永久删除：记录 method=permanent、状态「已删除」',
      Sb.cleaned[0].method === 'permanent' && Sb.cleaned[0].status === '已删除',
      { m: Sb.cleaned[0].method, s: Sb.cleaned[0].status });
    Pb.renderReport();
    ok('T80 永久删除的明细不提供还原按钮（明确不可还原）',
      docb.querySelectorAll('#report-stage [data-restore]').length === 0,
      docb.querySelectorAll('#report-stage [data-restore]').length);
    ok('T81 永久删除仍登记 cleanedPaths，防止复活',
      sel2.every(function (c) { return Sb.cleanedPaths.has(c.path); }));
  }
}

/* ================================================================== C：换盘重置 */
{
  const rc = boot(HTML);
  const docc = rc.doc;
  const Pc = rc.probe;
  ok('T82 第三个实例无求值期异常', !rc.bootError, rc.bootError && String(rc.bootError.message));
  if (Pc) {
    rc.flush();
    const Sc = Pc.S;
    ok('T83 扫描完成后按钮文案变为「重新扫描」', text(docc, 'scan-label') === '重新扫描', text(docc, 'scan-label'));
    const before = Sc.candidates.length;
    Pc.selectDrive('C');
    ok('T84 切换盘符后扫描态重置、候选清空、选中清空',
      Sc.scanned === false && Sc.candidates.length === 0 && Sc.selected.size === 0,
      { scanned: Sc.scanned, cand: Sc.candidates.length, scannedBefore: before });
    ok('T85 换盘后侧栏徽标归零，不再残留上一个盘的数字',
      text(docc, 'nb-cand') === '0' && text(docc, 'nb-defense') === '0',
      { cand: text(docc, 'nb-cand'), def: text(docc, 'nb-defense') });
    ok('T86 换盘后扫描快照被丢弃（不沿用旧盘数据）', Sc.scanSnapshot === null);
    ok('T87 换盘后报告视图回到空态', inner(docc, 'report-stage').indexOf('还没有报告') >= 0);
    ok('T88 换盘后空态引导同步', inner(docc, 'cand-stage').indexOf('还没有扫描结果') >= 0);
    ok('T89 切换盘符后按钮文案回到「开始扫描」', text(docc, 'scan-label') === '开始扫描', text(docc, 'scan-label'));
    ok('T90 切换盘符后操作栏隐藏', docc.getElementById('actionbar').hidden === true);
    ok('T91 切换盘符后统计卡片回到占位符', text(docc, 'st-total') === '—' && text(docc, 'st-cand') === '—');
    ok('T91b 换盘后清理记录与已处理集合一并清空（旧盘数据不串台）',
      Sc.cleaned.length === 0 && Sc.cleanedPaths.size === 0,
      { cleaned: Sc.cleaned.length, cleanedPaths: Sc.cleanedPaths.size });
    ok('T91c 换盘后侧栏盘符与容量跟随新盘（C 盘 512 GB）',
      text(docc, 'sf-drive') === 'C:\\' && text(docc, 'sf-total') === '512 GB',
      { drive: text(docc, 'sf-drive'), total: text(docc, 'sf-total') });
    ok('T91d 选择器按钮文案跟随所选盘',
      inner(docc, 'dpickLabel').indexOf('C:\\') >= 0, inner(docc, 'dpickLabel'));

    /* 反空转对照：重置状态不能把「重新扫描」这条主线弄坏 */
    Pc.runScan();
    rc.flush();
    ok('T92 换盘后重新扫描仍能正常产出候选（重置没有破坏主流程）',
      Sc.scanned === true && Sc.candidates.length === Pc.ALL_CANDIDATES.length - Sc.cleanedPaths.size,
      { scanned: Sc.scanned, cand: Sc.candidates.length });
    ok('T93 重新扫描后徽标与候选数一致',
      text(docc, 'nb-cand') === String(Sc.candidates.length),
      { badge: text(docc, 'nb-cand'), cand: Sc.candidates.length });
    ok('T94 重新扫描后快照重建', !!Sc.scanSnapshot && Sc.scanSnapshot.count === Sc.candidates.length);
    ok('T94b 候选路径盘符跟随所选盘（C:）',
      docc.querySelector('#tbody tr .pth').textContent.indexOf('C:\\') === 0,
      docc.querySelector('#tbody tr .pth').textContent);
  }
}

/* ================================================================== D：驱动器自动检测 */
{
  const rd = boot(HTML);
  const docd = rd.doc;
  const Pd = rd.probe;
  ok('T95 第四个实例无求值期异常', !rd.bootError, rd.bootError && String(rd.bootError.message));
  if (Pd) {
    const D = Pd.DRV;
    ok('T96 只列出真实检测到的盘（C/D/E 三个）',
      D.list.length === 3 && D.list.map(function (x) { return x.letter; }).join(',') === 'C,D,E',
      D.list.map(function (x) { return x.letter; }));
    ok('T97 盘符类型识别正确（C/D 固定、E 可移动）',
      Pd.driveAt('C').kind === 'fixed' && Pd.driveAt('D').kind === 'fixed' && Pd.driveAt('E').kind === 'removable',
      [Pd.driveAt('C').kind, Pd.driveAt('D').kind, Pd.driveAt('E').kind]);
    ok('T98 默认选中 D（有 D 就选 D）', D.cur === 'D', D.cur);
    ok('T99 来源标记为实测（drives.js / __SDC_DRIVES__）', D.source === 'inline', D.source);
    ok('T100 选择器按钮显示盘符与类型',
      inner(docd, 'dpickLabel').indexOf('D:\\') >= 0 && inner(docd, 'dpickLabel').indexOf('固定磁盘') >= 0,
      inner(docd, 'dpickLabel'));
    ok('T101 侧栏容量取自检测结果（D 盘 931 GB）', text(docd, 'sf-total') === '931 GB', text(docd, 'sf-total'));
    ok('T102 检测结果写入 localStorage 缓存', !!rd.w.localStorage.getItem('sdc.drives.v1'));
    ok('T103 有可用盘时排期一次自动扫描（无需联网）',
      rd.timers.length === 1 && rd.timers[0].ms === 520,
      rd.timers.map(function (t) { return t.ms; }));

    Pd.openDrivePop();
    ok('T104 打开弹层后列出全部检测到的盘',
      docd.querySelectorAll('#dpickPop .ditem').length === 3,
      docd.querySelectorAll('#dpickPop .ditem').length);
    ok('T105 弹层中当前盘带选中标记',
      docd.querySelectorAll('#dpickPop .ditem.on').length === 1 &&
      docd.querySelector('#dpickPop .ditem.on').getAttribute('data-drive') === 'D');
    ok('T106 弹层标题说明检测到的数量', inner(docd, 'dpickPop').indexOf('自动检测到 3 个驱动器') >= 0);
    ok('T107 弹层尾部说明「只列出真实检测到的盘」',
      inner(docd, 'dpickPop').indexOf('只列出真实检测到的盘') >= 0);
    Pd.closeDrivePop();
    ok('T108 关闭弹层', docd.getElementById('dpickPop').hidden === true);
  }
}

/* ================================================================== E：三路探测全空 */
{
  const re2 = boot(HTML, { drives: null });
  const doce = re2.doc;
  const Pe = re2.probe;
  ok('T109 第五个实例无求值期异常', !re2.bootError, re2.bootError && String(re2.bootError.message));
  if (Pe) {
    ok('T110 探测不到任何盘时一个都不列（宁可空着也不编造）',
      Pe.DRV.list.length === 0 && Pe.DRV.cur === '',
      { n: Pe.DRV.list.length, cur: Pe.DRV.cur });
    ok('T111 无盘时选择器禁用且提示「未检测到可用驱动器」',
      doce.getElementById('dpickBtn').disabled === true &&
      inner(doce, 'dpickLabel').indexOf('未检测到可用驱动器') >= 0,
      inner(doce, 'dpickLabel'));
    ok('T112 无盘时扫描按钮禁用、文案为「无可用驱动器」',
      doce.getElementById('btn-scan').disabled === true && text(doce, 'scan-label') === '无可用驱动器',
      { disabled: doce.getElementById('btn-scan').disabled, label: text(doce, 'scan-label') });
    ok('T113 无盘时不排自动扫描',
      re2.timers.filter(function (t) { return t.ms === 520; }).length === 0,
      re2.timers.map(function (t) { return t.ms; }));
    ok('T114 无盘时主区给出说明性空态',
      inner(doce, 'cand-stage').indexOf('没有检测到可用驱动器') >= 0);
    Pe.runScan();
    ok('T115 无盘时 runScan 被拒绝，不进入扫描态',
      Pe.S.scanning === false && Pe.S.scanned === false,
      { scanning: Pe.S.scanning, scanned: Pe.S.scanned });
  }
}

/* ================================================================== F：可清理占比（sf-share） */
{
  const rf = boot(HTML);
  const docf = rf.doc;
  const Pf = rf.probe;
  ok('T116 第六个实例无求值期异常', !rf.bootError, rf.bootError && String(rf.bootError.message));
  if (Pf) {
    const Sf = Pf.S;
    ok('T117 未扫描时占比显示占位符（不显示误导性的 0.0%）',
      text(docf, 'sf-share') === '—', text(docf, 'sf-share'));
    Pf.runScan();
    rf.flush();
    const gb = 1024 * 1024 * 1024;
    const shareOf = function () {
      const bytes = Sf.candidates.reduce(function (a, c) { return a + c.bytes; }, 0);
      return (bytes / (Sf.driveTotalGB * gb) * 100).toFixed(1) + '%';
    };
    ok('T118 扫描后占比 = 候选字节和 / 本盘容量（一位小数）',
      text(docf, 'sf-share') === shareOf(),
      { got: text(docf, 'sf-share'), want: shareOf() });
    const sel = Sf.candidates.slice(0, 2);
    Sf.selected.clear();
    sel.forEach(function (c) { Sf.selected.add(c.id); });
    Pf.doClean(sel, false, false);
    rf.flush();
    ok('T119 清理后占比随剩余候选下降（refreshAll → updDrive 链路通）',
      text(docf, 'sf-share') === shareOf(),
      { got: text(docf, 'sf-share'), want: shareOf(), removed: sel.length });
  }
}

/* ------------------------------------------------------------------ 收尾 */
function finish() {
  const lines = ['PASS ' + passes.length + ' / FAIL ' + fails.length, ''];
  if (fails.length) {
    lines.push('--- 失败断言 ---');
    fails.forEach(function (f) { lines.push('  ' + f); });
  } else {
    lines.push('全部断言通过');
  }
  const text = lines.join('\n');
  fs.writeFileSync(REPORT, text, 'utf8');
  console.log('app/ui.html 无头验证：PASS ' + passes.length + ' / FAIL ' + fails.length);
  if (fails.length) { console.log(text); process.exit(1); }
  process.exit(0);
}

finish();
