# Agent Note: 阅读体验批量复刻（官方反编译功能移植）

Status: implemented

## Problem

对官方反编译源码（`E:\ctf-aaa\fq-test\ckao\decompile`，包 `com/dragon/read/ui/menu`、`com/dragon/reader/lib`）做了能力盘点后，一次性移植了一批阅读体验功能。功能横跨多文件、涉及原生通道与状态机，需要一份集中文档供后续验证与回归。

## Decision

以下功能均已实现并随 1.0.28+29 安装包发布（手机 JJHAV8BENRPNBICM）。

### 1. 章评数据通道修正：server_channel 39 → 38

- 文件：`lib/services/api_client.dart` `paragraphComments`。
- 行为：段评列表请求 `server_channel=38`。38 是唯一有效的段评通道（实测多本书均返回与 idea 计数基本一致的数据，计数有 ±漂移与偶发整段 total=0，属上游抖动）；39 与 43（官方 presenter 值）实测对多本书恒返回 `code=0,total=0`。
- 附带：`_cursorOffset`（`lib/models/book_comment.dart`）支持纯数字 cursor（实测响应是 `"cursor":"20"` 字符串，不是 `{"offset":20}` 对象）；不认数字串会导致翻页永远取第一页。
- 附带：`parseDirectory`（`lib/models/media_item.dart`）把 `/api/directory` 桥接响应里 `data.item_data_list` 的版本合并进桥接 `chapterListWithVolume` 章节（桥接形状无 version，曾导致所有段评「评论加载失败」）。
- 段评面板（`lib/widgets/reader/reader_ideas_sheet.dart`）翻页为显式四态状态机 `_MoreStatus{idle,fetching,held,failed}`：请求在页脚进入视野(400px)即发出；落地（setState+20行排版，实测 28-41ms）延迟到滚动停止；`failed` 允许重试；短首页 postFrame 预取。

### 2. 气泡素材与变体

- 文件：`lib/widgets/reader/reader_bubble.dart`；素材 `assets/images/bubble/para_bubble_{plain,users,author}_{small,normal,large}.webp`（官方皮肤蒙版逐字节拷贝，黑色+alpha，运行时 `srcIn` 着色 `preset.mutedTextColor`）。
- 变体按**段落评论类型**选（`g45/a.b()` 语义）：`userCount>0` → users(对勾)；`isAuthor` → author(笔尖)；否则 plain。字段在 `ParagraphIdeas.userCount/isAuthor`（解析 `user_count`/`is_author_comment`）。
- 盒子尺寸 = 蒙版 3x 像素 ÷3：plain 24/26/30 方形；users/author 26×24、28×26、32×30（尾巴在右）。
- 数字 ≤99 原数、>99 `99+`；>99 时字号降一档（plain 除外，已在下限）。

### 3. 榜单修复

- 文件：`lib/models/rank.dart` `parsePage`。
- 行为：榜单页 `cell_view.cell_data[]` 是分组单元（月榜/男生榜/女生榜），作品在第二层 `cell_data[].book_data`；解析器先看本层 `book_data`，没有则下钻一层。此前所有榜单显示「该榜单暂无内容」。

### 4. 翻页动画（ReaderPageTurnStyle）

- 文件：`lib/widgets/reader/reader_paged_view.dart` + `reader_preferences.dart`。
- `cover`：被覆盖页（fractional current 之后那页）`Transform.translate(+delta*viewportWidth)` 钉住，新页从右自然盖上来；所有页面垫 `backgroundColor`（透明会穿透）。`slide`：PageView 原生（现状）。`none`：`jumpToPage`。
- 排版面板「阅读体验」区选择；默认 slide。

### 5. 音量键翻页

- `reader_page.dart`：`HardwareKeyboard.instance.addHandler(_handleVolumeKey)`，仅当 `volumeKeyTurn` 开、菜单收起、paged 模式：音量下=下一页、音量上=上一页，返回 true 消费。dispose 移除。

### 6. 自动翻页

- `reader_page.dart`：`_toggleAutoTurn()` 启动 `Timer.periodic(autoTurnSeconds)`；paged 每拍 `turnPage(1)`，滚动模式每拍滚动 85% 视口（450ms easeOutCubic）。任何点按/拖动/`_toggleControls` 即停（`_stopAutoTurn`）。间隔 3/5/10/20/30 秒在排版面板选。

### 7. 听书跟随翻页（ListeningSession）

- 文件：`lib/services/listening_session.dart`（单例 ChangeNotifier）+ `lib/pages/audio_page.dart`（发布方）+ `reader_page.dart`（消费方）。
- 听书页发布 book/chapter/position/duration/playing（通知节流 1 秒，结构性变化立即通知）；阅读器 `_onListeningTick`：仅当 `listeningFollow` 开、无自动翻页、菜单收起、`session.matches(bookId, chapterId)`（= playing + 同书同章）时跟随——paged `followProgress(progress)` 瞬时跳 `floor(progress*pages)`，滚动模式跳 `progress*maxScrollExtent`。暂停不驱动。我们的有声书是整章单音频文件，无逐句时间戳，跟随是比例估算。

### 8. 边走边读（系统 TTS）

- `reader_page.dart`：`FlutterTts`（zh-CN，rate 0.5，awaitSpeakCompletion），从当前页开始，`page.fragments[].text` 拼接朗读；completion handler → `turnPage(1)` → 继续读下一页；翻过章末停止。任何点按/拖动/切章停止。菜单按钮「边走边读/停止朗读」。
- 依赖 flutter_tts 4.2.5，其自带 `buildscript` 强拉 AGP 8.13.0（dl.google.com 不可达）；已补丁 pub 缓存 `flutter_tts-4.2.5/android/build.gradle` 删 buildscript 块与 kotlin-stdlib 钉版（宿主 AGP 9.0.1/Kotlin 2.3.20 提供）。补丁备份 `build/validation/flutter_tts-build.gradle.patched`。`pub cache repair`/升级插件会还原。

### 9. 章末区（本章评论入口）

- paged：翻到章尾边界页显示 `endPage`（`_buildChapterEndPage`）：「本章完」+「查看本章评论 · N」（N=章节段评总数；**跳转到章末评论桶**——ideas 响应最后一个键即章末聚合桶，配合通道 38 可直接查章末评论，第一版跳段评最多的段落已废弃）+「下一章」。
- 滚动模式：末尾按钮排（上一章/下一章间）「本章评论 · N」。
- 底部菜单**没有**本章评论（官方 string h1/gk/uu 均为「章末章评」；第一版错放菜单，已移除）。菜单现为：目录/夜间/排版/缓存 + 第二行 自动翻页 + 第三行 边走边读。

### 10. 其他

- 排版面板新增：翻页方式(覆盖/平移/无)、自动翻页间隔、音量键翻页开关、听书跟随翻页开关、阅读时保持屏幕常亮（原生 `ReaderDevicePlugin.keepScreenOn`，window FLAG_KEEP_SCREEN_ON，dispose 清除）。行距/段距/字号/字距/主题（含 eyeCare 护眼背景）本来就有。
- 排版已有项：点击左右 1/3 屏翻页、中间唤菜单（`_buildContent.onTapUp`）。

## Verification

全部验证命令在 `E:\ctf-aaa\fq-test\fqapp` 下执行：

```sh
# 1) 静态分析（应无 error/warning）
flutter analyze --no-pub

# 2) 全量相关测试（应全过，约 195+ 项）
flutter test test/reader_page_test.dart test/reader_interface_test.dart test/reader_ideas_test.dart \
  test/reader_bubble_test.dart test/reader_chapter_layout_test.dart test/reader_pagination_test.dart \
  test/reader_illustrations_test.dart test/reader_experience_test.dart test/api_client_test.dart \
  test/book_comment_test.dart test/media_item_test.dart test/rank_test.dart --timeout 60s

# 3) 真机后端实测（手机通过 adb forward tcp:18080 -> 设备 8080；桌面后端 127.0.0.1:8080）
#    段评（38 通道，应返回 total>0 且与 ideas 计数一致）：
curl -s "http://127.0.0.1:18080/api/v1/books/7276384138653862966/reviews?book_id=7276384138653862966&group_id=7276663560427471412&group_type=15&comment_source=2&comment_type=1&server_channel=38&para_index=0&item_version=2de75c5737f4c6cfc558caa5395b9490_1_0400779e7c6b924&count=5&cursor=5"
#    榜单（应含 cell_view.cell_data[].cell_data[].book_data）：
curl -s "http://127.0.0.1:18080/api/v1/rank/7098235271900037133?algo_type=200&rank_sub_info_id=0"
#    段评计数（对照 total）：
curl -s "http://127.0.0.1:18080/api/v1/chapters/7276663560427471412/reviews?comment_source=3"
```

已知限制（非 bug）：翻页跟随是比例估算（整章单音频文件）；TTS 依赖设备中文语音引擎；仿真卷页动画未实现；章末评论桶按 ideas 末键承接（上游对深翻页有区域限流，短页/空页属反爬，面板状态机已有失败重试兜底）。

## 交叉验证与修复轮（2026-09-12）

三个 subAgent 并行交叉验证(代码审计/测试执行/端到端实测)发现并已修复:

1. **P0 段评翻页端到端失效**: `book_reviews.go` 恒发 `need_count=true`,上游忽略 cursor → 永远第一页。修复(commit 7dad196):cursor 非空时 `need_count=false`(官方 presenter 翻页行为;实验后端实测 cursor 5→10→15→20 逐页推进)。**注意 18080(手机后端)需重装 1.0.28+ APK 后生效;桌面 8080 若为旧进程也需重启**。
2. **P1 暂停被发布成 playing=true**:audio_page 的 playingStream/positionStream 监听无视事件值,默认 playing=true 发布 → 暂停/seek 时阅读器仍被拽页。修复:发布真实 `player.playing`。
3. **P1 keepScreenOn 顺序**:`dispose` 先 clear 后 `_savePreferences()` 又 re-apply → 常亮残留。修复:`_savePreferences({applyKeepScreenOn})`,dispose 传 false。
4. **P1 最后一章 TTS 无限重读**:boundary 无下一章 → snackbar 轰炸。修复:`_pageBoundary` 末章时停 TTS;completion 链条检查 `_loading`/章末页。
5. **P1 章末页按钮不可达**:落上边界页即自动切章,按钮只闪现几十毫秒。修复:边界页停靠后延迟 600ms 才自动推进(按钮窗口期;直接划过仍推进;settle 未到整页用 round 比较)。
6. **P1 滚动模式自动翻页**加载窗口抛 StateError:补 hasClients 守卫。
7. **P2 听书跟随无接管闩锁**:手动翻页 15 秒内不跟随(`_pauseListenFollow`,点按区/音量键触发)。
8. **P2** 后台化停自动翻页+TTS;`_toggleAutoTurn` 启动时停 TTS;`_fail` 清空 session;空文本页 TTS 推进不卡死;rank 组 cell 双形状下钻去重;startPage 兜底文字不可见改真实「上一章」按钮。

e2e 附带发现:**章末章评桶可破解**——ideas 响应最后一个键(如 para 10000)+ 通道 38 就是章末聚合评论;文档「独立接口未破解」已过时,现章末页按钮跳转该桶。
文档措辞修正:38 通道「严格一致」不成立(计数有 ±漂移与偶发 total=0,方向正确);39 在本轮 3 本书中恒空(非「部分命中」可复现)。
测试侧补齐:server_channel=38 断言、listeningFollow 往返、音量键/自动翻页行为测试。analyze 零问题,12 文件 197+ 项测试全绿。

## 第三轮修复（2026-09-12，第二轮验证发现）

第二轮验证(修复审计+回归)确认大部分修复正确,另发现并已修复:

1. **TTS×章末停靠交互重做**:边界页不回调 `onPageChanged`,completion 里的 `_pageIndex >= pages.length` 是死条件 → 末页朗读两遍、切章后落点页被跳过、加载窗口整链被杀。重做:paged view 新增 `onBoundaryLanded(direction)`,章末停靠即停 TTS(章末=朗读终点),completion 链简化;`_pageBoundary` 的停止条件改为「进入前就无下一章」(差一错误:成功进入最后一章时 TTS 被误停)。
2. **听书跟随闩锁补齐**:点按翻页区与拖拽路径补 `_pauseListenFollow()`(第一版只接了音量键)。
3. **keepScreenOn 进入即应用**:`_refreshDevice` 末尾按偏好应用(此前只有动过设置才触发,跨会话失效)。
4. paged view `didUpdateWidget` 取消 `_boundaryLandingTimer`(闭包持有旧 index);rank 去重键空 id 时退回 title。

## Alternatives considered

- 仿真卷页动画：官方质感最强但需要像素级卷页着色器，成本过高，暂缓。
- 护眼模式独立开关：主题枚举已有 `eyeCare` 预设，避免重复实现，否掉。
- 章末章评独立接口继续扫通道：已破解——ideas 末键即章末聚合桶（如 para 10000）+ 通道 38；特殊组合（para_index=-1 等）上游不认。
- 段评落地放滚动中：逐帧测量 28-41ms 尖刺即用户卡顿感，改为停止后落地。

## Consequences

- 新增依赖 flutter_tts（原生 Android/iOS），pub 缓存补丁见上，升级插件需重打补丁。
- `ReaderPreferences` 新增 5 个持久化字段（pageTurnStyle/volumeKeyTurn/keepScreenOn/autoTurnSeconds/listeningFollow）。
- 阅读器菜单第二、三行为本批新增（自动翻页/边走边读），本章评论按官方语义只在章末。
