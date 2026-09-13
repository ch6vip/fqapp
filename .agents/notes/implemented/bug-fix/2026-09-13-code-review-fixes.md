# Agent Note: 全项目 code review 修复批次（缓存目录 GC / 听书续播 / 后端线程 / 明文流量）

Status: implemented

## Problem

对全项目做了一轮分区 code review（4 个并行审查通道：services、pages+player、reader、models+Kotlin），静态分析与 830 个测试全绿，但人工审查仍揪出 4 个真实缺陷、2 个 Android 层隐患，外加一次值得复盘的**误报踩坑**。

## Decision

### 1. `_trim` 会把"还没开始下载"的书目索引当垃圾回收

`ChapterCacheStore._trim` 原本在每次逐出后删除所有"没有章节实体"的 `book:` 记录。但 `saveBook` 的设计就是在第一章落盘**之前**先存目录（`detail_page._showDownload`、`audio_page`、`reader_page._ensureCatalog` 都这样）。于是：书 X 存了目录 → 留在后台的其他书 Y 写章节触发逐出 → X 因"无章节"被 GC。下载继续完成所有章节也救不回来——`books()` 只认有 `book:` 记录的书，整本离线下载在离线列表里**隐身**。

修复：逐出循环里顺带收集 `evictedBooks`，只回收"本轮被逐出且已无幸存章节"的书；catalogue-only 的书永远不碰。回归测试覆盖两个方向（`chapter_cache_store_test.dart`）。

### 2. 书籍详情页"继续收听"永远从第 1 章开始

`DetailPage._openListening` 用 `_readSavedRecord()` 取进度，book 分支读的是**未加 scope** 的文本阅读记录；而 `resumeAudioChapterIndex` 要求 `kind == 'audio'`，恒返回 null → 每次都从 0:00 第 1 章开播。修复：直接走 `AudioHistory(store).load()`（`scopedHistoryStore(store, 'audio')`）。`_MediaHistoryStore.historyEntry` 会回退未作用域键但仍校验 kind，所以旧版无 scope 的 audio 记录依旧能续播，无回归。

### 3. 播放页/听书页的计时器纪律

- `AudioPage`：睡眠定时器关闭与 dispose 都漏取消 `_sleepTimerTick`（1s 周期），页面销毁后每秒空转一次。补 cancel。
- `PlayerPage`：2s 进度定时器无条件 `_persistProgress()`，暂停/后台时每 2 秒用新的 `time` 戳重写同一条历史，书架最近排序被持续污染。对齐听书页的 `if (player.playing)` 守卫。

### 4. Android：明文流量与 JNI 线程

- Manifest 的 `usesCleartextTraffic="true"` 改为 `networkSecurityConfig`：默认禁明文，仅放行 `127.0.0.1`/`localhost`（内置 旧后端）。应用自身所有请求只打 loopback；上游 API 由后端进程代理。**残余风险**：若上游 payload 出现绝对 `http://` 媒体/封面 URL，加载会开始失败——那是可见故障，届时再评估升级为 https 还是给特定域放行；不要为了修图悄悄改回全局明文。
- `MainActivity`：`stopBackend`/`status` 的 JNI 调用移到线程池（`Shutdown` 等待在途请求会阻塞主线程 → ANR）；启动轮询加 `AtomicInteger` 代际防护——Dart 侧超时重试后，滞留的旧轮询线程不再有权 `stopBackend` 杀掉新启动的后端；轮询 deadline 改为从 JNI 调用**返回后**起算并至少读一次状态，慢冷启动不会被误判超时。

### 5. 误报复盘：WidgetSpan 缩进"测量与渲染不一致"

审查 agent 报了一个 P1：`_measureBlock` 测量用 `indent * scale` 的占位宽，渲染用 `SizedBox(width: indent)`，断言 scale≠1 时段落尾部被裁。它只查了 `rendering/paragraph.dart`（`layoutInlineChildren` 用原始 child 尺寸）就下了结论——**结论错了**。新版 Flutter 的 `RichText` 构造时经 `WidgetSpan.extractFromInlineSpan` 把每个 inline child 包进 `_AutoScaleInlineWidget`（`widgets/widget_span.dart`），按所在 span 的字体大小自动缩放 child：unscaled 的 `indent` 实际绘制宽度就是 `indent * scale`，与测量**一致**。我按 agent 的修法改后既有 1.3 缩放测试立刻以 36×1.3² 双重缩放失败，最小探针实验（width 36 → 首字形 x=46.8）确认了机制，于是回滚。

留了两样东西防再犯：代码注释说明 `_AutoScaleInlineWidget` 机制；新增 0.85 缩放的"测量==渲染高度"回归测试（原套件只测过 ≥1.0）。教训：涉及 inline child 布局的结论必须以 widget 树的实际渲染路径为准，`RenderParagraph` 的 child 约束不是终点，`_AutoScaleInlineWidget` 才是。

另：`MediaItemJson.toJson` 原本静默丢 `tag`（与 `copyWith` 注释里记过的丢徽章回归同类），已补成无损 round-trip 并提供 `fromJson`。

## Alternatives considered

- **保留"无章节即回收"但要求调用方先写第一章**：等于把顺序责任摊给 4 个调用点，将来第 5 个调用点照样踩；GC 语义收窄到"本轮被逐出"是一行条件的事，选后者。
- **payload 绝对 http URL 升级为 https**：无法逐主机验证证书可用性，坏一个 CDN 就是白图；先收 manifest，出问题再按域处理。
- **`stopBackend` 用单线程池串行化**：start 的 15s 轮询会把排队中的 stop 卡在后面，反而制造新的等待；选 cachedThreadPool 允许 stop/status 与轮询并发（现有代码本就允许这种并发）。
- **删掉无调用方的 `MediaItemJson`**：保留并修成无损，比删公共 API 再等有人重写一个有损版本好。

## Consequences

- 收益：离线下载不再隐身；书籍详情页听书续播恢复正确；两处历史记录不再被空转定时器污染；后端启停不再占主线程、重试不再被旧线程误杀；明文攻击面收窄到 loopback。
- 代价：`networkSecurityConfig` 后若上游真有 http 媒体 URL 会可见地失败（这是设计意图，不是回归）；MainActivity 的回包全部改经 `runOnUiThread`，新增一次主线程跳转；`_trim` 的语义多一个 `evictedBooks` 集合，O(n) 内存。
- 全量 834 测试通过（+4 新回归测试），`compileDebugKotlin` 通过。明文收紧与 MainActivity 改动需真机验证一次后端启动/停止与封面加载。
