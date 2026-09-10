# fqapp — 番茄小说/短剧/漫剧/听书/漫画 Flutter 客户端

一个运行在 **Android 手机本地** 的番茄内容聚合客户端：内置 Go 版 `` 后端，Flutter 原生 UI 提供小说阅读、短剧与漫剧播放、前台听书、漫画阅读、搜索、历史和小说离线缓存。

[下载 v1.0.17 测试安装包（ARM64）](https://github.com/ch6vip/fqapp/releases/tag/v1.0.17)

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
| 📖 小说阅读 | 图文正文、插图放大、左右分页或滚动、排版与字体导入、阅读亮度、离线缓存 |
| 🎬 短剧播放 | 集数列表、自动连播、播放/暂停、上/下一集 |
| 漫剧 | 独立首页与搜索分类、剧集目录、视频播放和进度续看 |
| 🖼 漫画 | 竖向连续阅读、目录切章、单图重试、放大查看、阅读位置恢复 |
| 🎧 听书 | 智能朗读音色、真人讲书、边听边读字幕、关联作品、定时关闭、前台播放/暂停、目录切章、拖动/快进、倍速、自动下一章、播放进度恢复 |
| 🔍 搜索 | 关键词或作品 ID 搜索，按 综合/短剧/漫剧/漫画/听书 分 tab，小说结果保留在综合中 |
| 📋 详情 | 封面 + 分类/完结/字数 + 作者等级 + 榜单/在读/评分 + 标签 + 简介 + 目录 + 书评 |
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
│   │   ├── media_item.dart          # MediaItem/Chapter/SearchTab 模型 + 归一化解析
│   │   └── chapter_media.dart       # 听书音源、音色与漫画图片模型
│   ├── services/
│   │   ├── backend_service.dart     # 旧后端管理(部署/JNI/桌面进程/健康检查/日志)
│   │   ├── api_client.dart          # 后端 HTTP 客户端(对接 /api/* 桥接层)
│   │   └── library_store.dart       # 历史/阅读时长本地存储
│   ├── pages/
│   │   ├── home_page.dart           # 首页(推荐流)
│   │   ├── search_page.dart         # 搜索(分 tab)
│   │   ├── detail_page.dart         # 详情(简介+目录)
│   │   ├── reader_page.dart         # 小说阅读器
│   │   ├── player_page.dart         # 短剧/漫剧播放器(Media3 + JNI 流式解密)
│   │   ├── audio_page.dart          # 前台听书(Media3 普通音频 URL)
│   │   ├── comic_reader_page.dart   # 漫画连续阅读、目录与页内位置恢复
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

### GitHub Actions 云端编译

打开 [Actions → Android APK](https://github.com/ch6vip/fqapp/actions/workflows/android-apk.yml)，
点击 **Run workflow** 即可从源码构建。`master` 上的应用、原生库及构建配置变更也会自动触发。
运行成功后，在该次运行的 **Artifacts** 中下载 `fqapp-arm64-运行编号`；其中包含
`app-release.apk`、SHA-256、签名与 16 KiB 对齐报告、源码版本和工具版本，产物保留 14 天。

[工作流](.github/workflows/android-apk.yml) 固定 Flutter `3.44.6`、Go `1.26.7`、JDK 17、
NDK `28.2.13676358` 和 CMake `3.22.1`。Go JNI 后端与 C 解密库都会在 runner 上编译，
构建脚本默认保留本仓库已有的移动端资源。CI 设置 `FQAPP_USE_MAVEN_MIRRORS=false` 使用
官方 Maven 源；本地构建默认仍使用国内镜像。

每次构建先运行 Flutter 静态分析与完整单元/组件测试，再生成并校验 APK。

`` 是私有仓库，CI 固定读取专用 `fqapp-android` 分支上的已提交版本
[`f667122`](https://github.com/ch6vip//commit/f66712208c305c1c24b98cb4231b9601f7514ea1) 并原样构建，不打任何补丁。
该提交包含小说图文解密契约、短剧剧集标题索引、章评／段评后端，以及短剧系列详情（演员表）；这些改动曾以
[配套补丁](patches//README.md) 的形式随 App 保存，现已并入后端历史并退休。
完整 Go 测试通过后再构建 JNI，构建报告记录该固定提交。
本地其它未提交的后端改动不进入云端构建。
本仓库已配置以下 Actions secrets，复制工作流到其它仓库时需要配置对应内容：

| Secret | 用途 |
| --- | --- |
| `LEGACY_READONLY_SSH_KEY` | 仅授予 `` 读取权限的独立 SSH deploy key |
| `ANDROID_DEBUG_KEYSTORE_BASE64` | 固定测试 keystore 的 Base64 内容，保持各次 APK 的签名一致 |

云端 APK 使用与当前本地验证包一致的**调试签名**，可以覆盖安装同签名的测试版本。
CI 通过 `FQAPP_DEBUG_KEYSTORE` 显式传入临时 keystore 的绝对路径，并在编译前及 APK
生成后核对预期证书指纹，避免使用 runner 其它默认目录中的调试证书。
正式发布需要另行配置正式签名，并同步更新预期证书指纹。
ELF/ZIP 的 16 KiB 对齐检查通过后，仍需在对应 Android 设备上验证实际播放。

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
`/api/v1/recommend/homepage`。漫剧首页使用 `tab_type=24`；听书使用现有音频播放接口，漫画首页使用真实漫画分类搜索。
客户端模型同时兼容归一化结果及部分旧版响应结构：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/recommend/homepage?tab_type=&offset=&session_id=` | 首页分类推荐及游标分页 |
| GET | `/api/v1/search?query=&tab_type=&offset=&count=10` | 搜索页按分类请求：综合 `1`、短剧/漫剧 `11`、漫画 `8`、听书 `2`，使用返回的游标 |
| GET | `/api/v1/books/{id}/detail` | 按作品 ID 精确查询名称、封面和类型；详情不可用时使用同一路径的 `/directory` 中的 `book_info`。详情页的全部富元数据（分类/完结状态/字数/在读人数/评分/标签/作者等级/榜单）都取自这一份响应，不额外发请求 |
| GET | `/api/v1/series/{id}` | 短剧／漫剧系列详情：标题、简介、集数、播放量、分类，以及**演员表**（`data.video_data.celebrities`，含 `nickname`/`role_name`/`avatar`）。也可经 `/api/v1/videos/{id}/detail` 访问。阅读类接口不含演员字段 |
| GET | `/api/v1/books/{id}/comments` | 书评列表与页级计数（`comment_cnt`、`score_cnt`、`context`）；详情页书评区与听书页「书评」使用 |
| GET | `/api/v1/books/{id}/related` | 关联作品（`book_data` 原著小说 / `video_data` 改编短剧）；听书页横向卡片使用 |
| GET | `/api/v1/books/{id}/tones` | 智能朗读音色（**小写键** `id`/`title`/`description`/`badge`/`is_multi_tone`）与真人讲书 `audio_tones`（用 `abook_id`）；听书页音色卡片使用 |
| GET | `/api/v1/chapters/{id}/reviews` | 章评／段评，返回按段号索引的数量与评论 ID（`comment_source=3` 取段评）；正文需再用 `/books/{id}/reviews` 的 `insert_comment_ids` 按 ID 回填 |
| GET | `/api/v1/chapters/{id}/paragraphs/{n}/reviews` | 同上，并带上 `para_index` 供客户端定位段落 |
| GET | `/api/v1/books/{id}/reviews?book_id=&group_id=&insert_comment_ids=` | 评论列表。默认即整本书评；`insert_comment_ids` 按 ID 回填正文，是段评的第二跳 |
| GET | `/api/v1/chapters/{id}/timeline` | 边听边读字幕（`data.speech_text`，格式 `[起始毫秒,0]<...>文本`）。**必须显式传 `genre` 与有效 `tone_id`**：后端默认的 `genre=4, tone_id=99` 恒返回 `1301008`，无字幕是该端点的正常答案 |
| GET | `/api/v1/search?query=&tab_type=8&offset=&count=10` | 漫画专属搜索，按真实类型识别结果 |
| GET | `/api/v1/search?query=漫剧&tab_type=11&offset=&count=10` | 漫剧首页推荐耗尽后的搜索来源，仅保留明确漫剧类型，沿用返回的 `next_offset` |
| GET | `/api/v1/audio/play?book_id=&item_ids=&tone_id=0` | 听书播放模型和时长，默认音色为 0 |
| GET | `/api/search?source=番茄&query=&page=` | 旧版搜索桥接，仍供部分首页回退调用 |
| GET | `/api/detail?source=番茄&book_id=&tab=` | 详情（tab=听书 走有声详情） |
| GET | `/api/directory?source=番茄&book_id=&tab=` | 目录（短剧走剧集；输出 `chapterListWithVolume` 格式） |
| GET | `/api/v1/chapters/{id}/novel` | 小说图文正文，使用 `data.content` 中已解密的 HTML，要求 `data.content_decrypted=true` |
| GET | `/api/content?source=番茄&item_id=&tab=` | 正文（小说/漫画/听书/短剧分发） |
| GET | `/api/content?source=番茄&item_id=&tab=短剧&mode=stream` | 短剧和漫剧视频流地址与内容密钥 |
| GET | `/api/resolve?url=` | 分享链接解析 |
| GET | `/api/download?source=番茄&book_id=` | 整本 TXT 下载 |
| GET | `/health` | 健康检查（返回设备池数量） |

**响应信封**：客户端接受 `code=200`（Web 桥接）或 `code=0`（上游兼容接口）的成功响应；
其他显式状态码或 `success=false` 视为错误。

**小说插图**：`ApiClient.chapterContent` 优先读取 v1 图文接口，失败时回退原纯文字正文。完整插图支持需要同步 `/internal/endpoints/base.go` 的解密修复，再运行 `scripts/build_backend.ps1 -Jni` 构建 Android 后端；上游的 `c=1` 是加密标志，密文来自 JSON `data.content`。旧后端没有解密成功标记时，客户端回退文字。该修复现已在 CI 固定的 `` 提交 [`f667122`](patches//README.md) 中，本地从该提交构建即可，不能复用旧 `liblegacy.so`。批量缓存保留已有插图并同步阅读器内存，纯文字回退会明确提示插图未更新。接口样本见 [小说插图修复记录](docs/reader-illustrations-validation-20260910.md)，缓存与 CI 验证见[审查修复记录](docs/review-fixes-validation-20260910.md)。

**搜索分类与分页**：搜索页使用 `/api/v1/search` 请求所选分类，在拆分漫剧之前先选取对应的上游 tab，
再按条目实际 `kind` 筛选。综合保留全部作品；短剧、漫剧、漫画、听书分别只展示 `video`、`manju`、`manga`、`audio`。
每个分类独立保存结果、错误和 `next_offset`，空页或重复页有前进游标时可继续加载，失败重试保留原偏移量。
旧桥接的 `normalizeSearchTabs` 会将综合结果复制到空分类，且按页码换算偏移量，因此搜索页直接使用 v1 接口。

**漫剧与漫画参数不同**：首页的漫剧为 `24`、看剧为 `8`、漫画为 `9`；搜索的视频为 `11`、漫画为 `8`、听书为 `2`。
当前漫剧搜索复用视频 tab，漫剧详情和目录继续使用桥接参数 `tab=短剧`，目录对应 `/api/v1/manga/videos/{series_id}`。
漫剧首页未提供下一页游标时直接转搜索，不能把 `bottom_unlimited=true` 当作可递增的推荐游标。
接口样本、分类规则与验证边界见 [漫剧接入验证](docs/manju-validation-20260910.md)。

---

## 数据模型

### `MediaItem`（归一化条目）

`MediaItem.fromRaw()` 兼容番茄 API 的各种字段形状（参考 早期前端 `norm()`）：

| 字段 | 来源优先级 |
|---|---|
| `id` | 小说/漫画/听书使用内容 ID；短剧/漫剧优先使用系列 `pseries_id`/`series_id`，单集结果保留 `episodeId` |
| `kind` | `book`/`video`/`manju`/`manga`/`audio`；合法显式类型优先，缺失时按结构化标识推断，否则为小说 |
| `title` | 高亮标题 → 外层标题 → 嵌套标题/书名 → `cell_name` |
| `cover` | `thumb_url` → `cover`/`cover_url`/`poster` |
| `author` | `author`/`author_name` |
| `badge` | 已保存的 `badge` → `category`/`type`/`cell_alias`/`card_tips` |
| `ep` | 已保存的 `ep` → `serial_count`/`item_count`/`episode_count` |

### `Chapter`（目录章节）

`chapterListWithVolume` 格式 → `itemId`/`title`/`volume_name`，按卷分组。

短剧和漫剧上游的 `data.episodes`、`item_data_list` 和 `lists` 也会统一转换为同一模型，客户端因此可以兼容新旧后端二进制。

### `SearchTab`（搜索 tab）

`title` + `items[]`，支持嵌套 `video_data`、`book_data` 展开，并保留可选 `hasMore` / `nextOffset`。
漫剧根据 `genre=205` 或明确的类型标签识别，标题、简介和作者提到“漫剧”不会改变作品类型。

---

## 页面说明

### 首页（`home_page.dart`）
- 提供推荐、小说、短剧、漫剧、漫画和听书分类；推荐页混排各类内容
- 优先调用真实 `/api/v1/recommend/homepage`，旧后端不可用时回退搜索结果
- 漫剧首屏使用专属推荐，后续按视频搜索的实际游标加载；筛选后空页或重复页仍可继续，来源耗尽后停止请求
- 3 列封面网格，下拉刷新

### 搜索（`search_page.dart`）
- 顶部搜索框（回车/图标触发）
- 输入 15 至 20 位纯数字自动按作品 ID 查找；`id:作品ID` 可显式查询较短的 ID，`1984` 等短数字默认作为关键词
- ID 查询支持小说、短剧、漫剧、漫画和听书；结果按真实类型归类，可点击“按关键词搜索”切换方式
- 结果按 tab 用 ChoiceChip 切换
- 分类固定依次为综合、短剧、漫剧、漫画、听书，综合中保留小说等作品结果
- 首次选择分类时请求对应来源，再次切换复用该分类的结果；重新搜索重置各分类，忽略旧请求的迟到响应
- 接近列表底部时按实际游标自动分页，按类型和作品 ID 去重；空页或重复页保留手动加载入口，避免连续空转请求
- 首屏和分页失败均可重试；接口明确结束、游标缺失或不再前进时停止分页
- 保存最近 20 条搜索，支持点击重搜、单条删除和全部清空

分类请求与分页修复的回归结果见 [搜索分类修复验证](docs/search-categories-validation-20260910.md)。
作品 ID 的接口样本与验证结果见 [ID 搜索验证](docs/id-search-validation-20260910.md)。

### 详情（`detail_page.dart`）
- 左上封面（3:4）+ 右侧标题、`分类 · 完结状态 · 字数`、「番茄原创」徽章，标题始终完整换行不截断
- 作者行：头像、笔名、等级徽章（上游 `user_title_infos` 的「作家Lv.5」）与关注按钮
- 数据三栏：榜单、正在阅读人数、评分（含五星），按可用字段自适应列数
- 演员表：短剧／漫剧显示横向演员卡片（头像、姓名、饰演角色）。数据来自 `/api/v1/series/{id}`；
  该接口失败或没有演员时不显示该区块，不影响播放。头像上游为 HEIC，解码失败时降级为姓名首字
- 书籍简介三行折叠可展开，题材标签，`查看目录` 行与 3 章目录预览
- 书评区：评分卡 + 评论列表（0-10 分转五星、相对时间、在读时长、点赞与回复数）
- 底部：听书 / 下载 / 阅读（播放、续看）三键；听书与下载仅小说显示
- 听书直接进入听书页并接续已保存的进度；下载复用阅读器的章节缓存面板
- 按内容类型打开小说阅读器、短剧/漫剧播放器、听书播放器或漫画阅读器
- 续读/续听优先按已保存的章节 ID 定位，目录更新后仍能找到原章节
- 富元数据直接取自同一份详情响应，不额外发请求；书评请求失败只隐藏该区块，不影响整页

### 阅读器（`reader_page.dart`）
- 加载解密后的图文正文，保留段落、插图和图注的原始顺序；签名图片地址保留，使用上游尺寸预留空间
- 插图保持原比例，分页时整张显示，点击进入全屏并可双指缩放；加载失败可重试，加载完成不会重新分页
- 正文首行缩进两字、续行顶格，两端对齐；段距与行距独立，开头重复的章节标题只显示一次
- 默认收起菜单，点击正文中央滑出上下菜单；菜单叠在正文上，不改变正文高度或滚动位置。返回键先收起菜单，再退出阅读
- 默认左右分页，可点击或滑动翻页；翻过章节末页进入下一章首页，返回上一章进入末页。排版面板可切换为上下滚动，滚动模式保留点击滚动一屏
- 分页按当前字体、字号、留白与窗口尺寸计算，保留完整文本行；页脚显示本章真实页码，排版变化和横竖屏切换后重新计算
- 页眉显示书名与章节，页脚显示章节序号、全书进度、时间和电量；可在排版面板关闭阅读信息。全书百分比按章节与章内位置估算
- 字号、字重、字距、行距、段距、标题大小与对齐、上下左右留白和四种阅读背景实时预览并保存
- 支持通过 Android 系统文件选择器导入 TTF、OTF、TTC 字体（单文件不超过 32 MB），也可切回系统字体
- 亮度可手动调整或跟随系统，只影响当前阅读窗口；切到后台、退出和 Activity 重建时恢复原窗口亮度
- 菜单、排版、目录和缓存面板随阅读主题配色；小屏、大字体与横屏下可滚动访问设置
- 目录支持搜索、倒序、当前章定位与缓存标记
- 章节 ID、图文位置和封面写入历史，换字号、横竖屏或阅读方式后按原位置续读；兼容旧文字偏移和滚动历史
- 章节正文解析上游 `<p idx>` 段落 ID，随结构化缓存持久化；旧缓存没有该字段时只影响段评
- 段评：控制栏入口显示本章条数，面板按段落列出并展示该段原文；展开某段时才拉取正文
  （idea 接口只给数量与评论 ID，正文按 ID 回填）；本章没有段评时入口隐藏
- 正文和目录自动保存到磁盘，底部“缓存”可下载后续 20/50/100 章并随时停止；旧文字缓存立即可读，联网后自动补图并迁移阅读位置
- 章节缓存保存图片地址和尺寸；插图文件首次显示时联网加载并自动缓存。过期签名在打开章节或恢复前台时刷新，离线时保留已有图文
- 缓存上限为 500 章或 80 MB，超出后清理较久未读的章节

插图与交付状态见 [小说插图修复记录](docs/reader-illustrations-validation-20260910.md)，分页基础见 [阅读分页验证记录](docs/reader-pagination-validation-20260910.md)，菜单与设备设置见 [阅读界面验证记录](docs/reader-interface-validation-20260910.md)，正文分段规则见 [小说正文换行与排版记录](docs/reader-paragraphs-validation.md)。

### 播放器（`player_page.dart`）
- 短剧与漫剧共享播放器；漫剧保留独立历史类型，并兼容以前按短剧保存的系列和播放位置
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

### 听书（`audio_page.dart`）
- 顶栏显示当前朗读模式（智能朗读 / 真人讲书）、状态圆点与更多菜单
- 书目卡显示书名、`完结 · N万人在读` 与目录入口
- 简介块（含题材标签）、关联作品（原著小说 / 改编短剧，可跳转详情）
- 边听边读字幕：按播放位置高亮当前句并预览下一句
- 操作行：语速 / 加入书架 / 下载 / 书评 / 更多
- `-15s` 进度条 `+15s` 与 `时:分/总时长`；控制行：目录 / 上一章 / 播放暂停 / 下一章 / 定时
- 智能朗读音色卡片（多角色对话、成熟大叔音等，含「升级」角标），切换音色时保留播放位置
- 定时关闭（15/30/60 分钟），到时自动暂停
- 使用已有 Media3 播放器，提供播放/暂停、进度拖动、前后 15 秒和 0.5～2 倍速
- 目录可搜索，支持上一章、下一章及自动连续播放
- 后端提供多个音色时可切换，并记住音色、倍速、自动下一章与书架状态
- 播放秒数与章节定时保存，暂停、切章和退出时立即保存；重新进入可续听
- 切到后台暂停，回到前台后手动继续；本版采用前台播放，不包含后台服务或锁屏控制

> **听书页的「书评」与章评**：官方听书页的操作项是「章评」（章末讨论），但章评属于
> 章节而不是正在收听的书；该面板展示的是整本书评，所以按实际内容标注为「书评」。
> 章评与段评已由后端提供：`/api/v1/chapters/{id}/reviews` 走 item-ideas 服务，
> 返回按段号索引的数量与评论 ID；正文需要再用评论列表端点按段落懒加载。
> 完整契约见 [章评端点 Agent Note](.agents/notes/implemented/feature/2026-09-10-chapter-ideas-endpoint.md)。

### 漫画（`comic_reader_page.dart`）
- 按接口顺序竖向阅读图片，支持章节目录和上下章
- 图片按需加载并限制解码尺寸；单张失败可重试，点图可放大查看
- 用“图片序号 + 图片内位置”记录进度，图片加载改变高度后仍保持阅读位置
- 空章、章节请求失败和未显示成功的图片不会覆盖已有阅读进度
- 漫画和听书使用独立历史键，和同 ID 小说的阅读位置分别保存；书架与统计入口使用原作品 ID

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
- [x] 漫画原生阅读页、章节目录、单图重试与进度恢复
- [x] 听书前台播放、目录、倍速和进度恢复
- [x] 小说章节下载/离线缓存
- [ ] Release 签名配置
- [ ] 整本 TXT 导出

---

## 许可

请遵守上游项目许可与相关法律法规，仅限个人学习研究使用。
