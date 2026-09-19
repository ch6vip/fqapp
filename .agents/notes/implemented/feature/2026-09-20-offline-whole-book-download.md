# Agent Note: 详情页点「下载」即下全本，下载的章节不受自动缓存预算清理

Status: implemented

## Problem

详情页底栏的「下载」原本弹出 `ChapterCacheSheet`，只有 20 / 50 / 100 三档按钮（`_presetCounts`）：
想整本离线时没有入口，剩余 1200 章和剩余 120 章在面板上长得一样，用户只能连点几次「缓存 100 章」再自己算剩下多少。
即使加上「全部下载」按钮，那个面板仍是多余的一步——详情页的场景就是「把这本书存下来」，没有需要用户判断的范围。

整本下载还会撞上缓存的容量机制：`ChapterCacheStore` 是 LRU（默认 500 章 / 80 MB，按 `accessedAt` 从老到新淘汰），
而一批下载的 `accessedAt` 严格递增（`_touch` 单调）。所以「一路下 1200 章」淘汰掉的恰恰是这批里**最早**的那些
——用户从第 1 章开始读的那部分先被删，最后只剩目录尾部：请求全发出去，结果与意图相反。

## Decision

**详情页：一次点击 = 整本下载，没有面板。** `DetailPage._toggleDownload` 从续读位置（`_resumeIndex`，无历史则第 1 章）起，
把剩余章节**全部**提交为一批；进度就地显示在底栏（图标换成进度环、文案换成「缓存 12/500」），再点一次停止；
结束/停止/失败各给一条 SnackBar。

**下载的章节被 pin，自动缓存的预算管不到它。** 这是本次改动的机制核心：

- `ChapterCache.write(..., pinned: true)` 在记录里写 `'pinned': true`。
- `ChapterCacheStore._trim` **完全跳过** pinned 记录：它们既不会被淘汰，也不计入 `maxEntries` / `maxBytes` 的用量。
  于是同一批的 1200 章不会自己挤掉自己，整本下载不再被截断。
- `maxEntries` / `maxBytes` 现在只约束**自动缓存**（阅读时顺手缓存的章节），语义写在类文档与面板脚注里。
- 只有用户显式删除才会清掉下载内容：书架的缓存管理页「删除单本 / 清空全部」（`clear()` 按 bookId 或整库删除）。

**谁算 pin：整本下载。** `ChapterDownload.start(pin: true)` 来自两处——详情页的「下载」，以及阅读器面板的「全部下载 N 章」
（同一个「存整本」意图，两处行为必须一致）。阅读器面板的 20/50/100 档位仍是普通自动缓存（`pin: false`），会被 LRU 回收。

**批次只实现一次。** 原来的 `_ChapterCacheSheetState._download` 循环抽成
`lib/services/chapter_download.dart` 的 `ChapterDownload`（`ValueNotifier<ChapterDownloadState>`），面板与详情页共用：
已有缓存复用、插图过期的章节刷新、每章先 `onContentAvailable` 再落盘的顺序，全都只有一份。

**整本批次跨页面存活。** `WholeBookDownload` 静态持有当前批次：用户点完下载直接去阅读，批次不会因为详情页被销毁而中断；
回到详情页会重新挂上同一个批次（而不是起第二个）。同时只允许一个整本批次——`start()` 会 cancel 上一个（已落盘的章节保留）。

## 消费路径

- `ChapterDownloadState` 是唯一进度来源：`running / completed / total / incompleteImages / message`。
  面板直接渲染它，详情页只把它折成 `({int completed, int total})?` 交给 `DetailReadBar`，由底栏决定「图标变进度环」。
- `DetailReadBar` 的 key 用固定的 `keyName`（`detail_action_下载`），不能用 label——label 里跑着实时进度。
- 页面卸载不终止批次：`DetailPage.dispose` 只 `removeListener`，再 `WholeBookDownload.release`（仅在批次已结束时清引用）。
  `release` **不调用** `dispose()`：页面是在 notifier 自己的监听回调里走到这一步的，而 ChangeNotifier 禁止在派发通知期间 dispose
  （`_notificationCallStackDepth == 0` 断言），且结束的批次本来就没有监听者。
- 启动新批次时旧批次走 `cancel()` 而不是 `dispose()`：栈里那个刚离开的详情页仍在监听，不通知它就会永远停在一个不动的进度上。
- 详情页 `initState` 会认领 `WholeBookDownload.active`：还在跑且同一本书就挂上，已经结束就直接释放。
- 单章字节数仍受 `maxBytes` 兜底（`该章节超过缓存容量上限`），防止单条记录异常巨大；正常章节远低于这个量级。

## Verification

- `test/detail_page_test.dart`：点「下载」后章节全部落盘且**没有** `ChapterCacheSheet`、结尾出现「缓存完成」、动作回到「下载」；
  运行中点一次会停止（`缓存 0/2` → 点它 → 未落盘任何章节 + 「已停止缓存」）。
  整本验收用例把假缓存的容量设成 **1 章**，两章的书仍全部落盘且两章都是 pinned——容量不再截断下载。
- `test/comprehensive_ui_loading_test.dart`：原用例从「断言弹出面板并显示范围」改成「一次点击缓存剩余全部」，
  三种场景（1 章 / 3 章 / 3 章且续读在第 3 章）都断言面板不存在且落盘集合从续读位置起到末尾。
- `test/chapter_cache_sheet_test.dart`：101 章一次下完并全部 pinned（容量 3 也一样下满 101 章）；阅读器方向从下一章起、
  同样 pinned；预设批次（「缓存 3 章」）不 pinned，仍属自动缓存。
- `test/chapter_cache_store_test.dart`：未 pin 的大批次仍会自淘汰（`maxEntries: 3` 连写 6 章只剩 `{4,5,6}`）；
  pin 的 6 章全部留下；pin 的章节不占用自动预算（`maxEntries: 2` 下 3 个 pinned + 3 个未 pin → pinned 全留、未 pin 只剩最后 2 个）。
- `test/reader_illustrations_test.dart`、`test/cached_books_page_test.dart` 的缓存替身同步了 `pinned` 参数。
- `flutter analyze` 无问题；全量 `flutter test --no-pub --concurrency=2` 见提交时的运行结果。

## Alternatives considered

- **按缓存容量截断整本下载（上一版做法：「下载前 500 章」，读完再点一次续下）。**
  不会失控，但用户要的是「把这本书存下来」：截断让一次点击只完成一半，还得靠用户按阅读进度手动续点。
  现在整本下载一次性完成，代价换成磁盘占用。
- **让批次跑过容量但不 pin。** 就是 Problem 里描述的自淘汰：请求全部发出，缓存里只剩目录尾部，正是要避免的结果。
- **全局抬高 `maxEntries` / `maxBytes`。** 会连自动缓存一起放宽，失控的就不只是「用户明确要的那本书」。
- **让面板自动开始整本下载（点「下载」仍弹面板，只是不用选）。** 少一次交互，但用户明确说了不要弹层；
  而且面板的「关闭即停止下载」会把一个整本任务变成误触就丢。
- **把详情页的批次做成后台队列/任务，带持久化断点。** pin 之后不再需要断点：一批跑完就是整本。
- **容量提示与按钮分开判断条件。** 上一版踩过：容量小于最大预设档（100 章）时会「承诺只存 M 章」却只给出会下满整档的按钮。
  现在没有截断，这类自相矛盾的文案也没有了。
- **`release` 里 dispose 掉结束的批次。** 立刻踩到 ChangeNotifier 的「派发通知期间禁止 dispose」断言（首轮测试就红）。

## Consequences

收益：详情页一次点击即可整本离线，进度、停止、结果都在原地；下载的章节不会被自动清理，也不会被自己挤掉；
面板与详情页共用同一实现。

代价：

- **下载内容没有上限**：下载量 = 磁盘占用，只能靠用户去书架缓存管理页删除单本或清空。
  自动缓存仍有 500 章 / 80 MB 的预算，所以「随手读到哪儿缓存到哪儿」不会失控。
- 同时只有一个整本批次：在 A 书下载途中去点 B 书的「下载」，A 会停（已落盘的保留）。
- 阅读器面板的批次与整本批次仍可能同时在跑（面板有独立的控制器）。`ChapterCacheStore` 的写入是串行队列，不会写坏，
  但两者会互相加剧自动缓存那一半的淘汰。
- 旧版本写入的缓存记录没有 `pinned` 字段，仍按自动缓存处理（可被淘汰）——升级后需要重新「下载」才会受保护。
- `ChapterCache` 接口的 `write` 多了 `pinned`、`chapterCapacity` 只描述自动缓存：新实现类必须跟上，
  且所有 `write` 替身（测试内三个）都要同步签名。
