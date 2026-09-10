# Agent Note: 短剧详情页演员表

Status: implemented

## Problem

短剧详情页缺少演员表。用户对照官方客户端提出该缺口：官方短剧详情页有主演横向列表（头像、姓名、饰演角色），本 App 的详情页只有封面、简介、数据三栏、标签、目录和书评。

一开始以为演员数据已经在现有响应里，只是没解析。核对后并非如此：详情页当时用到的三个接口都不含任何演员字段。

## Decision

演员数据来自一个新的后端端点 `POST /api/v1/series/{id}`（上游 `POST /novel/player/video_detail/v1/`，新建 `video_detail` 端点），字段位于 `data.video_data.celebrities`。

### 为什么必须新增端点

实测三个已有接口，全部没有演员数据：

| 接口 | 是否含演员 |
|---|---|
| `/api/detail?tab=短剧`（走 `book_detail_legacy`，阅读类接口） | 无 |
| `/api/directory?tab=短剧` | 无 |
| `/api/v1/manga/videos/{id}`（pseries，剧集列表） | 无 |

演员属于**播放器域**数据。官方客户端的对应调用是 `PlayerApiService` 的 `mGetVideoDetail`，模型 `VideoDetailInfo.celebrities`（`Celebrity`：`celebrity_id`/`nickname`/`avatar`/`role_name`/`intro`/`sub_title`），而它是 pbrpc 定义、未反编译出路径，最终从 `v56/a.java` 的 `@RpcOperation` 拿到真实路径 `/novel/player/video_detail/v1/`。

同一个响应里还有系列标题、简介、集数、播放量、分类，一并解析进 `SeriesDetail`（虽然本次只有演员表用到 UI）。

### 两个上游参数是必填的

第一次请求失败，返回 `100001 invalid param`，`debug_info` 为 `series_id invalid`。原因不是 id 有错，而是缺少 `biz_param.video_id_type`：

- `video_id_type` 必须为 **1（`VideoSeriesIdType.SeriesId`）**。不传时上游把 `series_id` 当作错误类型处理，直接判为非法。这是从 `ShortSeriesDetailFragment` 的构造代码（`videoIdType = SeriesId`、`source = FromDetailPage`）确认的。
- `video_platform` **不传**。官方客户端在这个请求里不设置它，而 `pseries` 用的是 1024。实测传 3 或 1024 都会失败，因此实现里该字段默认省略，只在调用方显式要求时才发送。

补齐 `video_id_type` 后 `code=0`，实测两部短剧分别返回 5 位和 1 位演员，且带角色名（如「张楸梓 饰 林汐」）。

### 头像格式

头像 URL 是 **HEIC**（`~tplv-resize:200:0.heic`，`Content-Type: image/heic`，魔数 `ftypheic`）。这带来两点：

- **不能改写格式**。把 `.heic` 换成 `.jpeg` 或 `.image`、或去掉 `~tplv-` 模板，都会破坏签名并返回 403，因此无法在客户端换成可解码格式。
- **同一批演员在搜索接口里是 JPEG**（`p6-novel-sign` 主机 + `.image` 模板，实测 `FF D8 ... JFIF`）。但那是搜索结果的附带数据，按作品标题去搜并不可靠，所以没有采用；演员数据的权威来源仍是系列详情。

实测 Flutter 3.44 引擎可以解码这些 HEIC（`ui.instantiateImageCodec` 得到 200×200，且文件内没有内嵌 JPEG），因此正常情况下头像能正常显示。但主机引擎与 Android 引擎的解码器集合未必一致，所以 `DetailCastRow` 仍带降级：头像为空、加载失败或加载中都显示姓名首字，保证卡片不会空白。

## Alternatives considered

- **从搜索接口的 `celebrities` 取演员**：搜索响应确实带演员（含 `role_name`）且头像是 JPEG，无需新增端点。但演员是否出现在搜索结果取决于标题命中，任意 series_id 无法保证拿到完整名单，属于用搜索副作用冒充详情数据。否掉。
- **让后端转码 HEIC→JPEG**：能一次性解决头像格式问题，但后端是 `CGO_ENABLED=0` 构建，Go 没有可用的纯 HEIC 解码器（HEIC 基于 HEVC），引入 cgo 会破坏现有交叉编译与 CI。否掉。
- **Android 侧新增 Kotlin 插件解码 HEIC**：项目已有原生插件先例，可行且稳健。但实测 Flutter 引擎本身能解码，先按常规图片加载 + 首字降级实现；若真机上头像不显示，再补这个插件。
- **把演员表塞进现有详情响应**：需要改阅读类接口的解析路径，而演员数据根本不在那条链路的上游响应里，无法"顺便"带出来。
- **内联渲染演员行而不新增区块**：演员表是独立信息块，塞进数据三栏会挤压榜单/在读/评分三项的既有布局。

## Consequences

- 短剧与漫剧详情页有了演员表（头像、姓名、角色），与官方版式对齐；小说和其它类型不请求该接口。
- 新增一次仅在视频类内容上触发的请求，且**不阻塞页面**：系列详情与详情／目录并发加载，失败或为空时区块直接消失，不显示空标题、不影响播放与目录。
- `SeriesDetail` 一并解析了系列标题、简介、集数、播放量、分类，但 UI 目前只用演员表；这些字段为后续微调留出余量，不需要再改后端。
- 演员头像依赖上游 HEIC；若某台设备的解码器不支持，显示姓名首字而不是空白或破图。
- 后端改动已提交到 ``（分支 `fqapp-android`，提交 `f667122`），CI 的 `LEGACY_COMMIT` 已同步更新。

## Verification

- 新增 `internal/endpoints/video_detail_test.go`：校验 `series_id` 必填返回 `badRequest`、`series_id`/`video_id`/`item_ids` 三个别名与优先级、请求体契约（`video_id_type=1`、`source=5`、`device_level=3`）、`video_platform` 未指定时必须缺席、指定时按值发送、`videoDetailURL()` 指向 detail 路径且保留 `{install_id}`/`{device_id}` 占位、`optionalInt` 区分"未提供"与显式 0。
- `go test -mod=readonly -count=1 ./...` 全绿；提交已推送到 ``。
- 发布二进制端到端：`/api/v1/series/{id}` 对两部短剧均返回 `code=0`，分别得到 5 位和 1 位演员（含角色名与头像 URL）；小说详情响应不受影响。
- 客户端 `test/series_detail_test.dart`（13 项）覆盖演员解析（含角色、头像、缺名/缺角色剔除）、系列元数据、`series_id_str` 回退、业务错误与异常载荷降级、首字降级、演员表区块的渲染与空态折叠、短剧触发请求而小说不触发、加载失败不破坏页面。
- `flutter analyze` 无问题；`flutter test` **676 项通过**。
- 未做真机验证：头像在 Android 上的 HEIC 解码表现需要在设备上确认（本机验证的是 Flutter 主机引擎）。若真机不显示，实现路径见上面的备选方案。
