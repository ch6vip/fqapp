# 阅读界面第二批移植

上游：`mikufoxxx/Wenku8_Flutter@ebcd7f1891b54a92fc045c372974d70ec829f10a`。
基线：fqapp 已合并 #282 (`39efd98`)。本批在其上继续移植展示层，不替换阅读/播放引擎。

## 源码对应

| 上游 | fqapp | 适配 |
| --- | --- | --- |
| `reader_chrome.dart` 的 `ReaderChromeLayer` / `ReaderEdgeBlur` | `reader_chrome.dart` | 保留无 opacity saveLayer 的位移/缩放；原生玻璃组替换为现有 `LiquidGlassBatch` / `EasyScrollEdge`；墨水屏、减少动态效果和性能开关生效 |
| `pages.dart::_readerBottomControls` | `reader_controls.dart` | 六项入口、Dock 与进度错峰显隐；fqapp 听/看胶囊保留；进度改为本章而不是章节序号 |
| `reader_tools.dart::ReaderChapterProgress` / `ReaderValueSlider` | `reader_chapter_progress.dart` / `reader_value_slider.dart` | 浮动百分比提示、无指针无障碍步进、拖动预览与最终提交；只在当前已加载章节内定位 |
| `reader_tools.dart::ReaderTools` / `_categoryGrid` / `_CategoryRevealClipper` | `reader_appearance_sheet.dart` / `settings/reader_settings_categories.dart` | 分类卡片和返回；外观、操作独立入口；字体/段落/屏幕/主题/翻页/听书等分类接原偏好；拖动时只保留当前滑条可见 |
| `reader_catalogue.dart` | `reader_directory_sheet.dart` | 使用真实 `Chapter.volumeName` 分卷、当前卷展开、搜索包含收起卷；原章节索引和快速滚动保留 |
| `reader_find.dart` | `reader_find_panel.dart` | 已加载章内文字查找，120 UTF-16 单位查询限制，500 处结果提示；字面匹配、IME 防抖、大章 isolate；结果映射回现有排版 |
| `reader_tools.dart::_bookmarks` | `reader_bookmarks_panel.dart` | 本书位置与摘录列表、添加/定位/确认删除；独立本机加密存储，不把书架或划线冒充书签 |
| `reader_selection.dart` | `reader_paragraph_menu.dart` | 共用 `GlassOverlaySurface`，长按可保存书签；保留复制/听书/划线；窄屏工具条可横向滚动 |

## 行为边界

- 正文布局、分页、跨章和听书跟随继续由 fqapp 引擎负责；菜单显隐不改变正文视口。
- 章内预览不加载别章、不逐次保存经过位置；松手保存实际到达位置。连续滚动按当前章局部坐标定位。
- 排版预览以 120ms 合并通知正文，持续拖动也更新；松手、返回及关闭提交最终值。
- 书签保存的是未替换原文坐标，显示时使用现有 source/display 映射。与划线分开存储，不自动删旧书签来腾容量。
- 书签目前仅在本书阅读器内管理，未接入本机备份格式、全局书签页或分类/批注，不宣称具备这些能力。
- 目录搜索与正文查找不同：正文查找不后台补取未加载章节，也不是整书查找。
- 阅读器内面板保持阅读系统栏策略；进入正文替换、音频或视频页面时释放阅读器所有权。
- 不导入上游账号/网络/云同步；不增加竖排、对页、单书排版、图片背景、词典等没有现有引擎承接的空控件。

## 验证口径

新增的聚焦回归验证数据与接线，既有历史布局测试不作为 Wenku8 视觉一致性指标。
实际设备构建和观察应注明对应源码及 APK，不用旧包或编译成功替代逐屏观察。
