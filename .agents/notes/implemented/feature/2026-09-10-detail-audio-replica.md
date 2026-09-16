# Agent Note: 详情页与听书页版式复刻

Status: implemented

## Problem

详情页是「编辑风」：居中封面配 `STORY` 水印、卡片式简介、底部只有一个阅读按钮和目录按钮。听书页复用通用播放器骨架：方形大封面、居中书名、系统 `Slider` 加两个跳转按钮。

两者都缺少官方客户端表达作品信息的方式——详情页没有分类／完结状态／字数／在读人数／评分／作者等级／标签／书评；听书页没有书目卡、简介、关联作品、朗读字幕、音色卡片、定时。

同时这两页此前的数据只用到 `MediaItem`（id/标题/封面/作者/badge），`/api/detail` 返回的 200 多个字段里绝大部分没有被读取。

## Decision

按用户截图复刻两页的**版式结构**，配色沿用 fqapp 现成的暖纸底 + 番茄红，不照搬番茄原版的淡紫渐变与米色底。

数据全部接入。新增三个模型承载此前未解析的字段：

- `BookDetail`（`lib/models/book_detail.dart`）读 `/api/detail` 的富字段，并承担展示格式化（`132.8万字`、`8万`、`原创`、`完结`）。
- `BookCommentPage`（`lib/models/book_comment.dart`）读书评列表与页级计数。
- `AudioToneSet` / `SubtitleTrack` / `RelatedWork`（`lib/models/audio_extra.dart`）读智能朗读音色、朗读字幕与关联作品。

**富元数据不额外发请求**：`BookDetail` 直接从详情页已经拿到的 `/api/detail` 响应解析。官方 `BookInfo` 契约（`com.dragon.read.api.bookapi.BookInfo`）与实测响应对照确认，该响应已包含 `category`、`creation_status`、`word_number`、`read_count`、`score`、`tags`、`author_info.user_title_infos[].title_text`（即「作家Lv.5」）、`book_rank_info`。

契约上有三处必须记住的实测事实：

1. **数值字段全是字符串**。`word_number: "1328318"`、`creation_status: "0"`、`serial_count: "592"`、`read_count: "79528"`。按数字解析会全部落空。
2. **字幕端点的默认参数永远失败**。`/api/v1/chapters/{id}/timeline` 在后端默认的 `genre=4, tone_id=99` 下稳定返回 `code=1301008 no available speech text`；实测 `genre=1`（或 `0`）配合任意有效 `tone_id`（1/4/82/90）才返回 `code=0`。因此客户端**必须**显式传 `genre` 与所选音色，且 `1301008` 是「这本书没有字幕」的正常答案，不是错误。
3. **音色端点用小写键**（`id`/`title`/`description`/`badge`/`is_multi_tone`），与同名的 PascalCase RPC 模型 `ToneInfo` 不一致；真人讲书条目用 `abook_id` 而非 `id`。

有声书的智能朗读选项还可能属于关联小说，需要同时切换书 ID 和章节 ID，不能按录音类型一律隐藏。
具体契约与验证见[关联小说音色切换](../bug-fix/2026-09-16-linked-audio-voices.md)。

字幕格式是 `[起始毫秒,0]<起始,0,0>文本` 的逐行文本，按行解析成带时间戳的 cue 列表，用二分查找定位当前句，同时展示下一句。

## 测试注入与离线的边界

两页都需要新增网络资源（书评、音色、关联作品、字幕），但既有测试通过注入 `detailLoader` / `directoryLoader` / `sourceLoader` / `voicesLoader` / `playerFactory` 保持离线。

规则是：**调用方已经注入过自己的 loader，就说明它按构造是离线的**，页面不得在背后联网；需要验证新模块的调用方再注入 `extrasLoader` / `subtitleLoader`。这样生产和既有测试都无需改动，也不会因为本机恰好跑着后端而让测试产生网络依赖。

## Alternatives considered

- **照搬番茄原版配色（详情页淡紫渐变、听书页米色暖调）**：最贴近截图观感，但会与首页、书架、阅读器的暖纸／番茄红体系割裂，需要为两页单独维护页面级主题并另推一套暗色。用户选择沿用现有配色，只复刻版式。
- **新建独立的 `/api/v1/books/{id}/detail` 富模型请求**：语义更清晰，但详情页已经在请求同一端点，再发一次只会让首屏多一个 RTT 和一套失败分支。改为复用既有响应。
- **把 `BookDetail` 塞进 `MediaItem`**：`MediaItem` 是列表卡片的归一化模型，被首页、搜索、书架共用；塞入详情专用的 200 字段会污染所有列表路径的内存与解析成本。
- **听书页整页重写以匹配截图**：截图没有大封面，但播放器状态机（生成号、释放串行化、后台暂停、迟到响应丢弃）有 35 个测试锁定，整页重写风险过高。改为只替换展示层，保留全部状态机方法。
- **详情页移除 3 章目录预览**：截图里「查看目录」下方直接是书评。但预览是续读捷径，且有 3 个测试依赖它取第二章。保留预览，放在「查看目录」行之后。
- **听书页「下载」按钮置灰或省略**：截图有该按钮。改为接入既有的 `ChapterCacheSheet`，成为真实的离线缓存入口，而不是死按钮。

## Consequences

两页现在呈现作品的完整元数据，且这些字段全部来自真实接口而非占位。

代价与限制：

- 详情页首屏多两个并发请求（书评、富元数据中只有书评是新请求）；两者都失败时整页仍可用，只是书评区消失。
- **字幕依赖书本已生成语音文本**。实测样本书返回 `1301008`，换 `genre`/`tone_id` 才拿到 2306 字的字幕。因此字幕区在多数书上不会出现，这是数据可用性而不是缺陷。
- 榜单三栏只在 `rank_title` 或 `book_rank_info` 存在时渲染；样本书该字段为 `null`，所以数据栏会显示为两栏。
- 截图底部的插图区未实现：那来自阅读器插图管线，与听书播放无数据关联。

## 章评为什么改名为书评

官方听书页的操作项是「章评」（章末讨论，与书评、段评并列），但客户端拿不到章评列表。实测：

- `/api/v1/forum-id`（上游 `/reading/ugc/item/mix_data/get/v`）能解析出本章的 `forum_id` 与 `item_related_count`（样本为 22），但没有评论内容，`mix_data` 为 `null`。章评列表在上游是 `group_id = forum_id` 的 `/novel/commentapi/comment/list/{group_id}/v1`。
- `/api/v1/chapters/{id}/paragraphs/{n}/reviews` **恒返回 400**：路由只设置 `item_id` 与 `para_index`，而 `book_reviews` 要求 `book_id` 且在请求体里硬编码 `group_id = bookID`、`group_type = 1`、`para_index = 0`，因此该路由即使补上 `book_id` 也只会返回整本书评。

后端没有以 `forum_id` 为 `group_id` 的评论列表端点，所以用官方标签会让内容与文案不符。操作项改名为「书评」，并在 `README.md` 记录该限制与补端点的方法（在 `book_reviews` 中接受 `group_id`/`group_type` 参数，或新增端点）。
- 测试查找方式需要配合版式改动：目录入口从底部栏移入正文后，小视口＋大字号下该 sliver 落在视口外，`find.byKey` 默认的 `skipOffstage` 会过滤掉它，必须先以 `skipOffstage: false` 查找再 `ensureVisible`，且不能在该步 `pumpAndSettle`（此时可能还有别的进行中动作在转圈）。

## Verification

- `test/book_detail_test.dart`、`test/book_comment_test.dart`、`test/audio_extra_test.dart` 覆盖字符串数值、标签拆分、字数／计数格式化、作者等级、0-10 分转五星、相对时间、页面计数回退、字幕解析与二分定位、音色小写键与 `abook_id`、关联作品分类，以及各类空／异常响应降级。
- `test/detail_redesign_test.dart` 与 `test/audio_page_test.dart` 的既有断言（`detail_book_title` 无 `maxLines`、全部图标属于 flutter_lucide、`audio-seek` 可拖动、15 秒跳转、目录搜索选章、自动下一章等）全部保持通过。
- `test/audio_page_test.dart` 新增三条：操作项以「书评」而非「章评」呈现且不联网时明确提示不可加载、加入书架可切换并写入 `inShelf`、定时到点自动暂停并保存进度。
- `flutter analyze --no-pub` 无问题；`dart format` 无差异；`flutter test --no-pub --concurrency=2` **640 项通过**（较改动前 596 项增加 44 项）。
- 截图核对脚本 `build/validation/ui-replica-20260910/ui_preview_test.dart` 渲染出详情页（亮/暗/书评区）与听书页（亮/暗/下半屏）六张截图。使用真实响应结构构造 fixture，未接入生产数据。
- 接口结论由本地后端实测得出，样本保存在 `E:\ctf-aaa\fq-test\ckao\apiprobe\samples\`（detail / comments / related / tones / timeline / forum_id）。
- 未做真机验证；未覆盖正文解密、播放解码等原生路径。
