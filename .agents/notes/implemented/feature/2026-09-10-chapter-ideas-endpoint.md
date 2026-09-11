# Agent Note: 章评／段评端点与段落评论路由修复

Status: implemented

## Problem

听书页的操作项按官方客户端叫「章评」（章末讨论），但客户端只能拿到整本书评，
文案与内容不符。阅读器侧同理：段评（按段落的想法）完全没有入口。

后端 `` 里 `/api/v1/chapters/{id}/reviews` 与
`/api/v1/chapters/{id}/paragraphs/{n}/reviews` 两条路由**恒返回 400**：路由只设置
`item_id` 与 `para_index`，而它们指向的 `book_reviews` 端点要求 `book_id`，
并且完全忽略这两个参数。

最初的判断是「把 `book_reviews` 参数化，接受 `group_id`／`group_type` 指向章节
forum 即可」。实测证明这个方向是错的。

## Decision

章评与段评走**另一个服务**：`POST /novel/commentapi/idea/list/{item_id}/v1/`。
书评走 `POST /novel/commentapi/comment/list/{group_id}/v1`，两者不可互换。

新增 `IdeaList` 端点（`internal/endpoints/idea_list.go`），并把两条章节评论路由改
指向它；`BookReviews` 补上官方段评配方所需的参数，默认值与原书评请求逐字段一致。

### 实测确立的契约

书评端点把 `comment_type` 锁死在 2（Book）：

| group_id | group_type | comment_type | 结果 |
|---|---|---|---|
| book_id | 1 | 2 | `code=0`，total=6536（书评） |
| forum_id | 任意 | 2 | `code=0`，但 total=0 |
| 任意 | 任意 | 0/1/3..5 | `103001 invalid param`，`debug_info="comment_type invalid"` |

所以论坛容器在书评端点上取不到任何东西，`group_id`／`group_type` 参数化并不能带来
章评——它只会产生 `103001`。

章评与段评的真实来源是 idea 服务，`comment_source` 决定返回什么：

- `comment_source=3`（NovelParaCommentExposed）→ 按**段号索引**的 map，每段带
  `count`、`bubble_data`（按 channel 的角标计数）与 `infos`。
- `comment_source=1`（NovelBookComment）→ 同样的 map 结构，但 `infos` 恒为空。

关键限制：**`infos` 只带 `comment_id`，没有正文**。正文必须再用评论列表端点取，
配方来自官方客户端 `ParaCommentListPresenter`：

```
book_id        = 真实书 ID（business_param）
group_id       = 章节 item_id（不是 forum_id）
group_type     = 15   UgcRelativeType.Item
comment_source = 2    NovelParaComment
comment_type   = 1    UgcCommentGroupTypeOutter.Paragraph
server_channel = 43   NovelParaUserCommentList
para_index     = 段落 ID
item_version   = 章节版本
```

`book_id`、`para_index`、`item_version` 三者缺一，上游即返回
`103001 book_id, item_version, or para_index invalid`。其中 `item_version` 不在详情
或正文接口里，取自目录接口的 `data.item_data_list[i].version`
（形如 `b271c896…_1_27cec4ca…`）。

`para_index` 是段落 ID 而非 0 基序号：官方客户端传的是 `getEndParaId()`。用序号查
会稳定得到 `code=0, total=0`。

## Alternatives considered

- **把 `book_reviews` 的 `group_id` 指向章节 forum**：改动最小，也能让请求返回
  `code=0`，但 `total` 恒为 0，拿不到任何章评。实测否掉，并回退了这次尝试
  （包括一并试过的 `forum_id` 端点 `count` 参数——它对 `mix_data` 没有任何影响）。
- **用 `forum_id` 端点的 `mix_data` 承载章评**：`count` 取 0/10/20 时响应逐字节相同，
  `mix_data` 恒为 `null`，只有 `item_related_count`（本章 22 条）可用。否掉。
- **按 `para_index` 直接从评论列表取段评**：官方 `ParaCommentListPresenter` 的配方是
  `comment_source=2`／`comment_type=1`／`group_type=15`／`server_channel=43` 配
  `para_index` + `item_version`（取自目录 `item_data_list[i].version`）。请求能被接受
  （`code=0`），但对含 3920 条段评的段落仍返回 `total=0`，确认该端点不提供段评正文。
  最终改用 `insert_comment_ids` 回填正文。
- **新建 app 侧 `/api/*` 桥接层做两次上游调用**：能让客户端一次拿到正文，但
  `webui.go` 的桥接层是给旧页面用的，`/api/v1` 才是 App 的入口；把链式调用塞进
  REST 层需要新增可组合的端点类型，超出本次范围。改为让客户端按需分两步调用。
- **把段落评论正文与计数合并进一个自建端点**：需要后端持有 reader 的段落 ID 空间，
  而那属于客户端的排版状态。保持后端无状态。
- **在阅读器正文里内联渲染段评角标**：本次**未做**，改为菜单入口 + 按段落面板，
  理由是当时判断需要改动分页布局（`reader_chapter_layout.dart`）逐行的命中测试，
  风险高于收益。
  **该方案后来还是做了**，做法是把气泡排进段落自身的 `TextSpan`（追加一个
  `WidgetSpan`），因此不必自己算行内位置，分页测量与绘制也不产生第二套高度。
  详见[阅读器正文内联段评气泡](2026-09-11-reader-paragraph-bubble.md)。

## Consequences

- 章节评论路由从「恒 400」变为可用；章评与段评有了真实数据来源。
- 书评行为逐字段不变（`TestBookReviewBodyDefaultsMatchBookReviews` 锁定默认请求体，
  `TestBookReviewBodyInsertIDs` 锁定 `insert_comment_ids` 在未传时必须缺席）。
- 客户端新增 `ChapterIdeas` 模型与 `ApiClient.chapterIdeas` / `commentsByIds`，
  段落评论响应（`data_list[i].comment` 嵌套结构）与书评响应（扁平 `comment[]`）
  统一归一化为 `BookCommentPage`。
- **段落 ID 来自正文 HTML**：`<p idx="N">` 的 `idx` 与 idea map 的键同一空间。
  `ChapterParagraph` 新增 `paraIndex` 并随结构化缓存持久化；旧缓存没有该字段时
  降级为 `null`，只影响该章的段评，正文照常显示。段评因此对离线缓存章节同样可用。
- 阅读器新增段评入口（控制栏 `段评 · N`）与按段落懒加载的面板；没有段评时入口隐藏，
  加载失败既不改变正文也不弹错误。
- 正文内联气泡随后补上，见
  [阅读器正文内联段评气泡](2026-09-11-reader-paragraph-bubble.md)；
  `bubble_data` 的通道计数由此有了用途（官方以 `bubble_data[3]` 作为气泡门槛）。
- 上游只给数量时不给正文，因此角标计数一次请求即可，正文按需懒加载。
- `para_index` 是段落 ID 而非 0 基序号：按序号查会稳定得到 `code=0, total=0`。

## Verification

- 新增 `internal/endpoints/idea_list_test.go`：校验 `item_id` 必填返回 `badRequest`、
  `idea_list` 请求体契约（`comment_source=3`）、书评默认请求体逐字段不变、
  `insert_comment_ids` 的存在与省略、以及 `splitCSV` 的边界。
- `router_test.go` 的三条章节评论路由断言由 `book_reviews` 更新为 `idea_list`。
- `go test -mod=readonly -count=1 ./...` 全绿。
- **后端已退休补丁**：这些改动已提交到 ``（分支 `fqapp-android`，提交
  `b237911`）。逐文件比对「旧基础 `4048110` + 补丁」与「`b237911`」的 blob，
  9 个文件全部一致；在新提交上**不打补丁**直接跑完整 Go 测试通过。
  CI 的 `LEGACY_COMMIT` 已更新为该提交，补丁文件与 `git apply` 步骤已删除。
- 发布二进制端到端复验（含两跳链路）：第 1 跳 `/chapters/{id}/reviews?comment_source=3`
  返回 `code=0` 与 85 段（最大段 `idx=72`、3920 条）；第 2 跳
  `/books/{id}/reviews?...&insert_comment_ids=…` 返回 `code=0` 与 8 条正文
  （如「孔子云：何惧死刑！[奸笑]…」）；书评基线 `total` 不变。
- 客户端 `test/chapter_ideas_test.dart` 覆盖按段号读取、通道计数与段落计数分离、
  仅暴露评论 ID、业务错误码降级、`data_list[i].comment` 归一化与游标 offset 解析。
- `test/reader_ideas_test.dart` 覆盖 `<p idx>` 解析、结构化缓存往返、旧缓存降级为
  `null`、面板只列出有段评的段落、正文按需加载且折叠后不重复请求、加载失败留在面板内、
  阅读器入口计数与跨章重新拉取、无段评时入口隐藏。
- `flutter analyze` 无问题；`flutter test` **663 项通过**；CI（Android APK）成功，
  其中包含检出后端固定提交并构建 JNI 后端。
- 未做真机验证；Android `liblegacy.so` 未在本机构建（本机无 NDK 28.2.13676358），
  由 CI 生成。
