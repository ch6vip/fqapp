# fqapp — 番茄小说/短剧 Flutter 客户端

一个运行在 **Android 手机本地** 的番茄小说聚合客户端：内置 Go 版 `` 后端，Flutter 原生 UI 提供小说阅读、短剧播放、搜索、历史和离线缓存。漫画和听书目前支持内容识别，原生阅读与播放页面尚未开放。

> **核心设计**：后端跑在 `127.0.0.1:8080`，UI 通过 HTTP 调用本地后端。不需要自建服务器，不需要 root；签名、解密和本地缓存由手机完成，但在线内容仍需访问番茄上游。

---

## 目录

- [特性](#特性)
- [架构总览](#架构总览)
- [项目结构](#项目结构)
- [快速开始](#快速开始)
- [构建 APK](#构建-apk)
- [Android 后端进程集成](#android-后端进程集成)
- [API 对接说明](#api-对接说明)
- [数据模型](#数据模型)
- [页面说明](#页面说明)
- [已知问题与调试](#已知问题与调试)
- [开发计划](#开发计划)

---

## 特性

| 功能 | 说明 |
|---|---|
| 📖 小说阅读 | 目录浏览、章节正文（后端解密）、字号调节、点击翻页 |
| 🎬 短剧播放 | 集数列表、自动连播、播放/暂停、上/下一集 |
| 🖼 漫画 | 内容类型识别（阅读器暂未开放） |
| 🎧 听书 | 内容类型识别（播放器暂未开放） |
| 🔍 搜索 | 跨类型搜索，按 小说/漫画/听书/短剧 分 tab |
| 🕘 历史 | 阅读/播放进度记录，续看 |
| 🏠 首页 | 推荐内容流，推荐不可用或耗尽后回退分类搜索 |
| 📱 本地后端 | 旧后端与前端在手机内运行，在线内容从上游获取 |

---

## 架构总览

```
┌────────────────────────────────────────────────┐
│                    Flutter App                  │
│                                                │
│  ┌──────────┐   ┌────────────┐   ┌──────────┐  │
│  │ UI 页面  │──▶│ ApiClient  │──▶│  HTTP    │  │
│  │(阅读/播放)│   │(归一化解析) │   │127.0.0.1 │  │
│  └──────────┘   └────────────┘   └────┬─────┘  │
│                                       │        │
│  ┌──────────┐   ┌────────────┐        │        │
│  │ Library  │   │  Backend   │        │        │
│  │  Store   │   │  Service   │────────┘        │
│  │(历史/时长)│   │(进程管理)   │                 │
│  └──────────┘   └─────┬──────┘                 │
└───────────────────────┼────────────────────────┘
                        │ Android JNI
                        ▼
              ┌─────────────────────┐
              │   Go  后端      │
              │    liblegacy.so     │
              │  签名 · 解密 · 代理  │
              └─────────┬───────────┘
                        │ HTTPS
                        ▼
              番茄上游 API (fanqie)
```

### 数据流

1. **启动**：`main.dart` → `BackendService.start()` 将配置、过滤器、Web 页面及其 CSS/字体、插件部署到 app 私有目录 → 通过 Kotlin/JNI 启动 APK 中的 `liblegacy.so` → 轮询 `/health` 直到 200。Android 不执行私有目录中的独立二进制；桌面后端路径使用宿主平台的 `assets/bin/`。
2. **请求**：UI 页面 → `ApiClient`（`http` 包）→ `http://127.0.0.1:8080/api/*` → 后端完成签名（Argus551）、设备池管理、请求上游、解密内容 → 返回归一化 JSON。
3. **存储**：历史和阅读时长走 `LibraryStore`（Hive）。

---

## 项目结构

```
fqapp/
├── lib/
│   ├── main.dart                    # 入口：启动后端 + RootShell(底部导航)
│   ├── models/
│   │   └── media_item.dart          # MediaItem/Chapter/SearchTab 模型 + 归一化解析
│   ├── services/
│   │   ├── backend_service.dart     # 旧后端管理(部署/JNI/桌面进程/健康检查/日志)
│   │   ├── api_client.dart          # 后端 HTTP 客户端(对接 /api/* 桥接层)
│   │   └── library_store.dart       # 历史/阅读时长本地存储
│   ├── pages/
│   │   ├── home_page.dart           # 首页(推荐流)
│   │   ├── search_page.dart         # 搜索(分 tab)
│   │   ├── detail_page.dart         # 详情(简介+目录)
│   │   ├── reader_page.dart         # 小说阅读器
│   │   ├── player_page.dart         # 短剧播放器(Media3 + JNI 流式解密)
│   │   ├── library_page.dart        # 书架(阅读历史)
│   │   └── mine_page.dart           # 我的(服务状态)
│   └── widgets/
│       └── media_card.dart          # 封面卡片组件
├── assets/
│   ├── bin/                    # 宿主平台独立后端，不打入 Android APK
│   ├── config/                      # config.json / filter.json / 设备池示例
│   ├── filters/                     # 15 个 JS 过滤脚本(goja 运行时)
│   ├── web/                         # 后端自带 Web UI(浏览器备用)
│   └── plugins/                     # manga_reader / player HTML 插件
├── android/                         # Android 工程、JNI 桥接与 JVM 测试
├── native/                          # 可重建的 CENC 流式 C 解密库与 CMake
├── scripts/
│   ├── build_backend.sh             # 编译宿主后端、可选 Android JNI + 同步运行时文件
│   └── build_backend.ps1            # 同上，Windows PowerShell 版
├── test/                            # Flutter 单元/组件测试及 Web 回归
└── pubspec.yaml                     # Flutter 依赖与资源声明
```

> **仓库不含原生二进制**：`assets/bin/` 和两份 `.so` 均被 Git 忽略。独立后端及
> `liblegacy.so` 可由 `` 源码重建；`libshortplay_crypto.so` 由本仓库 `native/` 中的
> C 源码在 Android 构建时自动生成。Android 构建前需准备 Go JNI 后端。

---

## 快速开始

### 环境要求

| 工具 | 版本 | 用途 |
|---|---|---|
| Flutter | 3.44+ (stable) | 构建 App |
| Dart SDK | 3.12+ | 随 Flutter |
| Android SDK | 36 (platform) + Build-Tools | 编译 APK |
| Go | 1.26+ | 交叉编译后端二进制 |
| Android NDK | 28.2.13676358 | 编译 Go JNI 后端与 C 流式解密库 |
| CMake | 3.22.1 | Android 构建自动编译 C 库 |

> Windows 下构建注意：Kotlin 增量编译在部分环境会报 `Could not close incremental caches`，已在 `android/gradle.properties` 中关闭（`kotlin.incremental=false`）。

### 1. 编译后端并同步运行时文件

脚本默认编译当前宿主系统与架构的独立后端，并同步运行时资源。Android 构建必须加
`--jni` / `-Jni`，同时生成 `android/app/src/main/jniLibs/arm64-v8a/liblegacy.so`：

```bash
./scripts/build_backend.sh --jni                  # 默认源码目录 ../
./scripts/build_backend.sh --jni /path/to/    # 手动指定源码目录
```

Windows PowerShell：

```powershell
.\scripts\build_backend.ps1 -Jni                       # 默认 ..\
.\scripts\build_backend.ps1 -Jni C:\path\to\
```

NDK 可由 `ANDROID_NDK_HOME` / `ANDROID_NDK_ROOT` 指定，或放在 Android SDK 的 `ndk/` 下。
源码树必须包含与 `BackendNative.kt` 匹配的 JNI 入口。独立后端使用 `GOHOSTOS/GOHOSTARCH`，
JNI 后端固定使用 `GOOS=android`、`GOARCH=arm64` 和 NDK clang。

脚本默认保留已有配置、过滤器、Web 与插件，只补齐缺失文件，以保留本项目的移动端配置和修复。
需要从上游覆盖时，分别使用 `--force-config` / `-ForceConfig` 和
`--force-runtime` / `-ForceRuntime`；覆盖后应检查 diff 并重跑测试。

> ⚠️ 脚本只拷贝 `config.json`、`filter.json`、`device_pool.example.json` 三个确定的配置文件，
> **不会**整目录复制 `config/`。真实设备池 `device_pool.json` 里带 `secret_key`，
> 脚本会跳过它并清理 `assets/config/` 中的副本；`pubspec.yaml` 也只声明上述三个配置文件。
> 设备实际注册的池保存在应用私有目录，后续资源升级会保留它。

### 2. 构建加密播放库

`native/` 提供自行实现的 CENC MP4 流式解密核心，沿用 `com.example.shortplay.CryptoNative`
JNI 接口与 ExoPlayer。Gradle 通过 CMake 自动编译 `libshortplay_crypto.so`，支持边读边解密与拖动，
使用 NDK 28 并显式设置 16 KB ELF 对齐，不再需要下载外部预编译 crypto 库。

升级旧工作区时，请把 `android/app/src/main/jniLibs/arm64-v8a/libshortplay_crypto.so`
备份到 `jniLibs` 之外，避免它与自动生成的库重复。Gradle 会检查旧输入以及 Go JNI 库是否就绪。
`build_backend -Jni` / `--jni` 仍只负责编译 旧后端；C 库由下一步 APK 构建自动生成。

实现范围、支持的 MP4 格式、主机回归和设备验证边界见 [C 库说明](native/README.md)。
本轮测试结果、APK 校验值和 16 KB 设备验证状态见 [C 库验证记录](docs/native-c-validation-20260908.md)。
旧库来源调查保存在 [历史来源记录](docs/native-crypto-provenance-20260908.md)。

### 3. 构建 APK

```powershell
cd fqapp
flutter pub get
# 当前 JNI 后端只提供 arm64-v8a，构建时显式指定目标 ABI
flutter build apk --debug --target-platform android-arm64
flutter build apk --release --target-platform android-arm64
```

生成的 APK 仅支持 `arm64-v8a`；如果要支持 32 位或 x86 设备，需要先为
对应 ABI 编译并打包 `liblegacy.so` 和 `libshortplay_crypto.so`，同时调整 ABI 配置。

### 4. 安装运行

```powershell
# 真机 USB 调试连接后
adb install -r build\app\outputs\flutter-apk\app-debug.apk
adb shell am start -n com.fqapp.fqapp/.MainActivity
```

首次启动：App 将运行时资源部署到 `files/backend/`，通过 JNI 启动本地后端，健康检查通过后进入主界面。
已有缓存时也可在启动页面直接进入离线阅读。

---

## 构建 APK

### Gradle 国内镜像

`android/settings.gradle.kts` 与 `android/build.gradle.kts` 已配置阿里云镜像，加速依赖下载：

```kotlin
maven { url = uri("https://maven.aliyun.com/repository/google") }
maven { url = uri("https://maven.aliyun.com/repository/central") }
maven { url = uri("https://maven.aliyun.com/repository/public") }
```

### Gradle 发行版镜像

若 `services.gradle.org` 下载慢，手动放入 `%USERPROFILE%\.gradle\wrapper\dists\gradle-9.1.0-all\<hash>\gradle-9.1.0-all.zip`（从腾讯云镜像 `https://mirrors.cloud.tencent.com/gradle/gradle-9.1.0-all.zip` 下载）。

### 常见构建问题

| 问题 | 解决 |
|---|---|
| `Could not close incremental caches` | 已在 `gradle.properties` 关闭 Kotlin 增量编译 |
| 构建偶发 `IllegalStateException: The settings are not yet available for build` | Gradle 9.1.0 配置缓存推广处理器（`ConfigurationCachePromoHandler`）的偶发 bug，重跑即可恢复，无需修改配置（详见下方「已知问题与调试」） |
| `Unable to locate Android SDK` | `flutter config --android-sdk C:\android-sdk` |
| `Flutter requires Android SDK 36` | `sdkmanager "platforms;android-36"` |
| maven.google.com 超时 | 已配置阿里云镜像 |
| `flutter doctor --android-licenses` 卡住 | `sdkmanager --licenses` 手动接受 |

---

## Android 后端进程集成

### 部署流程（`BackendService._deploy`）

1. 将 `config.json`、`filter.json`、`device_pool.example.json` 部署到应用私有目录 `files/backend/config/`。
2. 首次启动时用示例初始化 `device_pool.json`；以后保留后端注册并保存的实际设备池。
3. 从 Flutter 资源清单枚举并部署全部 `filters/`、`web/`、`plugins/` 文件，包含 CSS 和字体。内容变更时替换旧资源。
4. 仅桌面进程路径另外部署 `assets/bin/` 并设置执行权限；Android 从 APK 加载 JNI 库。

### 启动流程（`BackendService.start`）

```dart
// Android: MethodChannel → Kotlin → liblegacy.so (JNI)
// Desktop：
_proc = await Process.start(bin, [
    '-config', ..., '-pool', ..., '-filter', ..., '-runtime-dir', dir.path,
  ], workingDirectory: dir.path);
```

- 并发 `start()` 等待同一次完整启动，`stop()` 会等待进行中的部署与启动结束再清理。
- 健康检查默认总时限 15 秒，单次请求覆盖连接、响应头和响应体的时限，失败后间隔最多 300 毫秒重试。
- 启动诊断、桌面后端 stdout/stderr 写入 `backend.log`。后端子进程退出时清除引用；显式 `stop()` 等待其退出，超时后升级终止信号。

### ⚠️ SELinux 关键限制（已实测）

| 执行方式 | 结果 |
|---|---|
| Flutter `Process.start`（untrusted_app 域） | ❌ `Permission denied` |
| `adb shell run-as <pkg> ./`（shell 域） | ✅ 可执行 |

**Android 的 `untrusted_app` SELinux 域禁止执行 `app_data_file` 下的二进制**。
本项目已实现 JNI 路径：Go 使用 `-buildmode=c-shared` 生成 `liblegacy.so`，
Kotlin 通过 `System.loadLibrary("")` 加载，再调用匹配的 JNI 启停入口。
Android 上 JNI 失败会显示启动错误与重试入口，不回退到 `Process.start`。

安装 NDK（例如 `sdkmanager "ndk;28.2.13676358"`）后编译：

```powershell
.\scripts\build_backend.ps1 -Jni
```

Go JNI 入口会使用配置文件推导运行目录，静态页面、过滤器和 `src/` 均按绝对路径加载；HTTP 服务只绑定 `127.0.0.1`。
加密播放所需的 `libshortplay_crypto.so` 由 APK 构建自动从 `native/` 生成。

---

## API 对接说明

App 主要通过 `ApiClient` 调用后端 **`/api/*` 桥接层**（`webui.go`），首页推荐使用
`/api/v1/recommend/homepage`。客户端模型同时兼容归一化结果及部分旧版响应结构：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/recommend/homepage?tab_type=&offset=&session_id=` | 首页分类推荐及游标分页 |
| GET | `/api/search?source=番茄&query=&page=` | 搜索（返回 `{code,message,data:{search_tabs:[{title,data:[]}]}}`） |
| GET | `/api/detail?source=番茄&book_id=&tab=` | 详情（tab=听书 走有声详情） |
| GET | `/api/directory?source=番茄&book_id=&tab=` | 目录（短剧走剧集；输出 `chapterListWithVolume` 格式） |
| GET | `/api/content?source=番茄&item_id=&tab=` | 正文（小说/漫画/听书/短剧分发） |
| GET | `/api/resolve?url=` | 分享链接解析 |
| GET | `/api/download?source=番茄&book_id=` | 整本 TXT 下载 |
| GET | `/health` | 健康检查（返回设备池数量） |

**响应信封**：客户端接受 `code=200`（Web 桥接）或 `code=0`（上游兼容接口）的成功响应；
其他显式状态码或 `success=false` 视为错误。

**搜索 tab 归一化**：后端将“综合”tab 的结果整理为书籍/漫画/听书/短剧各 tab
（`normalizeSearchTabs`），搜索页按 tab 展示；首页搜索回退还会按条目实际 `kind` 筛选目标类型。

---

## 数据模型

### `MediaItem`（归一化条目）

`MediaItem.fromRaw()` 兼容番茄 API 的各种字段形状（参考 早期前端 `norm()`）：

| 字段 | 来源优先级 |
|---|---|
| `id` | 小说/漫画/听书使用内容 ID；短剧优先使用系列 `pseries_id`/`series_id`，单集结果保留 `episodeId` |
| `kind` | 合法显式 `kind` 优先；缺失或未知时根据视频、漫画、音频标识推断，否则为小说 |
| `title` | 高亮标题 → 外层标题 → 嵌套标题/书名 → `cell_name` |
| `cover` | `thumb_url` → `cover`/`cover_url`/`poster` |
| `author` | `author`/`author_name` |
| `badge` | 已保存的 `badge` → `category`/`type`/`cell_alias`/`card_tips` |
| `ep` | 已保存的 `ep` → `serial_count`/`item_count`/`episode_count` |

### `Chapter`（目录章节）

`chapterListWithVolume` 格式 → `itemId`/`title`/`volume_name`，按卷分组。

短剧上游的 `data.episodes`、`item_data_list` 和 `lists` 也会统一转换为同一模型，客户端因此可以兼容新旧后端二进制。

### `SearchTab`（搜索 tab）

`title` + `items[]`，支持嵌套 `video_data`、`book_data` 展开。

---

## 页面说明

### 首页（`home_page.dart`）
- 优先调用真实 `/api/v1/recommend/homepage`，旧后端不可用时回退搜索结果
- 3 列封面网格，下拉刷新

### 搜索（`search_page.dart`）
- 顶部搜索框（回车/图标触发）
- 结果按 tab 用 ChoiceChip 切换
- 接近列表底部时自动分页，按作品 ID 去重
- 保存最近 20 条搜索，支持点击重搜、单条删除和全部清空

### 详情（`detail_page.dart`）
- 封面 + 标题 + 作者 + 简介
- 目录网格（4 列），卷名分组
- 底部：阅读/播放/续看按钮
- 短剧类型 → 播放器；小说 → 阅读器；漫画/听书明确提示开发中

### 阅读器（`reader_page.dart`）
- 加载解密后的章节正文，保留 HTML 和纯文本中的段落边界
- 正文首行缩进两字、续行顶格，两端对齐；段距与行距独立，开头重复的章节标题只显示一次
- 左右点击先滚动一屏，到章节边界才换章；中间点击显示或隐藏控制栏
- 字号、字重、行距、段距、边距和阅读主题实时预览并保存
- 目录支持搜索、倒序、当前章定位与缓存标记
- 章节、滚动位置和封面写入历史，重新进入可续读
- 正文和目录自动保存到磁盘，底部“缓存”可下载后续 20/50/100 章并随时停止
- 缓存上限为 500 章或 80 MB，超出后清理较久未读的章节

最新正文排版修复和交付状态见 [小说正文换行与排版记录](docs/reader-paragraphs-validation.md)。

### 播放器（`player_page.dart`）
- 原生 Media3 播放器播放后端返回的流地址（客户端自动补全 URL）
- 自动连播（播完自动下一集）
- 控制栏三秒后自动隐藏；单击显示或隐藏，双击播放或暂停
- 支持搜索选集、上下集、快进快退 10 秒和全屏
- 0.75～2 倍速可持久保存，长按临时 2 倍速，松手恢复
- 暂停时拖动进度保持暂停，切到后台暂停播放
- 播放秒数、集数和封面定时写入历史，支持续看

### 书架（`library_page.dart`）
- 阅读历史：支持列表或封面网格（含进度、集数）
- 清空功能
- 右上角“离线缓存”可直接打开已缓存书籍，不依赖在线详情或目录接口
- 设置 → 数据 → 章节缓存，可查看占用、删除单本或清空全部缓存；阅读历史保留
- 本地服务启动期间也可从“离线阅读”入口打开缓存

### 我的（`mine_page.dart`）
- 服务状态（健康检查）
- 后端地址展示

---

## 已知问题与调试

### 1. 原生库与真机验证

- Android 后端必须使用 JNI。执行 `scripts/build_backend.ps1 -Jni` 或 Bash 版本的 `--jni` 生成 `liblegacy.so`。
- 加密播放使用 `native/` 中的 C 源码，Gradle/CMake 自动生成 `libshortplay_crypto.so`。
- 准备 Go JNI 后端后构建 arm64 APK，再用设备验证 `/health`、搜索、阅读和加密视频播放。Android 的纯 JVM 测试不会加载这两份库。
- 本轮审查的修复范围、自动化验证与剩余限制见 [全项目代码审查记录](docs/project-code-review-20260908.md)。

### 2. 调试技巧

```powershell
# 查看后端日志（App 内写入）
adb shell run-as com.fqapp.fqapp cat files/backend/backend.log

# 查看部署文件
adb shell run-as com.fqapp.fqapp ls -la files/backend/

# 端口转发测试（后端起来后）
adb forward tcp:18080 tcp:8080
curl http://127.0.0.1:18080/health

# Flutter 日志
adb logcat -s flutter
```

### 3. 设备池过期
若 content/full 解密乱码，删除 `files/backend/config/device_pool.json` 重启 App 即可自动重注册。

### 4. 构建偶发 `The settings are not yet available for build`

**现象**：`flutter build` / `gradlew` 偶发报
`IllegalStateException: The settings are not yet available for build`，
但重跑即恢复（daemon 日志显示失败后紧接着的 daemon 几秒内成功）。

**根因**（已定位到 Gradle 9.1.0 字节码）：调用链为
`ConfigurationCachePromoHandler.beforeComplete()` →
`runWithoutBuildDefinition()` → `ResolvedBuildLayout.isBuildDefinitionMissing()` →
`DefaultGradle.getSettings()`。`getSettings()` 在 settings 尚未 attach 时直接抛异常；
该处理器是 Gradle 9.1.0 新增的「配置缓存推广」功能（构建结束时打印
`Consider enabling configuration cache`），在复合构建（`settings.gradle.kts` 中
`includeBuild(flutter_tools)` + 子工程 `:gradle`）首次初始化的时序里偶发踩中此状态。

**结论**：这是 Gradle 9.1.0 自身缺陷，非项目代码问题，且无法稳定复现。

**处理**：无需修改代码/配置；偶发时重跑即可。若想彻底规避，可升级 Gradle
补丁版本（9.1.x / 9.2，需先确认与 AGP 9.0.1 兼容）。

> 注意：`Daemon compilation failed`（Kotlin 2.3.20，见
> `android/.kotlin/errors/*.log`）是另一独立问题 —— Kotlin 编译守护进程崩溃，
> 已通过 `gradle.properties` 的 `kotlin.incremental=false` 与
> `kotlin.compiler.execution.strategy=in-process` 规避，勿因 AGP 9 弃用警告而删除这些配置。

---

## 开发计划

- [x] **JNI 集成后端**：Go c-shared → `liblegacy.so` → `System.loadLibrary` 启动（解决 SELinux）
- [x] 小说搜索、目录、正文、章节/滚动位置续读
- [x] 短剧目录归一化、自动连播、播放进度续看
- [x] 首页真实推荐接口（`/api/v1/recommend/homepage`）
- [ ] Android arm64 真机 smoke test（启动、搜索、阅读、播放）
- [x] 短剧流式播放（Media3 + JNI CENC 解密与 HTTP Range）
- [x] 可重建的 C 短剧流式解密与 16 KB ELF 链接配置（见 [C 库说明](native/README.md)）
- [ ] 16 KB 页 Android 设备上的加密播放与生命周期验证
- [ ] 漫画阅读页（图片平铺/翻页）
- [ ] 听书播放页（音频播放器）
- [x] 小说章节下载/离线缓存
- [ ] Release 签名配置
- [ ] 整本 TXT 导出

---

## 许可

请遵守上游项目许可与相关法律法规，仅限个人学习研究使用。
