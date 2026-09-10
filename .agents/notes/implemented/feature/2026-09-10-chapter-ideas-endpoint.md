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
- **新建 app 侧 `/api/*` 桥接层做两次上游调用**：能让客户端一次拿到正文，但
  `webui.go` 的桥接层是给旧页面用的，`/api/v1` 才是 App 的入口；把链式调用塞进
  REST 层需要新增可组合的端点类型，超出本次范围。改为让客户端按需分两步调用。
- **把段落评论正文与计数合并进一个自建端点**：需要后端持有 reader 的段落 ID 空间，
  而那属于客户端的排版状态。保持后端无状态。

## Consequences

- 章节评论路由从「恒 400」变为可用；章评与段评有了真实数据来源。
- 书评行为逐字段不变（`TestBookReviewBodyDefaultsMatchBookReviews` 锁定默认请求体）。
- 客户端新增 `ChapterIdeas` 模型与 `ApiClient.chapterIdeas` / `paragraphComments`，
  段落评论响应（`data_list[i].comment` 嵌套结构）与书评响应（扁平 `comment[]`）
  统一归一化为 `BookCommentPage`。
- **段评正文需要两跳且依赖客户端持有的段落 ID 与章节版本**。阅读器 UI 尚未接入；
  本次交付的是端点能力、数据层与归一化解析，以及 `README` 中记录的两跳契约。
- 上游只给数量时不给正文，因此「段评角标」可以在一次请求内完成，而正文按需懒加载。
- 段落 ID 与 idea map 的键是否同一空间尚未确认：idea map 的键是 0..51 的连续序号，
  而 `bubble_data` 里 channel 43 对段 0 的计数为 0，与传序号查正文得到 `total=0`
  的现象一致。接入阅读器时需要用真实 `getEndParaId` 语义再验一次。

## Verification

- 新增 `internal/endpoints/idea_list_test.go`：校验 `item_id` 必填返回 `badRequest`、
  `idea_list` 请求体契约（`comment_source=3`）、书评默认请求体逐字段不变、以及
  官方段评配方（`2/1/15/43` + `group_id` 为章节 ID + `business_param` 三要素）。
- `router_test.go` 的三条章节评论路由断言由 `book_reviews` 更新为 `idea_list`。
- `go test -mod=readonly -count=1 ./...` 全绿。
- **CI 等价验证**：在固定基础提交
  `40481102257f9405c8086c614b50796873091a4e` 的临时 worktree 中
  `git apply` 新补丁并跑完整 Go 测试，通过后已移除 worktree。
- 发布二进制端到端复验：章评路由 `code=0`（48 段，段 0 共 287 条），
  段评配方 `code=0` 且无 `debug_info`，书评基线 `total=6536` 不变。
- 客户端 `test/chapter_ideas_test.dart` 覆盖按段号读取、通道计数与段落计数分离、
  仅暴露评论 ID、业务错误码降级、`data_list[i].comment` 归一化与游标 offset 解析；
  `flutter analyze` 无问题，`flutter test` **651 项通过**。
- 未做真机验证；Android `liblegacy.so` 未在本机构建（无 NDK 28.2.13676358），
  需由 CI 或装有 NDK 的环境用 `scripts/build_backend.ps1 -Jni` 生成。
