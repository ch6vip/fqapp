# 界面移植

## 方向与边界

2026-11-05 确认：以档案式首页为基准，先完成搜索、书籍详情、通用弹层三个样板，再按用户路径覆盖其他页面。统一设计语言，不复制首页布局，也不重写业务逻辑。

- 发现类：细线分区、档案标识、清晰标题；优先保证找书效率与信息密度。立体书架仅留在首页。
- 详情类：作品封面与宋体书名形成主视觉，元信息和正文分层；保留简介、目录、书评顺序。
- 内容消费类：阅读、漫画、音视频内容优先；菜单和控件统一，保留手势、进度、用户排版及播放器生命周期。
- 图标使用 Lucide，不以表情或文本符号代替操作图标。编号只标识作品、排行或分区，不给每个控件加装饰英文。
- 不新增登录、上游写入或付费能力；不改 API、持久化格式、播放引擎、版本号。桌面保留多栏布局，不拉伸手机版。

## 样板规则与所有者

| 项目 | 规则 | 代码所有者 |
|---|---|---|
| 色彩 | 奶白纸面、深色、OLED、墨水屏沿用现有主题 | `lib/widgets/home/home_design.dart` 的 `HomePalette` |
| 圆角 | 封面 3、静态面板 4、输入与主操作 8；底部 dock 不变 | `lib/widgets/home/home_archive.dart` |
| 文字 | 常规信息沿用应用字体；作品标题使用已打包的 Home Serif，英文/编号使用 Home Mono | `homeSerifStyle`、`homeCodeStyle` |
| 分区 | 标识、细线、定位方块、18sp 标题；长操作文字可收缩 | `HomeSectionLabel` |
| 搜索 | 描边输入框、下划线分类、独立来源开关；热搜标题与热度分行 | `lib/widgets/search/` |
| 详情 | 完整换行书名、可换行标签、独立分区与底部主操作 | `lib/widgets/detail/` |
| 弹层 | 样板顶部圆角 16、标题 20sp、统一关闭键；内容避开键盘与系统栏 | `HomeSheetFrame`、`HomeSheetHeader` |
| 点击与缩放 | 主要操作至少 48dp；紧凑次级操作至少 44dp；短屏可滚动，不隐藏必要操作 | 各组件布局约束 |

沿用现有组件，不新建平行主题系统。`HomeSheetHeader` 供目录、书评等虚拟列表复用；不把这些列表嵌套到 `HomeSheetFrame` 的滚动容器中。尚未迁移的旧弹层保留原行为，不按组件引用数量宣称整页已完成。

首页本地原型位于 `.agents/mockups/home-archive.html`。原型存在尺寸和动效规格，但不覆盖全应用。刊头缩为 20sp、入口为 36dp、分类去除重复序号、榜单使用浅色选中态是当前首页已实施的调整，不应再以原型初稿为由回滚。新样板实际渲染才是下一批的对照基线。

## 页面清单

以下清单按用户入口计，不把 `part`、布局扩展、控制器算作独立页面。“已有基础”仅指已有实现或共享主题，不代表已经按新样板移植或完成真实路径验证。

| 批次 | 页面/路径 | 直接实现 | 当前状态 |
|---|---|---|---|
| 0 | 首页 | `lib/pages/home_page.dart`、`lib/widgets/home/` | 已有档案设计；本批视口避让 dock，默认/短屏切书已在 MuMu 复核 |
| 1 | 搜索发现、联想、结果与来源切换 | `lib/pages/search_page.dart`、`lib/pages/search_shuqi.dart`、`lib/widgets/search/` | 样板落地，发现/结果/版式/来源主路径已复核；联想、分页与异常边界未全覆盖 |
| 1 | 作品详情 | `lib/pages/detail_page.dart`、`lib/widgets/detail/` | 样板落地，正文/底栏/目录/书评/下载弹层已复核；未执行阅读、听书或下载任务 |
| 2 | 分类 | `lib/pages/category_page.dart`、`lib/widgets/category/` | 已有基础，待迁移 |
| 2 | 完整榜单 | `lib/pages/rank_page.dart`、`lib/widgets/rank/` | 已有基础，待迁移 |
| 2 | 作者 | `lib/pages/author_page.dart` | 已有基础，待迁移 |
| 2 | 系列详情 | `lib/pages/series_detail_page.dart`、`lib/widgets/series_detail/` | 已有基础，待迁移 |
| 2 | 书旗详情 | `lib/pages/shuqi_detail_page.dart` | 已有基础，待迁移 |
| 3 | 书架、浏览历史、收藏 | `lib/pages/library_page.dart`、`lib/pages/library_shelf_*.dart`、`lib/widgets/shelf/` | 已有基础，待迁移；同时覆盖三种视图与编辑模式 |
| 3 | 我的、统计、阅读排行 | `lib/pages/mine_page.dart`、`lib/widgets/mine/` | 已有基础，待迁移 |
| 3 | 书籍缓存、短剧缓存 | `lib/pages/cached_books_page.dart`、`lib/pages/cached_dramas_page.dart`、`lib/widgets/cache/` | 已有基础，待迁移 |
| 4 | 小说阅读、离线阅读入口 | `lib/pages/reader_page.dart`、`lib/pages/reader/`、`lib/pages/cached_book_reader.dart`、`lib/widgets/reader/` | 已有基础，待迁移菜单；正文排版与用户偏好保留 |
| 4 | 漫画阅读 | `lib/pages/comic_reader_page.dart`、`lib/pages/comic/`、`lib/widgets/comic/` | 已有基础，待迁移控件 |
| 4 | 听书、听书模式 | `lib/pages/audio_page.dart`、`lib/pages/audio_listening_layout.dart`、`lib/pages/listen_mode_page.dart`、`lib/widgets/audio/` | 已有基础，待迁移；共享弹层变化不代表整页完成 |
| 4 | 短剧发现、播放 | `lib/pages/drama_page.dart`、`lib/pages/player_page.dart`、`lib/widgets/player/`、`lib/widgets/video_player_chrome.dart` | Android/Windows 已有基础，待迁移控件 |
| 5 | 设置、设置分类 | `lib/pages/settings_page.dart`、`lib/pages/settings_category_page.dart`、`lib/widgets/settings/` | 已有基础，待迁移 |
| 5 | 正文替换、系统 TTS 设置 | `lib/pages/text_replacement_page.dart`、`lib/pages/system_tts_settings_page.dart` | 已有基础，待迁移 |
| 5 | 备份、导入番茄书架 | `lib/pages/library_backup_page.dart`、`lib/pages/fanqie_history_import_page.dart`、`lib/widgets/data_transfer_widgets.dart` | 已有基础，待迁移；保留现有只读边界 |
| 5 | API 服务、日志、关于 | `lib/pages/api_service_page.dart`、`lib/pages/log_viewer_page.dart`、`lib/pages/about_page.dart`、`lib/widgets/logs/` | 已有基础，待迁移 |
| 平台限制 | iOS 视频入口 | `lib/main.dart`、`lib/widgets/unsupported_feature_page.dart` | 缺原生播放器，不属于视觉移植可解决的缺口 |

## 弹层与状态清单

| 归属 | 页面以外的表面 | 本批/后续范围 |
|---|---|---|
| 搜索 | 评分菜单、清空历史确认、输入联想 | 本批保留操作；发现/结果/空态/错误布局同步，菜单与确认待后续统一 |
| 详情 | 目录搜索/排序、全部书评、下载与缓存 | 本批统一标题、关闭、圆角；保留目录与评论的独立滚动 |
| 详情 | 封面查看、作者入口 | 保留现有查看与路由；不重写图片手势 |
| 书架/缓存 | 编辑菜单、删除确认、导入选择、缓存选择 | 第 3 批 |
| 阅读 | 目录快速滚动、排版、更多设置、字体、点击分区、段评、听读来源 | 第 4 批，分别保留各自状态与控制器 |
| 听书 | 声音、定时、倍速、跳过片段、下载、评论、浮动胶囊菜单 | 第 4 批；共享基座的消费者需抽查 |
| 短剧/视频 | 选集、清晰度、倍速、字号、评论/回复、关联作品、下载 | 第 4 批；`lib/pages/drama_download_sheet.dart` 归此项 |
| 设置/工具 | 确认、文件选择、备份预览、日志筛选与操作 | 第 5 批；系统选择器保持平台原生 |

每批复核范围应包含正常、加载、空数据、错误重试、禁用/选中、长内容与大字号，未覆盖项单独记录。只改底色或共享组件，不将页面状态自动改成“完成”。

## 分支与实现基线

2026-11-05 本地引用快照：`master=cbb7227`，当前首页分支基线 `637a01a`；不据此断言远程实时状态，也不自动合并、提交或发布。

`feat/visual-align` 的共享组件与多页基础此前已合入。旧文档把“分支存在或提交哈希领先”当成“功能未落地”，此判断已移除：`git cherry master <branch>` 对官方音频布局、听读高亮、首页区块 pr1、阅读目录快速滚动给出等价补丁；当前代码也已接入听书布局、阅读胶囊与目录。其余旧分支需比较实际代码差异，不能整体重新合入。

## 验证记录与限制

旧首页包 `e719dad17865...` 的默认尺寸与短屏记录见 `DEVELOPMENT.md` 的 2026-11-05 复核。旧记录包含滚动中间态点击落到底栏的问题，不再以“多滚动后能点到”作为完成标准。

### 2026-11-05：第 0/1 批样板

本地 Flutter 3.47.9 / Dart 3.13.7 构建 arm64 release APK，版本保持 `1.0.200` / `2205`。最终文件为 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`，SHA-256：

```text
67da5f1d26b2643bc5e330b532e2fd3094e2137bebda18259efa6a3fac872e37
```

MuMuManager 实时确认实例 `0`、Android 12、`127.0.0.1:16384`；保留数据覆盖安装，设备侧 APK hash 与本地一致。以下均操作此最终包，不使用中间构建的结果替代：

| 实际路径 | 观察记录 |
|---|---|
| 首页 → 下一本 → 上一本 | 默认 720×1280 下标题与 `NO.001/002` 同步切换；最终恢复第 1 本 |
| 短屏首页 | 临时 720×900、1.3 倍字号，滚动后“下一本”语义边界为 `[628,684][700,753]`，dock 起点为 y=754；内容在 dock 前裁切，点击实际切换第 2 本，没有误触 dock |
| 搜索历史 → 修仙 | 综合展示 18 部真实结果；封面/无封面列表切换，档案编号与分区标题显示正常 |
| 搜索 → 小说 → 书旗 → 番茄 | 小说返回 10 部、书旗返回 30 部；书旗分类禁用与无评分说明显示，切回番茄重新显示结果；最终恢复封面视图与番茄来源 |
| 首页作品 → 详情 | 《我能看到所有奇遇》封面、完整书名、换行标签、简介/目录分区与底栏显示正常；短屏大字号时书名继续换行，底栏保持独立高度 |
| 详情 → 目录 | 实际 580 章；切倒序首项为第580章，切正序恢复第1章；输入 `2` 仅显示第2章，输入 `999999` 显示空态，清空恢复列表，关闭返回详情 |
| 详情 → 全部书评 | 显示 15555 条总数与真实长书评，关闭返回原详情位置；未遍历全部分页或回复 |
| 详情 → 下载与缓存 | 默认与短屏下标题、关闭键、580章下载选项和无本地缓存禁用态可见；只开关弹层，没有触发整本下载 |
| 我的 → 读得最多 → 全部 | 抽查非本批页面的共享弹层消费者，显示本地 6 项排行并正常关闭；不据此标记“我的”整页迁移完成 |
| 外观 → 深色 / 墨水屏 | 分别检查搜索发现、作品详情和下载弹层；深色保留面板边界，墨水屏封面灰阶、黑白操作和描边可见；最终恢复“跟随系统”，OLED 原值关闭保持不变 |

截图、语义树、原始设置和日志均在仓库外 `%TEMP%/fqapp-ui-samples-20261105`，以 `20-final-` 起的记录对应最终包。系统尺寸恢复 720×1280、density 320，临时 `font_scale` 覆盖已删除，停留首页；未清除应用数据或操作实体手机。

静态辅助检查：`flutter analyze --no-pub lib` 无问题，`git diff --check` 无问题，release 构建成功；不新增或维护测试文件。当前进程 logcat 未见 Flutter 异常，crash buffer 为空，但日志量很少，不能据此覆盖全部运行时行为。

### 未覆盖边界

- 输入框接受了真实输入，系统 IME 状态报告显示，但截图没有可见软键盘；不能据此声称已验证键盘占屏后的避让。需有可见输入法的环境再复核。
- 搜索联想、连续分页、网络错误重试、清空历史确认，以及极大字号/横屏/Windows 多栏尚未完整操作；本批仅把相应布局与样板同步。
- OLED 纯黑未开启抽查；阅读、漫画、音视频、其余共享弹层消费者与第 2–5 批页面仍按清单待迁移/复核。

MuMu 的 ARM 转译不能证明物理设备性能、硬件解码或 16 KiB 页兼容性。听书实际发声、自动低性能降级和未操作的平台/主题仍需单独记录，不因样板完成而标为已验证。
