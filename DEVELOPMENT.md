# fqapp 开发者文档

面向构建、修改和调试本项目的开发者。用户使用说明见 [README.md](README.md)。

> **核心设计**：Rust 原生核心在 Flutter 进程内运行，UI 通过 flutter_rust_bridge 直接调用；同一分发器另开 loopback HTTP 适配器（`127.0.0.1:8080`），继续服务内置 Web UI、`/api/*` 桥和 `/src/*` 漫画图。不需要自建服务器，不需要 root；签名、解密和本地缓存由手机完成，但在线内容仍需访问番茄上游。

---

## 目录

- [架构总览](#架构总览)
- [项目结构](#项目结构)
- [构建环境](#构建环境)
- [构建 APK](#构建-apk)
- [Android 原生核心集成](#android-原生核心集成)
- [API 对接说明](#api-对接说明)
- [数据模型](#数据模型)
- [页面说明](#页面说明)
- [已知问题与调试](#已知问题与调试)
- [开发计划](#开发计划)

---

## 架构总览

```
┌──────────────────────────────────────────────────┐
│                    Flutter App                   │
│                                                  │
│  ┌──────────┐   ┌────────────┐   ┌────────────┐  │
│  │ UI 页面  │──▶│ ApiClient  │──▶│  Backend   │  │
│  │(阅读/播放)│   │(归一化解析) │   │ Transport  │  │
│  └──────────┘   └────────────┘   └─────┬──────┘  │
│                                        │         │
│  ┌──────────┐   ┌────────────┐         │         │
│  │ Library  │   │  Backend   │         │         │
│  │  Store   │   │  Service   │─────────┘         │
│  │(历史/时长)│   │(核心初始化) │                  │
│  └──────────┘   └─────┬──────┘                   │
└───────────────────────┼──────────────────────────┘
                        │ flutter_rust_bridge (FFI)
                        ▼
              ┌───────────────────────────┐
              │    Rust 核心 fqapi_core    │
              │    libfqapi_core.so       │
              │ 签名 · 解密 · 设备池 · 分发器│
              └──────┬─────────────┬──────┘
                     │             │
      loopback HTTP  │             │ HTTPS (reqwest)
      127.0.0.1:8080 │             ▼
                     ▼      番茄上游 API (fanqie)
          内置 Web UI / /src/* 漫画图
```

### 数据流

1. **启动**：`main.dart` → `BackendService.start()` 将配置、过滤器、Web 页面及其 CSS/字体、插件部署到 app 私有目录 → 通过 flutter_rust_bridge 在进程内初始化 Rust 核心（`libfqapi_core.so`）→ 轮询 `/health` 直到 200。核心没有独立进程，也不再有 Kotlin/JNI 桥或桌面可执行文件。
2. **请求**：UI 页面 → `ApiClient` → `BackendTransport`（默认 `RustBackendTransport`，经 flutter_rust_bridge 直调 Rust 分发器；Web/测试用 loopback HTTP）→ 同一 Rust 分发器完成签名（Argus551）、设备池管理、请求上游、解密内容 → 返回归一化 JSON。
3. **存储**：历史和阅读时长走 `LibraryStore`（Hive）。

---

## 项目结构

```
fqapp/
├── lib/                             # Flutter UI、模型和本地状态
│   ├── main.dart                    # AppBootstrap + RootShell
│   ├── models/                      # 数据模型与响应解析
│   ├── pages/                       # 阅读、播放、搜索、首页等页面
│   ├── services/                    # 请求、缓存、历史和平台服务
│   ├── widgets/                     # 按界面分组的组件与通用组件
│   └── src/rust/                    # FRB 生成绑定
├── rust/                            # fqapi_core 源码、协议夹具和 Rust 测试
├── android/                         # Android 工程、原生插件与 JVM 测试
├── native/                          # CENC 流式 C 解密库、JNI 与 CMake
├── assets/                          # 配置示例、Web UI、插件、图片和动画
├── test/                            # Flutter 测试及 Node 主机回归
├── scripts/                         # 构建、验证和资源生成；见 scripts/README.md
├── .github/workflows/               # Android APK 与原生库 CI
├── flutter_rust_bridge.yaml         # FRB 代码生成配置
└── pubspec.yaml                     # Flutter 版本、依赖与资源声明
```

> **仓库不含原生二进制**：`libfqapi_core.so` 和 `libshortplay_crypto.so` 均被 Git 忽略。
> 前者可由 `rust/` 中的 Rust 源码经 `scripts/build_rust_backend.*` 重建；
> `libshortplay_crypto.so` 由本仓库 `native/` 中的 C 源码在 Android 构建时自动生成。
> Android 构建前需先运行 Rust 构建脚本生成 ARM64 核心库。
>
> 体积参考：Rust ARM64 `libfqapi_core.so` 为 6,125,392 字节（约 5.84 MiB）。这是本地 release
> 构建产物的实测大小，不是安装包体积，也不是性能结论。

---

## 构建环境

### 环境要求

| 工具 | 版本 | 用途 |
|---|---|---|
| Flutter | 3.44.6 (stable) | 构建 App |
| Dart SDK | 3.12+ | 随 Flutter |
| Rust | stable (cargo/rustc) | 编译原生核心 `fqapi_core` |
| flutter_rust_bridge | 2.13.0 | 生成 Flutter/Rust 绑定 |
| Android SDK | 36 (platform) + Build-Tools | 编译 APK |
| JDK | 17 | Android Gradle 构建 |
| Android NDK | 28.2.13676358 | 交叉编译 Rust ARM64 核心与 C 流式解密库 |
| CMake | 3.22.1 | Android 构建自动编译 C 库 |

> Windows 下构建注意：Kotlin 增量编译在部分环境会报 `Could not close incremental caches`，已在 `android/gradle.properties` 中关闭（`kotlin.incremental=false`）。

### 1. 编译 Rust 原生核心

`rust/` 是产品唯一的后端实现（crate `fqapi_core`）。构建脚本会先用
`flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml` 生成 Dart/Rust 绑定，
再用 NDK 28.2.13676358 交叉编译 `aarch64-linux-android`，最后把 `libfqapi_core.so`
复制到 `android/app/src/main/jniLibs/arm64-v8a/`。

Windows PowerShell：

```powershell
.\scripts\build_rust_backend.ps1
```

Linux / macOS：

```bash
./scripts/build_rust_backend.sh
```

常用开关：`-SkipCodegen` 跳过绑定生成（绑定已是最新时），`-HostLib` 额外构建桌面 cdylib，
`-Profile debug` 选择 debug 配置。NDK 可由 `ANDROID_NDK_HOME` / `ANDROID_NDK_ROOT`
指定，或放在 Android SDK 的 `ndk/` 下；脚本优先使用 `ndk/28.2.13676358`。

`rust/testdata/` 的黄金向量由维护者的离线对照环境生成后随仓库分发；
正常构建与 CI 不依赖任何私有检出，也不需要额外的外部工具链。

> ⚠️ `assets/config/` 只包含 `config.json`、`filter.json`、`device_pool.example.json`
> 三个确定的配置文件。真实设备池 `device_pool.json` 里带 `secret_key`，**不随仓库或 APK 分发**；
> 首次启动时由 `BackendService` 从示例初始化，此后设备实际注册的池保存在应用私有目录，
> 后续资源升级会保留它。

### 2. 构建加密播放库

`native/` 提供自行实现的 CENC MP4 流式解密核心，沿用 `com.example.shortplay.CryptoNative`
JNI 接口与 ExoPlayer。Gradle 通过 CMake 自动编译 `libshortplay_crypto.so`，支持边读边解密与拖动，
使用 NDK 28 并显式设置 16 KB ELF 对齐，不再需要下载外部预编译 crypto 库。

升级旧工作区时，请把 `android/app/src/main/jniLibs/arm64-v8a/libshortplay_crypto.so`
备份到 `jniLibs` 之外，避免它与自动生成的库重复。Gradle 会检查旧输入与原生库是否就绪。
Rust 核心库由 `scripts/build_rust_backend.*` 生成；C 库由下一步 APK 构建自动生成。

实现范围、支持的 MP4 格式、主机回归和设备验证边界见 [C 库说明](native/README.md)。

### 3. 构建 APK

```powershell
cd fqapp
flutter pub get
# 当前 Rust 核心只提供 arm64-v8a，构建时显式指定目标 ABI
flutter build apk --debug --target-platform android-arm64
flutter build apk --release --target-platform android-arm64
```

生成的 APK 仅支持 `arm64-v8a`；如果要支持 32 位或 x86 设备，需要先为
对应 ABI 交叉编译并打包 `libfqapi_core.so` 和 `libshortplay_crypto.so`，同时调整 ABI 配置。

### GitHub Actions 云端编译

打开 [Actions → Android APK](https://github.com/ch6vip/fqapp/actions/workflows/android-apk.yml)，
点击 **Run workflow** 即可从源码构建。`master` 上的应用、原生库及构建配置变更也会自动触发。
运行成功后，在该次运行的 **Artifacts** 中下载 `fqapp-arm64-运行编号`；其中包含
`app-release.apk`、SHA-256、签名与 16 KiB 对齐报告、源码版本和工具版本，产物保留 14 天。

[工作流](.github/workflows/android-apk.yml) 固定 Flutter `3.44.6`、Rust 工具链与
flutter_rust_bridge `2.13.0`、JDK 17、NDK `28.2.13676358` 和 CMake `3.22.1`。
Rust 核心与 C 解密库都会在 runner 上编译。CI 设置 `FQAPP_USE_MAVEN_MIRRORS=false`
使用官方 Maven 源；本地构建默认仍使用国内镜像。

每次构建运行 Rust、Web 与诊断脚本测试、Flutter 静态分析与完整单元/组件测试，
并验证 Android JVM 测试和最终 APK。

产品构建不依赖任何私有检出或额外工具链；`rust/testdata/` 的黄金向量随仓库分发，
不进入产品构建。
本仓库已配置以下 Actions secrets，复制工作流到其它仓库时需要配置对应内容：

| Secret | 用途 |
| --- | --- |
| `RELEASE_KEYSTORE_BASE64` | 正式 keystore 的 Base64 内容 |
| `RELEASE_STORE_PASSWORD` | 正式 keystore 的 storePassword |
| `RELEASE_KEY_ALIAS` | 正式密钥别名（`fqapp`） |
| `RELEASE_KEY_PASSWORD` | 正式密钥的 keyPassword |

（`ANDROID_DEBUG_KEYSTORE_BASE64` 已不再被工作流使用：release 不再用调试密钥签名，
JVM 单测也不需要签名。可以保留，也可以删除。）

云端 APK 使用**正式 release 签名**，并开启 R8 混淆与资源裁剪。CI 先把 keystore 还原到
临时目录并核对证书指纹，再在 APK 生成后由 `scripts/verify_android_apk.py` 比对
`RELEASE_SIGNER_SHA256`；证书不符或根本没有签名都会直接失败，不会把错误签名的包发出去。

> ⚠️ 正式密钥取代了早先的测试密钥，两者**不能互相覆盖安装**。已发布的
> `v1.0.0-debug.20260906`、`v1.0.17` 都是旧签名的包，升级到正式签名版本需要**先卸载**
> （会清除阅读历史；`device_pool.json` 会按上文自动重新注册）。`debug` 构建仍然使用
> 调试签名，本地测试流程不受影响。

ELF/ZIP 的 16 KiB 对齐检查通过后，仍需在对应 Android 设备上验证实际播放；
开启 R8 后还必须额外确认 JNI 符号没被改名破坏（真机验收清单由维护者本地留档）。

### 4. 安装运行

```powershell
# 真机 USB 调试连接后
adb install -r build\app\outputs\flutter-apk\app-debug.apk
adb shell am start -n com.fqapp.fqapp/.MainActivity
```

首次启动：App 将运行时资源部署到 `files/backend/`，通过 flutter_rust_bridge 初始化 Rust 原生核心，健康检查通过后进入主界面。
已有缓存时也可在启动页面直接进入离线阅读。

---

## 应用图标

桌面图标、应用内“关于”页和内置网页使用同一份设计，原图与重新生成方法见
[图标资源说明](assets/branding/README.md)。图标资源已生成并随源码保存，正常构建无需额外步骤。

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

## Android 原生核心集成

### 部署流程（`BackendService._deploy`）

1. 将 `config.json`、`filter.json`、`device_pool.example.json` 部署到应用私有目录 `files/backend/config/`。
2. 首次启动时用示例初始化 `device_pool.json`；以后保留后端注册并保存的实际设备池。
3. 从 Flutter 资源清单枚举并部署全部 `filters/`、`web/`、`plugins/` 文件，包含 CSS 和字体。内容变更时替换旧资源。
4. 运行时资源不含任何可执行后端二进制；Rust 核心以 `libfqapi_core.so` 随 APK 打包，在进程内加载。

### 启动流程（`BackendService.start`）

```dart
// 默认：flutter_rust_bridge 直调 Rust 核心（进程内，无独立进程）
await rust.init(
  configPath: ..., poolPath: ..., filterPath: ..., runtimeDir: ..., port: 8080,
);
// Web / 测试：同一分发器另开 loopback HTTP 适配器，供浏览器入口与 /src/* 资源
```

- 并发 `start()` 等待同一次完整启动，`stop()` 会等待进行中的部署与启动结束再清理。
- 健康检查默认总时限 15 秒，单次请求覆盖连接、响应头和响应体的时限，失败后间隔最多 300 毫秒重试。
- 启动诊断写入 `backend.log`。核心没有独立进程：显式 `stop()` 调用 Rust 的 `shutdown` 释放运行时，不存在子进程退出或终止信号逻辑。

### ⚠️ SELinux 关键限制（历史记录）

| 执行方式 | 结果 |
|---|---|
| Flutter `Process.start`（untrusted_app 域） | ❌ `Permission denied` |
| `adb shell run-as <pkg> ./<binary>`（shell 域） | ✅ 可执行 |

**Android 的 `untrusted_app` SELinux 域禁止执行 `app_data_file` 下的二进制**，
这条实测结论今天仍然成立，也是本项目始终不发布独立后端可执行文件的原因
（`Process.start` 会 `Permission denied`）。
因此核心始终采用「共享库 + 进程内加载」的形态：`libfqapi_core.so`
随 APK 打包，Flutter 通过 flutter_rust_bridge 的 FFI 调用。

安装 NDK（例如 `sdkmanager "ndk;28.2.13676358"`）后运行 Rust 构建脚本：

```powershell
.\scripts\build_rust_backend.ps1
```

Rust 核心会使用配置文件推导运行目录，静态页面、过滤器和 `src/` 均按绝对路径加载；
loopback HTTP 适配器只绑定 `127.0.0.1`，`/health`、`/api/*`、`/src/*` 与 Web 入口共用同一分发器。
加密播放所需的 `libshortplay_crypto.so` 由 APK 构建自动从 `native/` 生成。

---

## API 对接说明

App 主要通过 `ApiClient` 调用后端 **`/api/*` 桥接层**（Rust 核心 `rust/src/endpoints/webui.rs`），首页推荐使用
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

**小说插图**：`ApiClient.chapterContent` 优先读取 v1 图文接口，失败时回退原纯文字正文。完整插图支持由 Rust 核心 `rust/src/endpoints/base.rs` 的解密实现提供，改动后运行 `scripts/build_rust_backend.ps1` 重建 `libfqapi_core.so`；上游的 `c=1` 是加密标志，密文来自 JSON `data.content`。核心没有解密成功标记时，客户端回退文字。该行为由 `rust/testdata/` 的离线黄金向量夹具保证一致。批量缓存保留已有插图并同步阅读器内存，纯文字回退会明确提示插图未更新。

**搜索分类与分页**：搜索页使用 `/api/v1/search` 请求所选分类，在拆分漫剧之前先选取对应的上游 tab，
再按条目实际 `kind` 筛选。综合保留全部作品；短剧、漫剧、漫画、听书分别只展示 `video`、`manju`、`manga`、`audio`。
每个分类独立保存结果、错误和 `next_offset`，空页或重复页有前进游标时可继续加载，失败重试保留原偏移量。
旧桥接的 `normalizeSearchTabs` 会将综合结果复制到空分类，且按页码换算偏移量，因此搜索页直接使用 v1 接口。

**漫剧与漫画参数不同**：首页的漫剧为 `24`、看剧为 `8`、漫画为 `9`；搜索的视频为 `11`、漫画为 `8`、听书为 `2`。
当前漫剧搜索复用视频 tab，漫剧详情和目录继续使用桥接参数 `tab=短剧`，目录对应 `/api/v1/manga/videos/{series_id}`。
漫剧首页未提供下一页游标时直接转搜索，不能把 `bottom_unlimited=true` 当作可递增的推荐游标。

---

## 数据模型

### `MediaItem`（归一化条目）

`MediaItem.fromRaw()` 兼容番茄 API 的各种字段形状：

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

短剧和漫剧上游的 `data.episodes`、`item_data_list` 和 `lists` 也会统一转换为同一模型，客户端因此可以兼容新旧响应结构。

### `SearchTab`（搜索 tab）

`title` + `items[]`，支持嵌套 `video_data`、`book_data` 展开，并保留可选 `hasMore` / `nextOffset`。
漫剧根据 `genre=205` 或明确的类型标签识别，标题、简介和作者提到“漫剧”不会改变作品类型。

---

## 页面说明

### 首页（`home_page.dart`）
- 提供推荐、小说、短剧、漫剧、漫画和听书分类；推荐页混排各类内容
- 优先调用真实 `/api/v1/recommend/homepage`，推荐接口不可用时回退搜索结果
- 推荐页的漫剧与小说都取各自的专属推荐流（`tab_type=24` / `2`），短剧、漫画、听书取搜索结果；
  漫剧的推荐流没有翻页游标，后续页仍由漫剧搜索承接
- 漫剧首屏使用专属推荐，后续按视频搜索的实际游标加载；筛选后空页或重复页仍可继续，来源耗尽后停止请求
- 封面左上角显示上游角标（`上新`／`爆款`／`热门`），文字与渐变配色均取自上游，支持明暗两套；
  仅带配色的标签作为角标渲染，无配色的类型标签由卡片自身的类型徽章承担。
  实测上游只在漫剧推荐流上放角标（12 项中 10 项），推荐页因此以漫剧流为主力
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
- 输入时显示联想词（250ms 防抖，保留上游的 `<em>` 高亮），点选即搜索；清空输入或执行搜索后自动收起
- 空查询时显示热搜词，点击即搜索

### 作者主页（`author_page.dart`）
- 从详情页作者行进入（整行可点，尾部「主页 >」）
- 头像、昵称、作家等级徽章（如 `作家Lv.5`）、粉丝数（如 `2.1万粉丝`）、简介
- 「全部作品」网格：封面、标题、`分类 · 完结状态 · 字数`，点击进入详情页
- 作品来自 `author_info.author_book_info`；`/authors/{id}/bookshelf` 是**分类书单**（30 条里 30 个不同作者），不用于作者页
- 加载失败可重试

### 排行榜（`rank_page.dart`）
- 从首页 hero 的奖杯按钮进入
- 榜单：推荐榜 / 完本榜 / 巅峰榜 / 新书榜 / 漫剧榜 / 短剧榜（`rank_algo` → `algo_type`）
- 分类：全部 / 穿越 / 系统 / 都市…（`info_id` → `rank_sub_info_id`）
- 条目含名次、封面、标题、`作者 · 分类 · 状态` 与简介摘要，前三名名次用主题色
- 触底自动翻页，续页名次连续（第二页从 31 开始）
- 榜单目录与真实 `rank_id` 取自首页榜单卡片的 `rank_with_category_data` 与 `cell_id_str`；`rank_id` 不可用占位值（占位时静默返回 0 本）

### 详情（`detail_page.dart`）
- 左上封面（3:4）+ 右侧标题、`分类 · 完结状态 · 字数`、「番茄原创」徽章，标题始终完整换行不截断
- 作者行：头像、笔名、等级徽章（上游 `user_title_infos` 的「作家Lv.5」）与关注按钮
- 数据三栏：榜单、正在阅读人数、评分（含五星），按可用字段自适应列数
- 作品 ID 行：显示当前加载所用的 ID（短剧／漫剧为系列 ID），可选中并一键复制；
  复制出的值可直接粘贴到搜索框以 `id:作品ID` 重新打开同一作品
- 演员表：短剧／漫剧显示横向演员卡片（头像、姓名、饰演角色）。数据来自 `/api/v1/series/{id}`；
  该接口失败或没有演员时不显示该区块，不影响播放。头像上游为 HEIC，解码失败时降级为姓名首字
- 书籍简介三行折叠可展开，题材标签，`查看目录` 行与 3 章目录预览
- 目录预览每章附正文开头数行（一次请求覆盖 3 章）；上游字段名虽为 `summary`，实际内容是正文开头，故按试读呈现
- 书评区：评分卡 + 评论列表（0-10 分转五星、相对时间、在读时长、点赞与回复数）
- 书评的「回复 N」可展开回复（点击时懒加载，失败只在该条下提示，不影响列表）
- 作者行整行可点进入作者主页（核心无关注端点，因此不提供假的关注按钮）
- 底部：听书 / 下载 / 阅读（播放、续看）三键；听书与下载仅小说显示
- 听书直接进入听书页并接续已保存的进度；下载一次点击即缓存整本（从续读位置起，进度显示在底栏，缓存中再点一次停止）。下载的章节不受缓存上限约束，也不会被自动清理
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
- 正文段落末行内联段评气泡：**凡有段评的段落都显示**（与官方默认一致），气泡为空心圈、圈内为段评数，
  尺寸/描边/间距按官方规格，颜色跟随阅读主题；计数超过 99 显示 `99+`；
  点击直接打开该段的段评面板。分页与滚动两种模式都生效，字号与无段评段落均已覆盖
- 章节 ID、图文位置和封面写入历史，换字号、横竖屏或阅读方式后按原位置续读；兼容旧文字偏移和滚动历史
- 章节正文解析上游 `<p idx>` 段落 ID，随结构化缓存持久化；旧缓存没有该字段时只影响段评
- 段评面板按官方版式：只展示**所点那一段**的评论列表（头像、昵称、时间、正文、赞/回复数），
  顶部为段落选择条（仅当本章有多段时）、`全部/最新` 筛选（客户端排序）、段落引文，面板高 90%；
  底部发布栏未做——核心无写接口，不做点了没反应的控件
- 段落评论正文由 `server_channel=39` 拉取（**不是**官方 presenter 里的 43；43 会被接受但恒返回空），
  面板展示该段真实段评：头像、昵称、时间、正文、赞/回复数、作者徽章，以及「读 N 分钟」；
  实测第 0 段 287 条、第 32 段 6 条，计数与段评气泡逐段一致
- 段评需要章节版本：`Chapter.version` 取自目录 `item_data_list[i].version` 并随缓存持久化；
  旧缓存恢复为空串，只影响那一章的段评（显示空态而非报错）
- 本章没有段评时，控制栏入口隐藏
- 正文和目录自动保存到磁盘，底部“缓存”可下载后续 20/50/100 章并随时停止；旧文字缓存立即可读，联网后自动补图并迁移阅读位置
- 章节缓存保存图片地址和尺寸；插图文件首次显示时联网加载并自动缓存。过期签名在打开章节或恢复前台时刷新，离线时保留已有图文
- 自动缓存上限为 500 章或 80 MB，超出后清理较久未读的章节；「下载」的章节在这个预算之外，会一直保留到你手动删除

### 播放器（`player_page.dart`）
- 短剧与漫剧共享播放器；漫剧保留独立历史类型，并兼容以前按短剧保存的系列和播放位置
- 原生 Media3 播放器播放后端返回的流地址（客户端自动补全 URL）
- 自动连播（播完自动下一集）
- 控制栏三秒后自动隐藏；单击显示或隐藏，双击播放或暂停
- 支持搜索选集、上下集、快进快退 10 秒和全屏
- 全屏方向按视频比例决定：横屏剧集横屏、竖屏剧集竖屏；**新一集加载前尺寸未知时不改动方向**，
  因此横屏连播不会被掰回竖屏；尺寸到达后自动应用正确方向
- 锁定后方向不再变化（连播也不改），解锁时才按视频比例调整
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
- 后台播放：听书支持后台 keepalive（用户可在设置中开关）与通知栏媒体控制；
  断开耳机或蓝牙（becoming noisy）时自动暂停

> **听书页的「书评」与章评**：官方听书页的操作项是「章评」（章末讨论），但章评属于
> 章节而不是正在收听的书；该面板展示的是整本书评，所以按实际内容标注为「书评」。
> 章评与段评已由后端提供：`/api/v1/chapters/{id}/reviews` 走 item-ideas 服务，
> 返回按段号索引的数量与评论 ID；正文需要再用评论列表端点按段落懒加载。

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

- Rust 核心随 APK 打包并在进程内加载。先运行 `scripts/build_rust_backend.ps1`（或 `bash scripts/build_rust_backend.sh`）生成 `libfqapi_core.so`；黄金向量夹具随 `rust/testdata/` 分发，不参与构建。
- 加密播放使用 `native/` 中的 C 源码，Gradle/CMake 自动生成 `libshortplay_crypto.so`。
- 生成 Rust 核心后构建 arm64 APK，再用设备验证 `/health`、搜索、阅读和加密视频播放。Android 的纯 JVM 测试不会加载这两份库。

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

- [x] **Rust 原生核心**：`fqapi_core` → `libfqapi_core.so` → flutter_rust_bridge 进程内调用（替代 Go/Kotlin JNI）
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
- [x] 发现类入口：搜索联想词与热搜、作者主页、排行榜、书评回复、章节试读预览
- [x] Release 签名配置与 R8 混淆
- [x] 整本 TXT 导出（离线缓存页每行「导出 TXT」→ 系统「下载」；重取最新目录与每章正文，按后端 `/api/download` 同形组装）
