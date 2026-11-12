# novel-sound 开发者文档

面向构建、修改和调试本项目的开发者。用户使用说明见 [README.md](README.md)。

> **核心设计**：Rust 原生核心在 Flutter 进程内运行，UI 通过 flutter_rust_bridge 直接调用；同一分发器另开 loopback HTTP 适配器（`127.0.0.1:18921`），把 `/api/v1/*` 只读路由和 `/src/*` 漫画图开放给外部阅读软件（如 Legado 书源）和本机工具。不需要自建服务器，不需要 root；签名、解密和本地缓存由手机完成，但在线内容仍需访问上游。

---

## 目录

- [架构总览](#架构总览)
- [项目结构](#项目结构)
- [注释与公开依据](#注释与公开依据)
- [构建环境](#构建环境)
- [构建 APK](#构建-apk)
- [测试](#测试)
- [Android 原生核心集成](#android-原生核心集成)
- [本机密钥库（SecureKeyStorage）](#本机密钥库securekeystorage)
- [API 对接说明](#api-对接说明)
- [数据模型](#数据模型)
- [页面说明](#页面说明)
- [已知问题与调试](#已知问题与调试)
- [开发计划](#开发计划)

---

## 架构总览

### 番茄书架原始采集与历史导入

设置 → 数据 → 备份与导入提供本机备份/恢复入口，并集中进入“导入番茄书架”。网页登录、最近采集与旧版历史 JSON 共用导入预览和本机书架/历史合并流程。原始响应、分卷导出与补取资料放在折叠详情中。

Android WebView 由用户本人完成官方手机号登录和人机验证。Cookie 保存在本应用私有 WebView 存储中，关闭窗口时 flush，只有显式“退出网页登录”才清除 Cookie 与网页存储；上游仍可使会话过期。交给 Rust 的会话副本只在内存和 `ApiClient._get` 的 POST 请求体中使用，不写进采集或备份。原生登录界面跟随应用主题，仅点击发送/获取验证码或重新发送按钮后尝试一次缩放适配；输入框获得焦点时取消尚未执行的自动适配，验证容器和键盘布局变化不触发缩放，提供手动“适应全页”和双指缩放；只读取按钮文字与布局尺寸，不读取输入框、验证答案或跨域 iframe 内容。

固定白名单覆盖历史、书架、进度、文件夹、置顶与标签，仍只调用已确认的读取接口。采集保留响应 JSON 原始字段并移除凭证，结果分卷存入 Android 私有目录 `files/fanqie-library-captures/`。清单 `fqapp.fanqie-library-capture` v2 的 `sources` 为索引，`parts` 为原始分卷；支持读取最近一次、续取公开详情和系统选择器导出 ZIP，兼容 v1 单文件。采集本身不写入书架，解析预览后才合并。

小说按章节 ID 对照目录恢复续读位置，保留较新的本机进度；未确认的段内偏移不转换为本地文字偏移。采集数量不等于书籍数量或全部云端数据；失败、取消、分页未完成和目录暂不可用均分别保留。协议证据与私人采集放在本地 `.agents/research/fanqie-history-20261018/`，不随源码分发。

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
      127.0.0.1:18921 │             ▼
                     ▼      上游 API
          外部客户端 / /src/* 漫画图
```

### 数据流

1. **启动**：`main.dart` → `BackendService.start()` 将配置、过滤器部署到 app 私有目录 → 通过 flutter_rust_bridge 在进程内初始化 Rust 核心（`libfqapi_core.so`）→ 轮询 `/health` 直到 200。核心没有独立进程，也不再有 Kotlin/JNI 桥或桌面可执行文件。
2. **请求**：UI 页面 → `ApiClient` → `BackendTransport`（默认 `RustBackendTransport`，经 flutter_rust_bridge 直调 Rust 分发器；Web/测试用 loopback HTTP）→ 同一 Rust 分发器完成签名（Argus551）、设备池管理、请求上游、解密内容 → 返回归一化 JSON。
3. **存储**：历史和阅读时长走 `LibraryStore`（Hive）。

### 小说离线缓存

`ChapterCacheStore` 把书籍目录与章节正文拆成两个加密 Hive 箱。书架和离线缓存列表只读较小的目录箱，正文箱只在阅读器实际读取章节时打开，避免冷启动扫描数百 MB 正文导致界面无响应。

- 正文保留在 `chapter_cache_v1_enc`；正常的书架/离线列表查询不打开正文箱。
- `chapter_cache_catalog_v1_enc` 保存 `book:<bookId>` 目录、缓存章节 ID、章节数、字节数、访问时间和下载标记；列表与容量统计不再扫描正文箱。
- 自动淘汰在正文箱已经打开时执行，并按目录中的访问时间和下载标记选择最久未读的未下载章节。
- 首次升级会从旧版合并箱迁移目录和索引；迁移使用 `LazyBox` 逐条读取，正文值不会同时驻留内存，完成后关闭旧箱。

---

## 项目结构

```
novel-sound/
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
├── assets/                          # 配置示例、过滤器、图片和动画
├── test/                            # Flutter 测试及 Node 主机回归
├── scripts/                         # 构建、验证和资源生成；见 scripts/README.md
├── .github/workflows/               # Android APK 与原生库 CI
├── flutter_rust_bridge.yaml         # FRB 代码生成配置
└── pubspec.yaml                     # Flutter 版本、依赖与资源声明
```

> **仓库不含原生二进制**：`libfqapi_core.so` 和 `libshortplay_crypto.so` 均被 Git 忽略。
> 前者可由 `rust/` 中的 Rust 源码经 `scripts/build_rust_backend.*` 重建；
> `libshortplay_crypto.so` 由本仓库 `native/` 中的 C 源码在 Android 构建时自动生成。
> Android 构建前需先运行 Rust 构建脚本生成两个 ABI 的核心库。
>
> 体积参考：Rust `libfqapi_core.so`（arm64-v8a）为 6,125,392 字节（约 5.84 MiB）。这是本地 release
> 构建产物的实测大小，不是安装包体积，也不是性能结论。

## 注释与公开依据

- 历史注释中的 `.agents/notes/...` 是维护者本地笔记，被 `.gitignore` 有意排除，不随源码分发；不是缺失的构建依赖，也不要求贡献者补齐这些文件。`docs/` 同样是本地资料目录，不能作为公开依据的唯一落点。
- 新增或修改注释时，关键业务理由、边界条件和结论应在注释正文中用一两句话说明，不再新增只指向本地笔记的依据。需要展开时，链接仓库内已跟踪的文档、公开 issue/PR 或提交；私人日志、设备信息和取证材料不直接入库。
- 现有引用暂不批量改写；维护相关代码时补齐自足说明，不把无关的注释清理混入功能改动。历史“为守住行数预算而拆分”等说明不代表当前规则：`scripts/check_line_budget.sh` 只报告体量，拆分应基于职责和可读性，不设固定行数门禁（#253）。

### Wenku8 界面移植边界

移植源固定为 `mikufoxxx/Wenku8_Flutter` 的
`ebcd7f1891b54a92fc045c372974d70ec829f10a`（2026-11-03）公开源码。
不是依据截图另做一套相似风格，也不导入它的账号、网络、云同步或阅读引擎。
原始声明与两份 GPL 文本保留在 `assets/licenses/wenku8/`，应用“关于 →
开源许可”可查看；具体适配边界见同目录 `PORTING.md`。

第一批范围：

- `lib/widgets/wenku/`：提取上游档案图标、有限入场动画、玻璃搜索框、固定页头和入口卡片；只在已移植页面启用上游主题，不改全局首页配色。
- `third_party/liquid_glass_easy/`：保留上游使用的 5.0.0 本地补丁版本、shader、MIT LICENSE 与 PATCHES.md，不用普通模糊底板冒充折射。
- 底部导航：主壳层使用上游 `GlassDock`（`lib/widgets/shell_dock.dart`），保留首页／短剧／书架／我的四个入口；短剧视频流与 OLED 纯黑下用上游轻量模式的静态底板，不对逐帧变化的画面做实时折射。
- 搜索：把上游主壳层内的搜索视图适配为 fqapp 独立路由（`SearchRoute` 沿用上游 420ms 斜切平面入场），保留来源、内容分类、ID 查询、评分筛选、历史和分页。页头、分段页签、列表／网格、骨架、空态与流尾使用上游组件；书旗作为分段控件的最后一段。
- 我的：使用上游 `MyPage` 的身份卡与功能入口结构。身份卡只描述本地应用，不提供文库登录／同步。现有统计另开路由，统计内容本身尚未移植。

后续独立批次仍包括完整发现页、详情、书架、本地缓存对应页、设置、
统计及阅读器菜单。当前首页保留原分支基线，不计作已核对完成的 Wenku8 移植。
短剧、漫画等 fqapp 专有功能没有上游一一对应页面，需单独适配，不能计入原版页面完成率。
上游公开快照缺少部分被引用模块（例如本地批量导入、自定义 TTS、报告页），
不能独立构建；没有公开实现的部分不虚构为“已移植”。

构建前执行 `flutter pub get` 同步本地 path 包与锁文件；shader 由该包自己的
`pubspec.yaml` 声明，不需要另行下载。界面验证使用重新构建的 release APK，
不能拿上一批设备上的安装包验证当前源码。既有测试保持冻结；不把静态检查
或历史测试结果当成界面一致性的证据。

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
| Visual Studio | 2022（「使用 C++ 的桌面开发」工作负载） | 仅构建 Windows 桌面端（可选） |

> Windows 下构建注意：Kotlin 增量编译在部分环境会报 `Could not close incremental caches`，已在 `android/gradle.properties` 中关闭（`kotlin.incremental=false`）。

> **桌面插件与「开发人员模式」**：仓库已包含 Windows 桌面端插件，`flutter pub get` / `flutter test` /
> `flutter run` 需要系统开启「开发人员模式」（插件通过符号链接注册），否则报
> `Building with plugins requires symlink support`。只跑 `dart pub get` 或 `flutter analyze` 不受影响；
> 不打算本地跑测试时，用 GitHub Actions 的 CI 即可。桌面端构建与验证见 [WINDOWS.md](WINDOWS.md)。

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
cd novel-sound
flutter pub get
# 演示只出 arm64 调试包；正式出包是双 ABI 分包，见下方说明
flutter build apk --debug --target-platform android-arm64
flutter build apk --release --target-platform android-arm64
```

镜像环境（`PUB_HOSTED_URL` 指向 pub.flutter-io.cn 等）下，上面每条命令都会隐式执行 `pub get`
并把 `pubspec.lock` 的全部 `url:` 改写成镜像地址；本地 Flutter 版本与生成该锁的版本不一致时，
还会顺带移动几十个包的版本。提交前核对 `git diff pubspec.lock`，必要时 `git checkout -- pubspec.lock`。

Rust 核心按 `arm64-v8a` 与 `armeabi-v7a` 两个 ABI 产出（`scripts/build_rust_backend.sh` /
`.ps1` 的 `aarch64-linux-android` + `armv7-linux-androideabi`），CI 因此用
`--target-platform android-arm,android-arm64 --split-per-abi` 出两个分包；x86/x86_64 设备不提供。

> **release 构建不要加 `--no-pub`**：`integration_test` 在 `dev_dependencies` 里，`flutter test` 会把
> 它写进 Android 插件注册表；随后用 `--no-pub` 构建 release，Gradle 会报
> `package dev.flutter.plugins.integration_test does not exist`。先跑测试再构建时保留 pub 步骤即可
> （CI 正是这样构建的）。

### GitHub Actions 云端编译

打开 [Actions → Android APK](https://github.com/ch6vip/novel-sound/actions/workflows/android-apk.yml)，
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

Android 安装与功能验证默认使用 MuMu，连接和启动命令见[MuMu 模拟器功能验证](#mumu-模拟器功能验证)。实体手机仅在用户明确要求时安装，界面操作由用户完成。

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

## 测试

### WebDAV 自动同步

「备份与导入 → WebDAV 同步」填写 HTTPS WebDAV 目录（缺失目录自动创建）、用户名与
应用专用密码，保存后启用自动同步。各设备使用同一目录；应用在其中维护
`fqapp-sync.json`。凭证保存在设备安全存储中，不进入备份或同步文件。

启动、返回应用和书架/进度变化后会同步，前台每两分钟也会检查云端；离线失败
不影响本机阅读，后续自动重试。系统终止或挂起应用期间不保证执行同步。
云端文件存在时，强制覆盖本机在线书架、阅读进度和已看剧集，包括移除本机独有的
在线收藏、替换较新的本机进度。本机新增收藏和进度不会自动回写已有云端文件。
删除已同步的收藏、历史或已看记录则会持久保存待同步删除，并通过条件写入传播到云端；
离线失败或进程重启后继续重试。空白新设备不推断删除。已有云端文件消失时停止自动重建。只有云端
文件不存在时，才使用本机快照建立初始备份；创建竞争失败则重新读取并以云端为准。
AI 资产仍使用便携备份恢复的合并规则。
本地 TXT/EPUB、缓存和外观设置不参与同步。云端文件含阅读数据，应使用私人目录。

同步应用阶段只修改仍与请求前快照一致的书架、历史和已看记录；期间的本机删除
保留并在同一轮的下一次条件写入中补传。历史删除与已看删除分别按各自身份处理，
删除同 ID 的小说历史不会连带删除视频已看记录。切换配置会等待旧任务退出后
立即启用新目标，每个异步应用边界重新检查配置代次。

当前小说与视频/漫剧仍沿用旧版裸 ID 存储。云端若同时包含会映射到同一个本机键的
不同类型历史，同步会在任何远程删除或本机覆盖前明确拒绝，保留双方原数据；
不将“安全拒绝”称为已支持跨类型同 ID 恢复，也不在本 PR 扩大迁移历史/统计契约。

服务器需支持强 ETag 和 `If-Match` / `If-None-Match` 条件写入；并发冲突会重新
读取并以云端为准，最多尝试三次。重定向不会携带认证信息自动跟随，请填写最终目录。
HTTP 明文连接不受支持。同步格式验证和大小限制沿用便携备份的字段白名单。

```bash
flutter test --no-pub test/webdav_sync_test.dart test/webdav_sync_page_test.dart
```

#### 2026-11-10 PR #300 后续修复与验证

- `library_shelf_groups_test.dart` 的本地删除用例只把固定 50 ms 等待改为分类仓库
  提交事件，原断言与超时不变，没有新用例或跳过项。VM 在书架删除后、分类清理前
  暂停可以重现旧断言提前执行；新等待在额外暂停 1200 ms 后仍等到真实提交。
- 在 Flutter 主机进程中通过 VM 调试调用生产 `WebDavClient` / `WebDavSyncService`，
  连接仅监听 `127.0.0.1` 的临时 HTTPS WebDAV 服务，使用临时凭证和构造数据，
  没有访问用户云盘。记录了真实 GET 200、带 ETag 的 PUT 204 和 MKCOL 201。
- 删除 `book:shared-id` 后，服务端与本机仍保留 `watched[shared-id].episodeA=123`；
  在应用云端前暂停并提交书架/历史删除，恢复后两端均无被删除条目；切换配置时
  暂停旧 GET，释放后 0.4 秒内新目录收到 GET，无需等待两分钟轮询。
- 云端同时包含 `book:clash` / `video:clash` 时明确拒绝，未发 PUT、原云端两项
  仍在。安全拒绝不是跨类型同 ID 恢复能力。含空格、中文和 `%` 的目录实际逐级
  MKCOL/PUT 成功；Dart 3.13.7 的 `Uri.replace(path:)` 保留有效百分号编码，未复现
  审核中的二次编码猜测，因此没有改写该客户端路径逻辑。
- 五个直接改动 Dart 文件静态分析无诊断；四个既有 WebDAV/书架文件共 69 项完成。
  一次并行构建下的完整 Dart 运行出现主机内存不足、套件连接断开和 pending timer，
  已停止，不能报告为完整门禁通过；保留原 CI 检查，不延长超时或跳过失败。
- MuMu 6.8.8.0、Android 12、实例 0、`127.0.0.1:16385` 覆盖安装正式签名
  arm64 release `1.0.201+206`，最终 APK SHA-256 为
  `bbfb439fa8c4aadd62e3fcf16f29d11a6e11bdf8f59c4e2103ca6db28e00e126`。
  冷启动、备份与导入 → WebDAV 同步、空地址拒绝保存均实际操作；页面使用现有
  `featurePadding` 后，正文不再被悬浮标题栏遮挡。番茄账号读取/登录管理入口仍在。
  升级前后导出书架 0、历史 3、已看 0，逐字段相同；AI 解压后仅导出时间变化。
- 首次 `pub get` 在 Windows 符号链接阶段中断，缺失的 Android 插件注册文件曾让
  本机调试/profile/release 包在 JNI 初始化时崩溃。重新完整生成插件注册并以
  `flutter build apk --release --target-platform android-arm64 --split-per-abi`
  构建后启动正常；这些生成物不提交，也未为此修改生产 JNI 代码。主机的真实
  HTTPS 同步调用不等于 Android/Windows 多设备云盘验收；后者仍未执行。

阅读器「背景」新增“雾蓝”（`#D8E4F0`）；选择会随本机阅读设置保存，不改变全局主题。

代码规模仅作为审查参考：不设置固定的文件/函数行数上限，不维护“只准缩不准涨”的预算。是否拆分取决于职责、复杂度与可读性，不为凑行数机械拆分。`bash scripts/check_line_budget.sh` 只输出源码体量信息，不因文件过长而失败；CI 中该步骤也不阻塞构建。静态分析、构建及功能验证不因此放宽。

### MuMu 模拟器功能验证

按用户于 2026-11-04 确认的约定，后续 Android 功能验证默认由代理在 **MuMu 模拟器**中执行：安装 release APK、启动应用、点击/滑动、查看界面和日志，以真实用户路径记录结果，不将构建成功或自动化测试通过等同于功能成立。

本机已验证环境为 MuMu `6.8.8.0`、Android 12、实例 `0`；当时 ADB 地址为 `127.0.0.1:16384`。以下路径是本机配置，端口不是固定约定，每次连接都先查询实际实例信息：

```powershell
$manager = 'E:\Program Files\Netease\MuMu\nx_main\MuMuManager.exe'
$adb = 'C:\android-sdk\platform-tools\adb.exe'
& $manager info -v all
& $adb devices -l
```

从目标 MuMu 实例的 `adb_host_ip` 和 `adb_port` 确定 `$serial`；确认它属于模拟器后再执行设备操作，不盲用 `7555`、`16384` 或默认设备：

```powershell
$serial = '127.0.0.1:16384' # 仅为已验证示例，必须按本次 info 输出填写
& $adb connect $serial
& $adb -s $serial install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
& $adb -s $serial shell am start -W -n com.fqapp.fqapp/.MainActivity
```

- 默认使用本地 release 构建；本机 MuMu 主 ABI 为 `x86_64`，已验证可通过 ARM 转译运行上述 arm64 APK。其他实例先确认 ABI 与转译支持，不把这一结果推广到所有模拟器或真机。
- 所有针对设备的 ADB 命令显式指定 `-s $serial`；不要用 `adb kill-server` 干扰其他设备连接。实体手机仅按明确要求安装，不由代理启动或操控；MuMu 不可用时说明阻塞，不自动切换到手机。
- 保留应用数据，不擅自卸载或清空；验证结束后还原临时设置，对比旧包后恢复当前待交付包。截图、UI 导出和日志存放于仓库外的临时目录，不提交用户数据。
- 记录模拟器版本、实例/序列号、APK 版本或哈希、实际操作和观察结果，明确未验证项。MuMu 不替代真机性能、硬件解码、16 KiB 页大小设备等专项验证；用户已确认的构建不要求重复验收。
- 听书验证先检查系统 TTS 服务与媒体静音状态：`& $adb -s $serial shell cmd package query-services --brief -a android.intent.action.TTS_SERVICE`、`& $adb -s $serial shell dumpsys audio`。本机在 2026-11-04 检查时没有 TTS 服务且媒体流静音；这是环境限制，不等同于应用初始化或解码缺陷，也不能仅凭进度推进声称已验证实际听感。

官方参考：[ADB 连接说明](https://mumu.163.com/help/20240807/40912_1073151.html)、[MuMuManager 命令行说明](https://mumu.163.com/help/20240726/35047_1170006.html)。

**本地 Flutter 工具链一致性**：`pubspec.lock` 与 CI（`FLUTTER_VERSION: '3.47.9'`）已升到 3.47.9，`.dart_tool/package_config.json` 也指向 `E:\ctf-aaa\.toolchains\flutter-3.47.9`；PATH 上的 `C:\Users\ch6vip\flutter\bin` 仍是 3.44.6 / Dart 3.12.2。混用会让 `flutter test` 报 `petitparser` 语言版本 3.13 过高及 `ui.HitTest*` 类型缺失；切到 3.47.9 后若出现 `Invalid kernel binary format version (expected 138, found 130)`，是 `.dart_tool/hooks_runner` 里旧 SDK 编译的 `hook.dill`，删除该生成目录即可，不必改动源码。

会话级临时指定（不修改全局 PATH）：

```powershell
$env:PATH = 'E:\ctf-aaa\.toolchains\flutter-3.47.9\flutter\bin;' + $env:PATH
Remove-Item -Recurse -Force .dart_tool\hooks_runner  # 仅在出现 kernel 版本冲突时
flutter analyze --no-pub
bash scripts/test_quick.sh home
```

构建 MuMu 验证包用 `flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub`；不带 `--split-per-abi` 的 fat APK 的 versionCode 低于已装包，安装会报 `INSTALL_FAILED_VERSION_DOWNGRADE`。

#### 2026-11-04 听书复核

在上述实例安装 `1.0.200` arm64 release 包，安装后核对 APK SHA-256 为 `ab40ff2a2bfac46e1863ae78311f003f140fd0442915a720ae20e6f765f89bd7`。以下是该包的实际界面操作和 Android 媒体会话观察，不是自动化测试结论：

| 路径 | 实际结果 | 限制 |
|---|---|---|
| 系统朗读 | 阅读页直接起播、从智能朗读切入均显示“未找到朗读引擎，请安装或重新选择系统 TTS 引擎”；收起再展开菜单未重复提示 | 系统查询没有 TTS 服务，不能验证成功发声、暂停恢复及连续朗读 |
| 智能朗读 | 起播、暂停、恢复、下一章、离开阅读页继续播放、退出再打开听书页保留暂停位置均已观察 | 媒体流静音，只确认进度、字幕和活动解码音轨，不代表听感通过 |
| 真人讲书 | 起播、暂停、恢复、前后章节切换、退出再打开听书页保留暂停位置均已观察 | 本次作品显示“暂无原著章节映射”，未把它当作已确定的客户端缺陷；实际听感未验证 |

暂停观察中，智能朗读位置连续两次为 `12746 ms`，恢复后为 `17504 ms`；真人讲书连续两次为 `90154 ms`，恢复后为 `92116 ms`。两次暂停采样间隔至少 4 秒。截图、媒体会话和日志保留在本机仓库外的 `%TEMP%\fqapp-mumu-audio-iu72nwm9`。

结束时恢复原默认“系统朗读”和第 1 章首页，关闭全部播放并返回首页；媒体静音及音量配置与验证前一致。未卸载、清空数据或安装额外 TTS 引擎。

本次仅修复阅读页借用胶囊时漏报播放错误，不改变播放引擎、起播返回值或应用版本。下一步优先补齐系统 TTS 引擎和可听输出环境，再验证成功朗读与实际音频输出；不要用依赖升级或自动切换引擎掩盖环境缺失，也暂不扩展新听书功能。

#### 2026-11-04 阅读导航栏开关（#258）

同一 MuMu 实例安装 `1.0.200` arm64 release 包，安装后核对 APK SHA-256 为 `d58596add72fbb46368fea490d6cc8d029a6014760c31b03b27a258c99a81fa9`。实际通过阅读设置切换状态栏与导航栏，关闭设置面板后从 Android `dumpsys window -a windows` 检查应用窗口的 `Requested visibilities`；两项可独立请求显示/隐藏。退出阅读后恢复原窗口状态，退到桌面再返回会重新应用阅读偏好；关闭应用进程后重新进入，导航栏开启状态仍保留。

本机 `qemu.hw.mainkeys=1`，窗口没有系统导航栏的 InsetsSource，因此上述记录只证明设置保存及原生窗口显隐请求，不证明小白条已实际显示、内容避让或一次上滑即可回桌面。这些交互在本实例仍未验证；未改模拟器系统属性、导航模式或系统镜像来制造通过结果。截图、窗口状态与报告位于仓库外 `%TEMP%\fqapp-mumu-nav-jb1dhjos`。

验证结束恢复“系统状态栏”开启、“底部导航栏”关闭和第 1 章首页，返回应用首页，保留安装的新包与原应用数据；本次未继续听书验证。

#### 2026-11-05 首页档案化改版复核

同一 MuMu 实例（本次 `MuMuManager info -v all` 查得实例 `0` / Android 12 / `127.0.0.1:16384`）安装当前分支重建的 arm64 release 包：Flutter 3.47.9 / Dart 3.13.7、`--split-per-abi`、versionName `1.0.200` / versionCode `2205`，APK SHA-256 为 `e719dad17865afe76a8f46ab9208308d08af0938a24fb15d446f46f52e60da5a`，安装后设备侧 hash 一致。旧包 `ee9409e3…`（11-04 18:21 构建，对应 `e615e2b`）留作界面对照基线。以下是实际界面操作、语义树与 logcat 观察，不是自动化测试结论：

| 路径 | 实际结果 | 限制 |
|---|---|---|
| 冷启动 | `am start -W` TotalTime 约 9.0s，`fqapi_core: core init: port=18921`；启动后约 20s 内显示「正在启动本地服务…」，随后进入完整首页 | 后端服务就绪前的加载态属正常初始化 |
| 首页档案化 | 什锦铺 / SHIJINPU STORY ARCHIVE、01 / RANKING、排行榜、榜单胶囊、书脊阵列、信息行、翻页器、悬浮 dock 全部呈现，与旧包基线一致 | 仅在本实例分辨率与字体下观察 |
| 翻页器 | NO.001 → NO.002，第 2 本 / 共 16 本，书名、作者、在读人数与书脊焦点同步 | 未验证点击书脊画布的命中换算 |
| 切换榜单 | 「完本榜」选中并刷新为 30 本 / NO.001 / 19.2 万人在读 | 上游数据，不作内容正确性断言 |
| 切换顶部 tab | 「小说」下划线正确移动，内容区仍显示同一排行榜区块；切回「推荐」正常 | 各 tab 内容差异未验证 |
| 短屏 + 大字号 | 720x900 + `font_scale 1.3`：首屏信息行被压到 `[32,896][688,900]`，翻页器在首屏外；4 段小滚动后翻页器到 `y=552..624`（dock 上沿 754），点击成功翻到第 2 本 | 滚动中间态 `y=824..896` 时点击会命中 dock 的「我的」并跳转；功能可用，属首屏密度与中间态误触的体验取舍 |

短屏组合的「滚动后可命中」已固化为 `test/home_rank_shelf_geometry_test.dart` 的回归用例（`bfd63a2`）；未因此改动 `Scaffold(extendBody: true)`、悬浮 dock 或 `HomeRankShelf._geometryFor`。logcat 无 FATAL EXCEPTION、ANR 或应用崩溃。

本机 `x86_64` 主 ABI 经 ARM 转译运行 arm64 包；媒体流静音且无 TTS 服务，本轮未验证听书发声、物理设备性能、硬件解码、16 KiB 页设备，以及自动降级 flat 态。截图、UI dump 与 logcat 位于仓库外 `%TEMP%\fqapp-mumu-home-20261105`。

验证结束恢复 `wm size` 为 720x1280、`font_scale` 为未设置、首页「推荐榜」NO.001 / 共 16 本，保留安装的新包与原应用数据；未卸载、清空数据或改装调试包。

#### 2026-11-10 #300 公共 CI 修复记录

#300 run `42583363579` 的首页续读失败来自 `SecureKeyProvider -> EncryptedHive -> ReaderUnderlineStore` 遗留的 10 秒虚拟计时器；安全存储失败的 30 秒真实时间冷却到期后可以复现，随后划线单例队列还会阻塞下一用例。用户授权仅修正这份现有书架测试的环境：显式模拟安全存储不可用、逐项重置缓存，不初始化与书架导航无关的划线存储，退出恢复原状态。原导航断言保留，不新增用例、不修改生产超时或重试策略。在同源代码上整份 41 项诊断完成；VM 断点延迟到失败时间已过去 77 秒后，三个续读用例仍顺序完成。

同步 #301 的生产路径修复：本地书成功移出后先批量移除分类归属，再删除文件；普通非本地书仍保留分类。MuMu 实例 `0` / Android 12 / `127.0.0.1:16385` 已在公共修复包 `a9e68a0d9188d4eac6922914d733cc1e9c9a7121d80bfe185a31168ebfa3d49d` 验证导入 TXT、分配分类、移出、撤销恢复同一 ID 后显示未分类。结束书架 0、历史 3、已看 0，历史逐字段未变；临时书、分类与输入文件已清理。该包来自 #306，不包含本分支 AI 改动，不能作为本分支其他功能验收。

为避免新一轮 PR 合并检查引入主线启动超时，同步 `origin/master` 的 `16ee87b`，保留原 AI 改动并给新增振动通道加 2 秒失败降级；没有把本 PR 合并回主线、改工作流或增加依赖。本分支原 head 为 `9450d290d22f6e6820f2627b9db7c80705a44f15`；远端结果只认本次推送后的新 head。静态检查、诊断运行与已有公共 MuMu 验证分别记录，不以测试完成代替用户路径。证据保存在仓库外 `%TEMP%\fqapp-ci-repair-20261110`，不提交用户备份。

#### 2026-11-10 #301 公共 CI 修复记录

#301 run `42600437041` 的本地书分类残留对应删除顺序：旧路径等文件删除返回后才移除分类归属。成功移出书架后现改为先批量清理本地书归属，再逐本删除文件；归属失败记录日志且不阻止后续文件清理，非本地书移出仍保留分类。旧用例短等待在本机普通运行中未稳定复现，不以单次诊断运行推断因果。

MuMu 实例 `0` / Android 12 / `127.0.0.1:16385` 已在公共修复包 `a9e68a0d9188d4eac6922914d733cc1e9c9a7121d80bfe185a31168ebfa3d49d` 验证导入 TXT、分配分类、移出、撤销恢复同一 ID 后显示未分类。结束书架 0、历史 3、已看 0，历史逐字段未变；临时书、分类与输入文件已清理。该包来自 #306，不包含本分支 Rust 身份配置改动，不能作为本分支其他功能验收。

用户同时授权 #300 的定向测试隔离，故同步现有 `library_shelf_test.dart` 的环境修复：安全存储通道显式不可用并逐项重置，书架导航用例不初始化无关的划线存储，退出恢复原状态；不新增用例或更改生产安全存储策略。同源代码整份 41 项诊断完成，VM 断点等待超过 30 秒冷却后三个续读用例也能顺序完成。为避免新一轮合并检查引入启动超时，同步 `origin/master` 的 `16ee87b` 并给新增振动通道加 2 秒失败降级；保留 Rust 身份配置，不把本 PR 合并回主线、不改工作流或增加依赖。原 head 为 `696eca30e75fab1767fe48b4ec7686a6ce8fc777`，远程 CI 只认推送后新 head。证据保存在仓库外 `%TEMP%\fqapp-ci-repair-20261110`，不提交用户备份。

#### 2026-11-10 Android 振动反馈开关（#303）

基于 `c29b279`，在“设置 → 外观”增加默认开启的“振动反馈”；经典与档案主题共用 `haptics_enabled`，冷启动在交互页面挂载前读取。统一触感组件和书架/播放手势的直接调用都读取该偏好，Android 的 activity decor view 同时拦住 Flutter 控件自带的长按振动；不改系统振动或键盘设置。iOS 暂不显示此开关。

本次由 MuMuManager 查询得到实例 `0` / Android 12 / `127.0.0.1:16385`，720x1280、字体比例 1.0、x86_64 经 ARM 转译运行 arm64 release。Flutter 3.47.9 / Dart 3.13.7，应用版本保持 `1.0.201+206`（arm64 split versionCode `2206`）；安装后设备侧 APK SHA-256 与本地产物一致：`c7778e081a31757ba4909475450e0009db3b0bee30c114b47e3546958bdc1132`。

| 真实路径 | 观察结果 |
|---|---|
| 升级后进入档案主题的外观设置 | 开关默认开启，语义树 `checked=true`；按钮操作在 `dumpsys vibrator_manager` 中产生本应用的 `TEXTURE_TICK` 记录 |
| 关闭后返回、重新进入外观、打开/关闭主题模式菜单 | 开关显示关闭，操作前后本应用的振动记录完全一致，没有新增 |
| 关闭后强制停止进程并冷启动，再进入外观 | 语义树仍为 `checked=false`；启动及后续导航没有新增本应用振动记录 |
| 从档案切换为经典主题，再长按书架中的浏览历史条目 | 两主题共用关闭状态；长按正常进入“已选择 1 本”，没有新增振动记录，随后退出编辑未删除数据 |
| 经典主题重新开启后重复同一长按 | 正常进入编辑，系统服务新增本应用 `CLICK` 记录（15:12:23.158）；切回档案后按钮恢复 `TEXTURE_TICK` |
| 点击设置行关闭再开启，随后冷启动 | 整行点击也生效；重启后的开关为 `checked=true` |

补充检查：受影响的 10 个 Dart 文件定向分析无诊断；使用 `build_rust_backend.ps1 -SkipCodegen` 构建 ARM64/ARMv7 核心，随后 `flutter build apk --release --target-platform android-arm,android-arm64 --split-per-abi` 成功；arm64 APK 的正式签名校验成功且与原安装包一致。未新增、修改或运行测试。

结束时恢复档案主题、跟随系统、沉浸式播放布局和振动开启，返回首页并保留新包；系统 `haptic_feedback_enabled` / `sound_effects_enabled` 均保持 1，分辨率和字体比例不变。未卸载、清空数据或改装调试包。截图、语义树、振动记录、日志与原包备份位于仓库外 `%TEMP%\fqapp-haptics-20261110`。

这些记录证明界面、持久化与 Android 振动请求开关，不证明实体振动马达的触感或噪声；ARMv7 仅构建，未在设备上运行；视频倍速与听书定位的具体播放路径未实操。最终进程的 logcat 未见匹配的崩溃或振动通道初始化错误。iOS 构建与物理设备性能未验证。

### 分层跑测试

#### 2026-11-10 书旗书架来源修复（#270）

基于主线 `16ee87b` 独立处理，不包含 #304 的只读边界改动。书旗详情进入阅读器时传入 `ShuqiBook.toMediaItem()`，阅读菜单加入本机书架使用 `source=shuqi` 和原始数字 ID，不再把阅读会话 ID `shuqi:<id>` 当作番茄书籍。书旗仍不写阅读历史、阅读时长或章节缓存。

`ShelfStore` 初始化时只迁移符合旧阅读器输出形状的 `shelf_v1:book:shuqi:<数字 ID>` 记录：保留全部元数据及 `addedAt`，写入 `shelf_v1:shuqi/book:<数字 ID>` 并落盘后才删除旧键；已有有效目标记录不覆盖，无法确定身份的记录不改。旧错误键不符合分组标识校验，不能经现有分组入口产生有效归属；本次不扩大分组或备份协议的接受范围，也不保留双读别名。

MuMuManager 确认实例 `0` / Android 12 / `127.0.0.1:16385`，x86_64 经 ARM 转译运行正式签名 arm64 split release，版本保持 `1.0.201+206` / versionCode `2206`。首轮验证包 SHA-256 为 `fd53fd36e6bfec96749ef05c249152f631de661fd7c8a5f8ce009e3c185d349a`；审查后收紧已有目标记录的身份校验，重建最终包 SHA-256 为 `7d428147423d68b2ca86495c939592447416f84697e7394ea55b0620e47cb27c`。两次覆盖安装后设备侧均核对一致。未改动 Rust，原生库复用与当前主线源码相同的已构建产物。

| 真实路径 | 观察结果 |
|---|---|
| 旧包搜索书旗 → 打开正文 → 阅读菜单加入书架 → 从书架打开 | 样本 `9136773` 误进番茄详情，显示 `shuqi:9136773`，详情加载失败 |
| 保留错误条目覆盖升级 → 书架打开 | 同一本书仍为 1 条，正确显示书旗详情、1493 章目录及首章正文；菜单识别为“已在书架” |
| 终止进程、重新启动并从书架打开 | 条目仍存在且进入书旗详情；MuMu 的启动命令有一次需再次前置任务，不以命令返回值代替界面验收 |
| 阅读菜单移出 → 再加入 → 书架重新打开 | 仍只有 1 条，可正常打开，作者字段随新条目保存 |
| 应用内导出迁移后备份 | `id=9136773`、`source=shuqi`、原加入时间保留；旧包误排除的 1 条变为正常导出，未放宽备份校验 |
| 保留正确条目、旧包再次加入同书 → 覆盖最终包 | 旧包确实产生 2 条；最终包收敛为 1 条并可打开正文，前后导出的正确条目逐字段一致（含作者和加入时间），旧错误项不再被备份排除 |
| 仅移除本轮临时书籍后再次导出 | 书架恢复 0、历史 3、已看 0；历史、已看及分组与本轮操作前导出一致 |

辅助检查：两个改动 Dart 文件格式化无变化、定向分析及 `flutter analyze --no-pub lib` 无诊断，`flutter build apk --release --target-platform android-arm64 --split-per-abi` 成功。未新增、修改或运行测试；KGP 插件未来兼容警告（#205）仍存在。

截图、UI XML、应用导出及构建日志保存在仓库外 `%TEMP%\fqapp-issue270-20261110`，不上传用户数据。未卸载或清空数据。迁移目标已存在的分支已走实际旧包/新包升级路径；损坏记录和落盘中断未进行故障注入。Windows、ARMv7 及 Xiaomi/HyperOS 真机未验证。

#### 2026-11-10 CI 失败定位与生产路径修复（#306 / #301）

本轮基于 #306 的 `78be475`，没有修改工作流、依赖或版本。初轮不改冻结测试；用户随后明确授权提交推送，并只对 #300 异步隔离和 #304 失效契约作定向例外，不新增测试。两个生产改动：

- `HapticPreferences._applyPlatform` 给可选的 Android 振动通道调用增加 2 秒响应上限，超时返回失败，启动按既有可选初始化策略继续；不把平台未应用当作成功，也不阻止后续加载重试。#306 的 run `42802056525` 和主线 run `42778150152` 均有 7 项启动等待超时。Dart VM 断点确认书架与分组已经就绪，未完成的是 `HapticPreferences._loading` 内无回复的 `setEnabled` 调用，不是主题值解析。
- `LibraryPage._removeFromShelf` 在书架删除成功后，先批量清理本地导入书的分类归属，再逐本删除文件；目录解析或文件删除不能挡住前面的归属清理。归属清理失败仍记录日志并继续文件清理，普通非本地书移出仍保留分类。该顺序对应 #301 run `42600437041` 的本地书分类残留；旧用例的短等待在本机普通运行中未稳定复现，不能仅凭诊断运行认定修复。

MuMu 实例 `0` / Android 12 / `127.0.0.1:16385`，720x1280、字体比例 1.0，x86_64 经 ARM 转译运行正式签名 arm64 split release。Flutter 3.47.9 / Dart 3.13.7，版本保持 `1.0.201+206` / versionCode `2206`。最终 APK SHA-256 为 `a9e68a0d9188d4eac6922914d733cc1e9c9a7121d80bfe185a31168ebfa3d49d`，覆盖安装后设备侧一致；Rust 未改，复用已有同源原生库。

| 真实路径 | 观察结果 |
|---|---|
| 旧包关闭振动反馈，保留数据覆盖升级 | 首页正常进入，外观页仍显示关闭 |
| 开启振动反馈，终止进程后冷启动 | 首页正常进入，外观页仍显示开启 |
| 导入临时 TXT，建分类并分配，再移出书架 | 界面从 1 本变为 0 本；操作前分类弹层确认临时分类已选中 |
| 移出后在撤销窗口恢复同一条目，再检查分类 | 弹层选中“未分类”，不是重新导入的新 ID；撤销只恢复书架记录，本轮不声称已删除的 TXT 正文也被恢复 |
| 删除本轮条目及临时分类，再导出备份 | 书架 0、历史 3、已看 0；书架、历史、已看和可导出分组与操作前一致，AI 资产解压后仅导出时间变化 |

已清理临时导入文件，恢复档案主题、系统外观、沉浸式布局与振动开启，返回首页。最终进程日志未见匹配的崩溃、ANR、未处理 Flutter 或 Hive 错误。没有卸载、清空数据或操作实体手机；MuMu 不证明物理马达触感。通道永不回复及文件 I/O 挂起未在设备上注入故障。

辅助检查：固定工具链下两个 Dart 文件格式化无变化，完整 `flutter analyze --no-pub` 无诊断，arm64 release 构建成功。只运行既有冻结用例作定位：改动后 7 项启动等待不再超时，相关初始化和书架分类诊断未报错；这些结果不代替上表的实际用户路径。KGP 未来兼容警告（#205）仍在。证据仅保存在仓库外 `%TEMP%\fqapp-ci-repair-20261110`，原始备份和日志不上传。

定向隔离与其他分支：

- #300 run `42583363579` 的 `dart-gate` 在 30 分钟取消。首次失败是 `library_shelf_test.dart` 的首页缓存续读用例结束时仍有 10 秒虚拟计时器，堆栈为 `SecureKeyProvider -> EncryptedHive -> ReaderUnderlineStore`，随后用例持续超时。相关代码与当前相同。在 VM 断点等待安全存储失败的 30 秒冷却到期后继续，复现了相同断言；继续定位还确认划线存储单例队列会残留上一用例的虚拟时钟任务。只改该现有测试文件的环境：安全存储通道明确模拟不可用并逐项重置，书架导航用例不初始化无关的划线存储，退出恢复原状态；原有导航断言全部保留。没有修改生产安全存储超时、冷却或重试。改后整份 41 项诊断完成；同一 VM 断点等待到失败时间已过去 77 秒后，首页续读、书架续读、关闭直读三个用例也顺序完成。
- #304 的只读契约修正在该 PR 独立工作树处理，不带入本分支；公共生产修复和 #300 隔离同步过去。账号/上游写入旧测试按用户例外授权收窄或移除，保留公开读取及本机来源限制，不恢复废弃接口，也不跳过门禁。
- APK 和完整静态分析已验证；远程 CI 以各 PR 推送后对应新 head 的实际状态为准，不能沿用旧 run 或本地诊断结果。Windows、ARMv7 与物理设备未在本机复验。

测试按「秒级模块 → 收尾全量 → CI 兜底」三层跑，日常迭代不要每次都付全量的成本：

| 层 | 命令 | 规模 | 何时用 |
|---|---|---|---|
| 模块 | `./scripts/test_quick.sh home` | 秒级 | 改动迭代的每一轮 |
| 全量 | `./scripts/test_quick.sh --all`（即 `flutter test --no-pub`） | 2000+ 项 / 数分钟 | 交付前收尾 |
| CI | `android-apk.yml` 与 `windows.yml` 每次 master push 全量 | 同全量 | 兜底 |

- `test_quick.sh` 的模块词按测试文件名**子串**匹配：`home` 会同时命中 `home_page_test.dart`、`home_scroll_cost_test.dart`、`real_home_payload_test.dart`（子串宽是特性，`provider` 这类词会带出全部 `*_provider_test.dart`）。多个词合并去重后一次跑，也可直接传测试文件路径；拼错的模块词是硬错误，不会静默少跑。
- 脚本固定带 `--no-pub`：首次 `flutter pub get` 之后，每次运行前的依赖解析是纯启动开销。`--concurrency=N` 可提并行（默认沿用 Flutter 的 4）。
- **收尾仍要全量**：跨模块的涟漪只有全量能兜住——例如 `dramaProvider` 复用 `HomeNotifier`，改 `home_provider.dart` 可能影响 `drama_page_test.dart` 的断言；CI 反正会全量跑，本地先跑一次（数分钟）换一个比 CI 快得多的失败反馈。
- 套件平均单项约 0.2 秒，没有病态慢测试；耗时大头是播放器/短剧/音频侧的广度（约六成文件）。靠删测试精简省不了多少时间，还会丢掉按回归记录的防坑文档——要精简就精简跑法，不是删用例。

---

## Android 原生核心集成

### 部署流程（`BackendService._deploy`）

1. 将 `config.json`、`filter.json`、`device_pool.example.json` 部署到应用私有目录 `files/backend/config/`。
2. 首次启动时用示例初始化 `device_pool.json`；以后保留后端注册并保存的实际设备池。
3. 从 Flutter 资源清单枚举并部署 `assets/filters/` 下的文件（含清单中的嵌套文件）到 `backend/filters/`。内容变更时替换旧资源。
4. 运行时资源不含任何可执行后端二进制；Rust 核心以 `libfqapi_core.so` 随 APK 打包，在进程内加载。

`config.json` 里还有一个可选的 `upstream` 段（`version_name`、`version_code`、
`manifest_version_code`、`update_version_code`、`user_agent`）：**设备注册**用的 UA 与版本号从
这里读，UA 支持 `{manifest_version_code}`（别名 `{version_code}`，两者取同一个值）、
`{os_version}`、`{device_type}` 三个占位符。字段留空即用改动前硬编码的值，所以不写这一段
行为完全不变。

范围只说一次，免得误解：**这一段只作用于设备注册的第一步 `device_register`**。同一流程里
`activate_premium` 仍写死 `version_code=61532&version_name=6.1.5.32`，`register_key` 写死
`version_code=6.1.5.32` 且 UA 是光秃秃的 `com.dragon.read`，`sdk_version` 与 `package` 也是常量；
正文 / 目录 / 搜索 / 短剧端点的查询串（`rust/src/endpoints/*.rs`）与通用请求的 UA
（`rust/src/upstream/client.rs` 的 `DEFAULT_USER_AGENT`）同理。上游要动这些仍然得改代码。

类型上：数字、布尔、`null` 都会被转成字符串（`null` 视作留空，走默认值）；数字写成 `71332`
或 `"71332"` 等价，整数值的浮点写法（`71332.0`、`1e3`）也等价于 `71332`，真正的分数
（`7.1`）保留小数。

形状上：**整段必须是 JSON 对象**。数组、字符串、数字都会让 `Config::load` 失败、后端起不来
——这一点不是多余的：serde 默认会把结构体按位置从数组反序列化，`"upstream": [1, 2]` 会被读成
`version_name = "1"`、`version_code = "2"`，一个看起来合法、实则完全错误的身份会被悄悄发给
上游。整段写成 `null` 视作「未配置」，等同于不写这一段。

**段内的字段名也必须写对**：多写或拼错一个字段名（例如 `useragent` 而不是 `user_agent`）
同样是配置错误，会让 `Config::load` 失败。否则拼错的字段会被静默忽略——UA 保持内置模板，
改配置的人只会看到「改了没效果」，而没有任何报错提示。

**`version_name` 和 `version_code` 必须一起写**：只写其中一个同样是配置错误（理由见下）。

一致性上：三个 `*_version_code` 是同一个上游版本的不同视图。**显式填的字段一定生效，没填的
跟随 `version_code`**（而不是退回内置默认值），所以只改一个 `version_code` 时，注册头里的
manifest / update code 会一起跟着走，不会出现新旧版本号并存的设备身份；四个字段都没填才回到
改动前的硬编码值。

`version_name`（`7.1.3.32`）和 `version_code`（`71332`）是同一个版本的两种写法，但**两者之间
没有可推导的规则**——去掉点号对多数版本成立（`6.5.1.32` → `65132`），对少数不成立
（`15.8.0` → `150800`，不是 `1580`）。所以后端**不做任何推导**，也**不接受只填一个**：
只写 `version_name` 或只写 `version_code`，和数组、拼错的字段名一样，是**配置错误**，
`Config::load` 失败、后端起不来。

这样处理而不是「警告一下继续跑」，有两个原因：一是猜出来的版本号是一个看起来对、实则错的上游
身份，比直接报错更糟；二是桌面构建不安装 logger（`log` 宏是 no-op），警告在 Windows 上根本
看不见，而配置错误在所有平台上都能报出来。**要改版本，四个字段一起改。**

注意两点：`config.json` 是随包发布的资源，`BackendService._deploy` 每次启动都用包内副本覆盖
`files/backend/config/config.json`，所以手改设备上的那份不生效；身份参数在后端每次启动时重新
读取（`stop()`+`start()` 也会重读），但要换配置仍需重新打包并重启 App。
关于设备池：每个设备在注册时**记下当时的 `version_code`**（`device_pool.json` 的
`registered_version_code`）。后端启动时，**用别的版本号注册的设备会被退役**——不会把一个
声称了旧版本的设备发出去。退役的设备会在需要时重新注册。

一个例外，也是有意的：**这个字段是后加的**，所以在这之前写入的设备池文件里没有它。那些设备
**不会被清空**——一次 App 升级不应该把整个设备池掏空、对着上游来一轮集中注册。它们会随着
使用逐个被替换掉。


### 废弃的 HTML 插件资产（#252）

`assets/plugins/player.html` 没有产品调用方，按历史残留移除，不作为待接入功能保留；同时移除 `pubspec.yaml` 的目录声明和 `BackendService._deploy` 的插件部署入口。播放器继续使用现有 `NativePlayer` 平台实现，漫画阅读继续走 Flutter 页面；Rust 的通用静态文件服务不是这些 HTML 的调用方，不作改动。

新安装包不再包含或部署该插件。升级时不主动删除旧版本已落盘的 `backend/plugins/` 文件，不清空应用数据；这些遗留文件不会因本次改动重新部署。经 #262 的定向维护授权，`test/backend_service_test.dart` 改用嵌套过滤器作为部署样本，检查过滤器更新、设备池保留、新安装不生成插件和历史插件不被覆盖或删除；不为旧断言恢复产品部署路径。

### 启动流程（`BackendService.start`）

```dart
// 默认：flutter_rust_bridge 直调 Rust 核心（进程内，无独立进程）
await rust.init(
  configPath: ..., poolPath: ..., filterPath: ..., runtimeDir: ..., port: 18921,
);
// 端口来自部署后的 config.json；外部客户端（Legado 书源等）按该端口访问 /api/v1/*
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

Rust 核心会使用配置文件推导运行目录，过滤器和 `src/` 均按绝对路径加载；
loopback HTTP 适配器只绑定 `127.0.0.1`，`/health`、`/api/v1/*` 与 `/src/*` 共用同一分发器。
读路由对任何本机客户端开放（供阅读软件等外部工具调用），写路由仍要求每次启动的能力值。
加密播放所需的 `libshortplay_crypto.so` 由 APK 构建自动从 `native/` 生成。

---

## 本机密钥库（SecureKeyStorage）

Hive 主密钥与设备池密钥不再经过 `flutter_secure_storage`，改由应用自己的
`SecureKeyStorage`（`lib/services/secure_key_storage.dart`）按平台落到系统级密钥库。
这样做的直接原因是 `flutter_secure_storage_windows 3.1.2` 把 `win32` 钉在 5.x，
挡住了 `wakelock_plus` / `package_info_plus` 的 Built-in Kotlin 版本（#205）。

| 平台 | 实现 | 位置 |
|---|---|---|
| Android | AndroidKeyStore 内的 AES-256-GCM 密钥，密文存 `shared_prefs/fqapp_secure_keys.xml`；条目名作为 AAD | `android/app/src/main/kotlin/com/fqapp/fqapp/SecureKeyPlugin.kt` |
| iOS | Keychain 通用密码项，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | `ios/Runner/AppDelegate.swift`（`SecureKeyBridge`） |
| Windows | DPAPI（`CryptProtectData`，当前用户范围）保护的文件 `secure_keys.dpapi` | `lib/services/windows_dpapi_key_store.dart` |
| Linux | libsecret（Secret Service）单个 JSON 条目，调用在独立 isolate 中执行 | `lib/services/linux_libsecret_key_store.dart` |

失败语义与原来一致，且更严格：**“没有密钥”与“读不到密钥”必须分开**。

- 只有平台回答“条目不存在”时才允许新建密钥；
- Keystore/DPAPI/libsecret 报错一律抛给 `SecureKeyProvider`，由它失败关闭
  （`EncryptedHive` 会拒绝明文回落或隔离箱文件，绝不静默覆盖）；
- Windows 先写 `.tmp`、把旧文件轮换成 `.bak` 再改名，崩溃后仍能读到上一份密钥；
- Linux 会先 `secret_service_get_sync(OPEN_SESSION | LOAD_COLLECTIONS)` 预热，
  避免冷 keyring 首次查询误报“不存在”而另建密钥。

### 迁移与回滚

`defaultSecureKeyStorage()` 返回 `MigratingSecureKeyStorage`：读时先查本机密钥库，
缺失才读旧 `flutter_secure_storage` 并回写；写时两边都写。因此：

- 升级到本方案后，旧密钥在首次读取时自动搬家，书库/历史/WebDAV/AI 凭据保持可用；
- 回滚到旧 APK 仍能读到同一把密钥（旧存储里有双写副本）；
- 迁移成功会写一条 `keys` 标签的运行日志（“已将 … 迁移到本机密钥库”），
  可在“设置 → 服务 → 运行日志”搜索 `keys` 核对。

### 第二阶段：移除 `flutter_secure_storage`（未做，等一轮发布后）

迁移完成后，旧包只剩“导入源”作用。满足下列条件即可删除：

1. 线上版本全部经过一次含本方案的启动（本机密钥库已写入，日志可核对）；
2. 删除 `lib/services/secure_key_storage.dart` 中的 `FlutterSecureKeyStorage`、
   `MigratingSecureKeyStorage` 的 legacy 分支，以及 `pubspec.yaml` 的
   `flutter_secure_storage` 依赖；
3. `flutter pub upgrade`：`win32` 不再被钉住，`wakelock_plus` ≥1.8、
   `package_info_plus` ≥10.1 自动落地；
4. 之后才具备删除 `android/gradle.properties` 中 `android.builtInKotlin=false`
   的前提（仍需先处理 `flutter_tts` 的 KGP，见 #205）。

> macOS / Fuchsia 在本仓库没有 runner，也没有原生后端；这两个平台保持旧存储
> （`defaultSecureKeyStorage()` 会回退），删除依赖后它们不再受支持。

---

## API 对接说明

App 通过 `ApiClient` 调用后端 **`/api/v1/*` 业务路由**（Rust 核心 `rust/src/endpoints/`），首页推荐使用
`/api/v1/recommend/homepage`。漫剧首页使用 `tab_type=24`；听书使用现有音频播放接口，漫画首页使用真实漫画分类搜索。
客户端模型同时兼容归一化结果及部分旧版响应结构：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/recommend/homepage?tab_type=&offset=&session_id=` | 首页分类推荐及游标分页 |
| GET | `/api/v1/search?query=&tab_type=&offset=&count=10` | 搜索页按分类请求：综合 `1`、小说 `3`（上游标题书籍）、短剧/漫剧 `11`、漫画 `8`、听书 `2`，使用返回的游标；评分门槛仅筛选客户端已加载结果，不改变请求参数与游标 |
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

`MediaItem.fromRaw()` 兼容上游 API 的各种字段形状：

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
- 提供推荐、小说、短剧、漫剧、漫画和听书分类；搜索行与分类条固定在顶部，只有下方内容参与横滑切类、竖向滚动和下拉刷新
- 分类选中项使用浅背景与短下划线；各项预留选中字号的宽度，切换时不挤动相邻标签，墨水屏改用描边
- 切分类只把内容区复位到顶部；横滑时预览相邻分类最近显示的内容，未访问的分类显示骨架，窗口宽度或字号变化后重新生成预览；首次进入后再切分类使用轻量加载态
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
- 左上封面（3:4）+ 右侧标题、`分类 · 完结状态 · 字数`、「原创」徽章，标题始终完整换行不截断
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
- 听书直接进入听书页并接续已保存的进度；下载一次点击即缓存整本（从目录开头检查缺章，复用已有缓存，进度显示在底栏，缓存中再点一次停止）。下载的章节不受缓存上限约束，也不会被自动清理
- 按内容类型打开小说阅读器、短剧/漫剧播放器、听书播放器或漫画阅读器
- 续读/续听优先按已保存的章节 ID 定位，目录更新后仍能找到原章节
- 富元数据直接取自同一份详情响应，不额外发请求；书评请求失败只隐藏该区块，不影响整页

### 阅读器（`reader_page.dart`）
- 加载解密后的图文正文，保留段落、插图和图注的原始顺序；签名图片地址保留，使用上游尺寸预留空间
- 插图保持原比例，分页时整张显示，点击进入全屏并可双指缩放；加载失败可重试，加载完成不会重新分页
- 正文首行缩进两字、续行顶格，两端对齐；段距与行距独立，开头重复的章节标题只显示一次
- 默认收起菜单，点击正文中央滑出上下菜单；菜单叠在正文上，不改变正文高度或滚动位置。返回键先收起菜单，再退出阅读
- 菜单上方借用全局听书胶囊，音频、系统朗读和有效的历史续听共用同一套控制路径；无会话且无续听记录时不显示，也不占位。跨书阅读仍控制正在听的书，暂停时保留胶囊，关闭后移除但不收起阅读菜单
- 听书胶囊复用全局播放器的封面、播放/暂停、关闭三块控件和关闭动画；阅读菜单内的音频胶囊额外提供 `⋯` 原地音色切换，系统朗读与历史续听卡不显示该入口。切真人讲书前提示并二次确认，切换期间防止重复提交，失败不提示成功，重选当前音色不提示切换。正文加载状态不禁用另一会话的播放控制；正文底部播放/同步小按钮仍按本书的听读状态独立显示
- 阅读菜单右侧的圆形“听”使用官方 `f7s` 的 56dp 主题图，右边距 16dp、菜单上方下边距 20dp，与上方“看”间隔 11dp。同书的有效音频或系统朗读会话存在时隐藏（包含暂停、加载和真人有声的原著映射）；只剩历史续听卡不隐藏，听 A 读 B 时也保留入口
- 点击“听”直接沿用当前页/段落定位及已存音色后台起播，本地书使用系统朗读。底栏不再重复提供耳机入口；设置 → 更多设置 → 听书方式保留原来源选择和系统朗读。`/tones` 明确无可用资源时提示而不启动上游播放，请求失败保持未知、后续菜单打开重试；不仿造官方远程隐藏/实验配置，本轮不包含展开式听读引导
- 后台听书的返回值只表示请求已接收，不再据此提示“已开始播放”；加载、实际播放和错误由全局胶囊的会话状态显示。菜单显隐统一同步音量键翻页开关。系统朗读起播保留阅读菜单的当前状态，已展开的菜单和胶囊不自动收起，也不重新打开用户已收起的菜单；在线听书起播保持原有规则
- 当前阅读页也显示本书的播放错误提示，包括未安装系统 TTS 引擎；全局浮窗隐藏不再吞掉这些错误。提示沿用会话级去重，页面被遮挡、离开或当前会话已切到别书时不借阅读页弹出
- 阅读设置 → 更多设置 → 显示提供独立的“系统状态栏”和“底部导航栏”开关。底部导航栏默认关闭，保持旧版沉浸效果；开启后由 Android 显示当前系统导航方式的小白条或导航键，不切换系统导航模式。偏好经 `reader_show_system_navigation_bar` 保存，随阅读会话在恢复焦点时重应用；离开阅读或会话结束时仍还原进入前的系统栏状态（#258）
- 从 #223 仅迁移非正文页隐藏播放/同步按钮、上游时间点优先高亮和后台起播异常返回失败；时间点的原文偏移经正文替换映射转换后再高亮。保留字幕兜底、双击跳读、高亮颜色/下划线与手动翻页不停播。#224 的别名复用、音色切换、阅读菜单内原地音色面板和重复打开保护沿用当前实现，不恢复旧胶囊或旧测试
- “看”的关联查询与点击后的打开请求分别持有取消句柄；收起菜单、离开当前阅读路由、切章、进入后台或修改相关设置会使旧打开请求失效，旧请求的清理不会覆盖新请求。关联查询不因收起菜单丢失
- 阅读菜单右侧的“看”入口通过 `/api/v1/books/{id}/video-match` 查询本书关联剧，后端按官方 V2 的 `VideoTimePointReqType.MatchMotionComic=2` 调用只读 `/reading/reader/video/timepoint/`。无关联、本地书或用户关闭展示时不显示；请求失败不打断正文，下次打开菜单可重试
- “看”按钮使用官方 `g6h` 的 56dp 主题图；有效封面加载后可展开一次引导，墨水屏和系统减少动画模式不展开。设置 → 更多设置 → 改编剧可分别关闭入口和阅读章节同步；按真实 `NovelToVideoMap` 的剧/集 ID 定位，缺失映射则使用已有观看记录或首集，不伪造进度
- “看”的引导只在菜单可见、阅读路由位于最前且应用在前台时计时；完成可见的展开动画后才记为已展示。设置遮挡、菜单淡出和后台状态会取消引导，尚未完成展示时保留后续展示机会
- 短剧/漫剧播放页接受可选 `startPosition`：阅读章节同步从对应集开头播放，普通入口仍按原规则续播。这里不仿造官方远程实验分组，也不新增全局短剧音频挂件
- 默认左右分页，可点击或滑动翻页；翻过章节末页进入下一章首页，返回上一章进入末页。排版面板可切换为上下滚动，滚动模式保留点击滚动一屏
- 分页跨章回翻以章末文字位置为锚点；段评气泡异步到达并增加页数后仍停在末页，不沿用首次排版的末页起点。用户实际翻页后恢复普通页首锚点，显式「上一章」按钮仍进入章首
- 滑动/覆盖翻页按起手以来的手指位移推进，页面从屏幕边沿进入，不因触点位置瞬间跳动；反向拖动退回起手位置，单次手势最多推进一页，接手未结束的翻页动画时保留当前页面位移。章节边界沿用原有翻章路径
- 分页按当前字体、字号、留白与窗口尺寸计算，保留完整文本行；页脚显示本章真实页码，排版变化和横竖屏切换后重新计算
- 页眉显示书名与章节，页脚显示章节序号、全书进度、时间和电量；可在排版面板关闭阅读信息。全书百分比按章节与章内位置估算
- 字号、字重、字距、行距、段距、标题大小与对齐、上下左右留白和四种阅读背景实时预览并保存
- 设置 → 更多设置 → 显示提供「正文对话高亮」，默认关闭，独立于听书的「朗读句高亮」；样式可选自动、背景、下划线，自动在墨水屏使用下划线
- 对话按成对的 `“”`、`‘’`、`「」`、`『』` 和英文双引号识别，可跨段落；未闭合引号不延伸高亮到章末。标记使用替换后的显示文本与已有字形坐标，不改正文、复制内容、段评和播放定位，也不因开关或样式变化重新分页；分页、滚动及连续阅读的相邻章节共用这一路径
- 支持通过 Android 系统文件选择器导入 TTF、OTF、TTC 字体（单文件不超过 32 MB），也可切回系统字体
- 亮度可手动调整或跟随系统，只影响当前阅读窗口；切到后台、退出和 Activity 重建时恢复原窗口亮度
- 阅读设置 → 更多设置 → 显示中的“底部导航栏”独立于“系统状态栏”，默认关闭，保留原来的沉浸效果（#258）。开启后请求 Android 显示当前导航模式的小白条或导航键，不更改系统导航模式
- 导航栏偏好使用 `reader_show_system_navigation_bar` 保存，重启后保留；返回阅读或恢复窗口焦点时重新应用，离开阅读时还原进入前的系统栏状态。正文沿用现有 `SafeArea` 避让系统栏
- 如果设备或模拟器从系统层禁用导航栏（例如 MuMu 的 `qemu.hw.mainkeys=1`），应用的显示请求不会创建导航栏。原生窗口请求、偏好保存与实际小白条显示/手势必须分别验证，不能把前两者当成完整交互验证
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
- MT6895 / 天玑 8100 设备在 Flutter 引擎启动前关闭 Impeller，使用 Skia/OpenGL ES 兼容视频纹理；其他芯片保留默认渲染策略。此策略不关闭 Media3 硬件解码，也不更换 SurfaceProducer。冷启动 logcat 中 `FqRenderer` 的 `policy=skia-opengles` 表示已应用启动参数，实际花屏是否消失仍需设备验收。实现入口为 `MainActivity.getFlutterShellArgs()` 和 `RendererCompatibility.kt`。
- 自动连播（播完自动下一集）
- 控制栏三秒后自动隐藏；单击显示或隐藏，双击播放或暂停
- 支持搜索选集、上下集、快进快退 10 秒和全屏
- 加载期不铺封面：只留黑底与加载圈，首帧到达后按解码尺寸出画（封面是竖图，铺进横版盒会被裁成一条）
- 全屏方向按视频比例决定：横屏剧集横屏、竖屏剧集竖屏；**尺寸未知时不发方向请求**，
  因此横屏连播不会被掰回竖屏；尺寸到达后也**不补发**，本次全屏的方向就此确定
  例外是 feed 卡片的「横屏钮」（`openFullScreen`）：入场那一次强制横屏，用户之后
  自己切全屏不再沿用（`_entryLandscape`）
- 锁定后方向不再变化（连播也不改），解锁时才按视频比例调整
- 0.75～2 倍速可持久保存，长按临时 2 倍速，松手恢复
- 暂停时拖动进度保持暂停，切到后台暂停播放
- 播放秒数、集数和封面定时写入历史，支持续看

### 播放页布局与手势

播放页的布局、右缘浮层与手势在近几轮重构中形成了固定约定，改动前请先读这一节。

**布局三档**（`PlayerLayoutMode`，持久化在 `services/player_layout_preferences.dart`，
设置页「播放页布局」可切换）：

| 档位 | 行为 |
|---|---|
| 沉浸式 | 单画面，方向跟视频比例走 |
| 横屏片源自动分屏 | **竖屏设备**上遇到横版片源才自动分屏（只走上下轴）；换集沿用上一集判定，首次进入尺寸未知时按竖版兜底；其余同沉浸 |
| 始终分屏 | 一律分屏，分屏比例由用户拖动分隔条决定 |

- 画面几何统一走 `widgets/player/player_video_layout.dart`：**横屏按整窗宽度居中**，
  不再从画面里挖掉挖孔那一侧的安全区；纵向仍让开上下 `insets`。
- 分屏有上下、左右两轴，但**只记当前轴的比例**（`_splitRatio` + `_splitRatioSideBySide`）：
  换轴时旧轴比例作废、回落该轴自己的默认值（竖屏约 0.28、横屏约 0.64）。
- 分屏视频盒（`compact`）不复用竖屏底栏：紧凑条上直接显示当前倍速（`compact-rate`）。

**右缘浮层**（`widgets/player/player_side_panel.dart`）：视频设置、弹幕设置、
字体大小、选集抽屉、同系列共用同一份几何——贴右缘、铺满高、宽 = `(窗宽/3).clamp(240,420)`、
左圆角 12、200ms 滑入。**面板贴右缘时 `SafeArea` 必须 `left: false`**：左边那条安全区
属于屏幕另一侧的挖孔，让开会把整列内容右推。宽度用 `LayoutBuilder(constraints.maxWidth)`
量，不要用 `MediaQuery.size`（页面嵌在别处时两者不等）。

**倍速 / 清晰度的入口**：**底栏（或分屏紧凑条）已经显示当前档时**，这两项不出现在
「视频设置」里——点当前档直接开档位弹层：竖屏是底部弹层（`widgets/player/playlet_option_sheet.dart`，
键 `player-rate-sheet` / `player-quality-sheet`），横屏是右侧面板
（`player-side-rates` / `player-side-quality`）。反过来，**底栏没有当前档可点**时
（`catalog` 形态竖屏、feed 卡片、通用播放器）视频设置里保留一行入口（行尾当前档，
点开同一个弹层）；分屏紧凑条已有当前档，不再重复给入口。

**横屏「下一集」卡**（`video_player_chrome.dart` 的 `_nextEpisodeCard`）：

- **16:9 为理想比例**；封面按「3 倍卡高」铺进去并上移一个卡高，窗口里只露出封面中间 **1/3**。
- 锁定按钮在场时排在它**正下方**（锁仍钉在右缘中点，不动），高度取「锁底 → 进度条上沿」
  的剩余空间，48–72dp；没接锁功能时在顶栏与底条之间居中。
- 卡片整体右移半宽，**右半溢出屏幕**，只留左半可见；可见宽度下限 48dp（因此卡宽 ≥96dp，
  高度 48–53dp 时卡片会比 16:9 略方），右缘再让开 `insets.right` 的挖孔。可用高度连
  48dp 都放不下时**整卡不画**（不做迷你热区）。卡内文字只排在可见左半、集数用
  `FittedBox` 缩排，避免被屏幕边缘硬切或省略。
- 读屏语义是「下一集，第N集」，`onTap` 挂在 `Semantics` 上（`excludeSemantics` 会丢掉
  子树的 tap action）；最后一集不摆。

**手势通道**（`services/playback_gesture_levels.dart` ↔ `NativePlayerPlugin.kt`）：
左半屏上下滑调亮度、右半屏调音量，经 `MethodChannel('fqapp/native_player')` 调用
`gestureLevels` / `setScreenBrightness` / `resetScreenBrightness` / `setMediaVolume`。
亮度下限固定 0.02（Dart 与 Kotlin 两侧同值），只在「被覆盖过」时才在退出播放页时还原
窗口亮度；`NativeGestureLevels.kt` 负责把 255/1023/2047/4095 四种 OEM 量程归一。这些
调用都不需要额外权限（窗口亮度覆盖 + `AudioManager.setStreamVolume`）。

### 书架（`library_page.dart`）
- 阅读历史：支持列表或封面网格（含进度、集数）
- 清空功能
- 右上角“离线缓存”可直接打开已缓存书籍，不依赖在线详情或目录接口
- 设置 → 数据 → 章节缓存，可查看占用、删除单本或清空全部缓存；阅读历史保留
- 本地服务启动期间也可从“离线阅读”入口打开缓存

### 听书（`audio_page.dart`）
- 移动端智能朗读与真人讲书共用紧凑书籍行、逐句字幕、操作行、进度与播放控制、边听边读及声音入口，不再按模式切换大封面和小封面版式；桌面保留原有布局
- 48×64 封面框按原图比例完整显示，不裁掉封面上下内容；书籍行右侧打开简介弹层，关联作品仍可跳转详情
- 顶部模式切换始终占据同一位置，暂无可用音色或切源期间禁用对应项；切源保持页面身份与当前作品的背景色相，不因音频书 ID 或暂时为空的附加信息重建整页。播放仍切换真实目标书和章节 ID，已知的真人／智能类型不依赖附加信息加载完成
- 字幕、加载、错误重试和连播倒计时共用固定槽位，字幕与槽位随系统字号等比例增大，状态变化不推移进度与控制行；小屏可竖向滚动。当前句高亮并显示上下文，真人模式保留有时间轴时展开原著全文的入口
- 边听边读入口在两种模式下保持位置；智能朗读打开字幕，真人讲书按时间轴打开原著对应章节，无字幕或原著映射时禁用并说明原因
- 操作行：语速 / 加入书架 / 下载 / 书评 / 更多
- `-15s` 进度条 `+15s` 与 `时:分/总时长`；控制行：目录 / 上一章 / 播放暂停 / 下一章 / 定时
- 两种模式通过同一紧凑声音行打开音色面板，保留多角色对话、智能音色与真人版本；同书切换音色保留播放位置，跨书版本沿用目标目录的章节匹配与历史恢复
- 阅读页起播遵循默认播放引擎，本地书固定使用系统朗读；菜单胶囊暂停时可选择引擎并接续，系统朗读中打开朗读设置。系统朗读胶囊封面返回书页，阅读菜单内则收起菜单；缺少阅读页上下文而无法切到系统朗读时保留偏好并明确提示，不把保存偏好当作起播成功
- 定时关闭（15/30/60 分钟），到时自动暂停
- 使用已有 Media3 播放器，提供播放/暂停、进度拖动、前后 15 秒和 0.5～2 倍速
- 目录可搜索，支持上一章、下一章及自动连续播放
- 后端提供多个音色时可切换，并记住音色、倍速、自动下一章与书架状态
- 播放秒数与章节定时保存，暂停、切章和退出时立即保存；重新进入可续听
- 后台播放：听书支持后台 keepalive（用户可在设置中开关）与通知栏媒体控制；
  断开耳机或蓝牙（becoming noisy）时自动暂停
- 倍速变速引擎（#129）：默认走**移植自 FFmpeg `af_atempo` 的 WSOLA**
  （`native/audio_tempo/sp_atempo.c` + kissfft，编进 `libshortplay_tempo.so`）。
  番茄官方听书倍速就是这条路——`libttmplayer.so` 里
  `avfilter_get_by_name("atempo")`、参数 `tempo=%1.2f`，
  `aformat -> atempo -> abuffersink`；窗口 `sample_rate/24`、Hann 窗重叠
  相加、FFT 互相关对齐。本仓库的参数与官方逐项一致，所以听感对齐。
  Media3 自带的 SonicAudioProcessor 是另一套实现（AMDF 基频搜索），
  高倍速下发毛/电音，只作为「兼容」回退档保留。

  设置 → 听书 → 听书变速引擎 三档：**对齐官方（WSOLA，默认）** /
  系统（AudioTrack/APM，`setEnableAudioTrackPlaybackParams`）/
  兼容（Media3 Sonic）。插入方式是自定义
  `DefaultAudioSink.AudioProcessorChain`（`WsolaProcessorChain`），
  只替换「谁来做时伸缩」，SilenceSkipping 的位置与默认编排一致。
  视频/短剧播放器永远走 Media3 内建变速，否则音频处理与视频渲染不再
  步进同一套计时。三档都在新建播放器时生效。

  **变速前置重采样**：与官方 `FFSampleFilter`/`aformat` 对齐——进 atempo
  之前把 PCM 统一到**设备原生输出采样率**（`AudioTrack.getNativeOutputSampleRate`，
  见 `NativePlayerPlugin.nativeOutputSampleRate()`），不是写死 48 kHz，
  否则原生 44.1 kHz 的设备上 AudioTrack 会再隐式重采样一次。相位是 64 位
  Q16 定点（32 位在长块上会回绕）。本项目实测音源均为 48 kHz，这一级
  当前是空操作，保留给原生率不同的机型。

  **响度压缩未做**：官方还有一层 `LoudnessAudioProcessor`（SAMICore →
  `mammon::LoudnessProcess`），但它依赖服务端下发的
  `volumeBalanceSrcLoudness`，且目标 LUFS 在 stripped 二进制里取不到。
  直接打包官方 `.so` 不可行（4 KiB 对齐不满足 16 KiB 页、私有许可、
  +15 MB/ABI）。要做应按 BS.1770 单遍流式归一，目标 -16 LUFS。

  算法回归：`NATIVE_CC=gcc node --test test/native_atempo_test.cjs`
  （时长比例、幅度、纯音保真度、拼接无爆音、窗口推导、重采样比例/音高/幅度）。

> **听书页的「书评」与章评**：官方听书页的操作项是「章评」（章末讨论），但章评属于
> 章节而不是正在收听的书；该面板展示的是整本书评，所以按实际内容标注为「书评」。
> 章评与段评已由后端提供：`/api/v1/chapters/{id}/reviews` 走 item-ideas 服务，
> 返回按段号索引的数量与评论 ID；正文需要再用评论列表端点按段落懒加载。

### 漫画（`comic_reader_page.dart`）
- 按接口顺序竖向阅读图片，支持章节目录和上下章
- 请求为 `/api/v1/manga/<itemId>?book_id=<bookId>`，阅读器传入已知书籍 ID，避免降级再次依赖失败的主接口。未提供 `book_id` 的调用仍从章节元数据解析；主路径和 `full` 降级都按章节取图，失败时返回错误，不再用书籍级 `book_detail` 图片代替目标章节。
- 图片按需加载并限制解码尺寸；单张失败可重试，点图可放大查看
- 用“图片序号 + 图片内位置”记录进度，图片加载改变高度后仍保持阅读位置
- 空章、章节请求失败和未显示成功的图片不会覆盖已有阅读进度
- 漫画和听书使用独立历史键，和同 ID 小说的阅读位置分别保存；书架与统计入口使用原作品 ID

### 我的（`mine_page.dart`）
- 服务状态（健康检查）
- 后端地址展示

---

## 已知问题与调试

### 1. 原生库与设备验证

- Rust 核心随 APK 打包并在进程内加载。先运行 `scripts/build_rust_backend.ps1`（或 `bash scripts/build_rust_backend.sh`）生成 `libfqapi_core.so`；黄金向量夹具随 `rust/testdata/` 分发，不参与构建。
- 加密播放使用 `native/` 中的 C 源码，Gradle/CMake 自动生成 `libshortplay_crypto.so`。
- 生成 Rust 核心后构建 arm64 APK，默认用 MuMu 验证 `/health`、搜索、阅读和加密视频播放；硬件相关行为仍需另行真机验证。Android 的纯 JVM 测试不会加载这两份库。

### 2. 调试技巧

沿用 MuMu 工作流中已确认的 `$adb` 和 `$serial`。`run-as` 仅适用于可调试构建，默认 release 包不可据此读取私有日志；可改看应用内诊断及 `logcat`，不要为取日志清空数据或改装调试包。

```powershell
# 查看后端日志（App 内写入）
& $adb -s $serial shell run-as com.fqapp.fqapp cat files/backend/backend.log

# 查看部署文件
& $adb -s $serial shell run-as com.fqapp.fqapp ls -la files/backend/

# 端口转发测试（后端起来后）
& $adb -s $serial forward tcp:18080 tcp:18921
curl http://127.0.0.1:18080/health

# Flutter 日志
& $adb -s $serial logcat -s flutter
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

番茄原始采集可在“设置 → 数据 → 备份与导入 → 导入番茄书架”中查看最近采集，
选择“解析并预览已保存的数据”，预览后合并到本机书架和历史。
导入复用现有 Hive 书架和阅读历史；按章节 ID 对照目录，不把上游 `order` 当成目录下标。
较新的本机位置优先，缺目录时保留章节 ID，点书时重新匹配；段内偏移暂不转换。
导入记录保留到用户手动删除（导入历史超过 10000 条时按最旧时间淘汰），备份也保留该标记。本机转换工具见 `scripts/README.md`。

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
- [x] 整本 TXT 导出（离线缓存页每行「导出 TXT」→ 系统「下载」；重取最新目录与每章正文，按后端 `/api/download` 同形组装。取文时可取消且不写文件；进入「正在保存文件」后等待系统回报成功或失败，期间不能取消或返回）
- [ ] **按职责整理 `lib/widgets/video_player_chrome.dart`**（实测 5004 行，其中
      `_VideoPlayerChromeState` 一个类占 4580 行（311–4890），`part` 只切出一份 22 行的横屏进度条）。
      拆的是**职责**不是行数：每一块都改成「传值 + 回调」的无状态 widget，留在同一个 State
      里的只有播放器接线。按「改动收益 ÷ 风险」排序，一次只搬一块，搬完跑相关套件。

      下表的行数是**定义体的实测跨度**（从声明行到方法体结束，命名参数列表与嵌套
      括号不计入），可用 `python` 扫一遍括号配平复核：

      | 顺序 | 目标文件 | 搬什么（实测方法体行数） | 依赖 |
      |---|---|---|---|
      | 1 | `lib/widgets/player/next_episode_card.dart` | `_nextEpisodeCard`（152） | 只读 `widget.*` 与已算好的尺寸 |
      | 2 | `lib/widgets/player/split_layout.dart` | `_buildSplit`（195）、`_splitDivider`（53） | 布局几何，不含播放状态；`_splitCollapsed` 是一对 1 行 getter / 7 行 setter，跟着布局走 |
      | 3 | `lib/widgets/player/side_panels.dart` | `_showSideSettings`（38）、`_sheetSwitch`（21） | 面板选择/档位，需回调上抛；`_rateChipLabel` 只是 1 行的顶层文案函数 |
      | 4 | `lib/widgets/player/gesture_hud.dart` | `_gestureHudOverlay`（72）、`_applyGestureLevel`（35）、`_GestureHudState`/`_GestureKind` | 亮度/音量归一化，纯展示 + 回调 |
      | 5 | `lib/widgets/player/landscape_bar.dart` | `_landscapeBar`（132）、`_topBar`（75）、`_lockButton`（56）、`_landscapeTitle`（38）、`_landText`（25） | 顶/底栏与锁定钮，读多写少 |
      | 6 | `lib/widgets/player/info_panels.dart` | `_information`（75）、`_catalogBar`（69）、`_originalBookCard`（60） | 剧集信息与原著卡，纯展示 |
      | 7（最后） | 原地保留 | `_scheduleHide`（38）、`_positionVideo`（36）、`_listenToPosition`（17）、`_ensurePagerOnCurrent`（14） | 播放器接线：位置流、分页、自动隐藏定时器，跨块共享状态，收益最低 |

      判定标准：搬完后 **该类不再直接读被搬块的私有字段**，且对应测试（`player_*`、
      `video_player_chrome_test`、`playlet_*`）不改断言即通过。达不到就是没降耦合，应回退。


## 正文替换（#120）

规则存于 SharedPreferences 的 reader_text_replacement_v1 版本化 JSON，默认关闭。TextReplacementStore 串行验证/写入后发布不可变快照；写失败不发布。配置页及阅读器排版页共用正文替换入口。

TextReplacementEngine 在独立 isolate 内编译用户正则、预览和逐段转换，执行预算 1 秒，超时或取消时请求立即终止 worker 并释放端口；结果按原文、标题和规则快照复用最近 8 章。上限为 50 条规则、每个匹配/替换字段 2048 个 UTF-16 code units，章节输出不超过 max(65536, 原文文本长度×4)，映射编辑最多 200000 段。正则采用 Dart unicode 模式；替换模板支持 $0、$1…$99、$$。不支持跨段匹配或在替换结果中插入换行。

ChapterContent 原文、legacyText、缓存和导入文件保持原语义。ReaderChapterLayout 消费原文与派生结果，逐段组合编辑映射；历史 positionVersion=2 以及范围划线 start/end 始终保存在未替换的章节坐标中（包含标题/插图占位符/分隔符）。v1 历史先迁移原始布局坐标，再映射到显示位置。选择替换词内部的一部分时，持久化范围向原文匹配区间两侧扩展；整个段落被删除时保留原身份且不绘制，避免后续段评和划线移位。复制使用显示文字。

阅读器首次加载、预取补图/时间轴刷新及规则变化共用转换服务，以章节、原文版本和 generation 拒绝迟到结果；规则与刷新并发时以最新原文重新生成。原始标题去除只执行一次，避免正文被替换成标题后再次被误删。系统 TTS 首章与后续章节均从原文转换，固定同一会话快照；规则保存时关闭旧会话并清理高亮，需重新启动。真人录音不变。

验证：运行 flutter analyze --no-pub 与 flutter test；重点套件为 text_replacement_*、reader_text_replacement、reader_paragraph_actions、reader_chapter_layout、reader_pagination、reader_illustrations、offline_reader 和 system_tts。Android/Windows 的构建与真机超时终止行为仍须在对应环境验收；Linux 主机单测不代表设备或 AOT 验收完成。

### AI 测试台

设置 → 阅读 → AI 阅读优化 → 高级 → AI 测试台。主页面使用全局提供商与模型，
可输入样例正文、编辑本次行为提示词及切换本次去屏蔽词选项；这些编辑不修改全局设置。
请求沿用正文上传授权、预算、用量账本与前台服务，显示流式进度、耗时、Token 用量、
正文预览、修改详情和模型原始响应。测试结果不写入正式章节缓存，不自动重试。
停止或退出测试台会取消请求，进入提示词编辑、请求预览或 JSON 校验子页时保留测试。
结果保留所属请求快照，输入或配置变化后标记为上次结果。

「查看请求」展示 System、User 和输出格式。输出协议优先于用户行为提示词，
用户行为提示词优先于去屏蔽词等可选功能；JSON Schema 字段说明与 JSON 文本协议共用契约。
「更多工具 → JSON 校验」可离线检查原文与模型响应，或带入已完成请求的原文和响应。
WebDAV 配置与诊断由数据同步功能负责。

## Linux / Arch x86_64（实验性运行基础）

支持 Linux runner、bundle 内 Rust 核心、阅读/书架及 TXT/EPUB 本地导入。
听书播放和系统朗读/桌面集成分别见下方第二、三批说明；短剧视频、Android 系统栏、备份文件选择等未实现通道明确报告暂不支持。
第四批提供实验性 Arch 打包脚本与 Linux CI artifact，不提供正式 Release。
构建溯源、安装/卸载、升级回退边界与依赖见 [LINUX.md](LINUX.md)。

Arch 构建依赖：Flutter stable（本批验证 3.47.9 / Dart 3.13.7）、Rust stable
及 x86_64-unknown-linux-gnu target、clang、cmake、ninja、pkgconf、gtk3、libsecret。
运行需要 GTK3、libsecret、glibc（含 iconv）、xdg-user-dirs 和图形会话，
以及已启动且已解锁的 Secret Service（如 GNOME Keyring）。不要用 sudo 运行应用。
媒体构建及运行还需要系统 libmpv（Arch 的 mpv 包），第三批另需 Speech Dispatcher，详见下文。

```bash
flutter pub get
flutter analyze --no-pub
flutter build linux --release --no-pub
./build/linux/x64/release/bundle/fqapp
```

请运行完整 bundle，保留同目录的 data/、lib/；Rust 只从可执行文件旁的
lib/libfqapi_core.so 加载，不依赖启动时的工作目录。不需要手改 FRB 生成文件。
CMake 调用 Cargo --locked 构建 release 核心，首次构建需可用的 pub/Cargo 缓存或网络。

本地资料沿用 path_provider/Hive 的上游目录：Hive 在用户 Documents，
导入书籍和后端在 application support 目录。不要将日常资料目录指向测试目录。
Linux 每个 HOME 只允许一个写者（锁位于 ~/.local/share/fqapp/.writer.lock），
第二个进程返回 23；锁随进程退出释放，不要删除正在使用的锁文件。
密钥服务失败不回落为明文；密钥损坏或现有加密资料无法解密时拒绝替换资料。
请恢复原 keyring 后重试，勿通过删除密钥或资料来解决启动错误。
Linux 密钥操作等待真实完成，避免超时后迟到写与重试产生两个不同密钥；
若 Secret Service 卡住，需要先修复服务，再关闭并重新启动应用。

隔离启动检查应同时设置新的 HOME、XDG_CONFIG_HOME、XDG_DATA_HOME、
XDG_CACHE_HOME、XDG_RUNTIME_DIR，并使用私有 D-Bus 与临时 keyring；仅改 HOME
仍可能连接日常会话的密钥服务。虚拟显示器的启动结果不能替代实际 GPU、
Wayland/X11 桌面、媒体或音频验收。

### Linux 实验性媒体（第二批，依赖 Linux runtime base）

Linux 复用桌面 media_kit 播放器，增加锁定的 media_kit_libs_linux 1.2.1。
需系统 libmpv（Arch 的 mpv 包）；构建时检查库存在，不下载另一套 allocator。
Rust/C CENC 使用 PIC 并与 core 一起构建。FRB 与媒体 FFI 从可执行文件相邻的
绝对 lib/libfqapi_core.so 加载，不依赖启动 cwd。Windows/Android 加载与代理
策略保留；Linux 沿用 reqwest 环境路由，不新增应用代理设置语义。

听书支持普通 URI 与 CENC loopback Range、暂停、seek、倍速和销毁。
关闭窗口在首批刷盘/后端关闭后释放全部播放器；创建期间销毁会关闭迟到会话。
Linux 视频入口仍为 unavailable，等待真实图形播放验证再开放。
TTS、MPRIS、portal、锁屏/挂起恢复与 idle inhibition 不在本批；播放器通知和
保亮请求无系统集成效果。合成媒体 null 输出不证明物理声卡、GPU、Wayland。

离线验证：构建 core 后，以 FQAPP_MEDIA_LIBRARY 指向 bundle 中绝对 core 路径，
运行 python3 scripts/verify_windows_media.py；它复用 Windows 实际 FFI 合成媒体
验证，覆盖本地/HTTP CENC、导出明文字节的音视频帧一致性、随机 Range、安全
边界及会话撤销，只写 build/。然后设置 FQAPP_TEST_MEDIA 为生成的
build/validation/windows-media/decoded.mp4 绝对路径，运行
flutter test --no-pub --concurrency=1 test/desktop_media_playback_test.dart，
验证实际 libmpv 播放、暂停、seek、倍速、完成及释放。

上游完整检查使用 CI；本地运行 flutter analyze --no-pub、上述定向媒体检查及
相关构建，不运行完整 Flutter/Rust 套件。资源受限机器串行执行，
使用 systemd scope 限制 CPU/内存及 CARGO_BUILD_JOBS=2、
CMAKE_BUILD_PARALLEL_LEVEL=2。隔离 HOME/keyring，不读取真实账号/媒体缓存。

真实 Linux engine 接线回归入口：
`flutter build linux --release --no-pub -t test/support/linux_media_runtime.dart`。
在私有 HOME/XDG、D-Bus、Xvfb 和虚拟音频会话内运行生成的 bundle，设置
`FQAPP_RUNTIME_ORIGIN=http://127.0.0.1:<port>`。该本地 HTTP 服务需提供支持 Range 的
8 秒合成 `audio.wav` 和 `encrypted.mp4`（AAC/CENC，测试 key 为
`00112233445566778899aabbccddeeff`）。入口使用真实 LinuxPlatform、NativePlayer、
media_kit 原生纹理插件和 bundle 内 Rust/C 核心，检查创建、实际进度、暂停、seek、
释放后 CENC listener 撤销，再在活跃 CENC 播放中正常关窗；监督进程须检查退出码 0。
它是独立测试 target，不由产品 main 引用。此 bundle 不是产品包；交付前重新构建默认 target。
该测试不证明物理声卡/GPU、完整产品存储关窗链或 Windows/Android 运行通过。

### Linux 系统朗读与桌面集成（第三批）

在前两批上增加 Speech Dispatcher（构建必需 `speech-dispatcher` pkg-config 和 libspeechd 头文件；
Arch 运行包 `libspeechd`、`speech-dispatcher`、中文音源如 `espeak-ng`）。
应用只连接现有 daemon，不自动启动、安装或重配置用户服务。设置页列出真实输出
模块；初始化选择 zh/cmn 语音，无中文语音、连接/设置失败会返回 TTS_ERROR。
rate 以 log2 映射到 Speech Dispatcher 的 -100..100；这不是实测倍速保证。
可选 volume 为 0..1，未设置保留 daemon 默认。pause 取消本客户端队列，
恢复由现有朗读状态机重发当前句；start/done/cancel 按 daemon 消息 ID 映射，
取消后旧回调不得推进正文。SSIP 操作在专用 worker，Flutter 回复/释放回主线程。

Linux 听书、系统朗读使用 owner 标识更新 MPRIS，旧 owner 的清理不能移除新会话；
D-Bus 名已被其他实例持有时报告 MPRIS_OWNER_BUSY，不替换它。
媒体键支持显式 Play/Pause、PlayPause、上下章；有实际 timed seek handler 时才声明
CanSeek。位置来自播放器/朗读状态，不导出封面或含凭据媒体 URL。
Linux 视频入口仍关闭。Android 专用登录、系统栏等能力不假报成功；
Linux reader brightness 尚不可用，返回 unsupported_platform，不伪造硬件亮度。

阅读和播放的常亮需求合并为一个 GTK idle inhibitor；GTK 返回 0 时报告
INHIBIT_UNAVAILABLE，关闭/停止释放 cookie。GTK 通过当前桌面可用后端实现；
不保证每个 compositor 提供 portal/inhibitor。logind LockedHint 仅为提示，
capabilities.lockEvents 恒 false；subscription 不证明锁屏可靠性。
隐藏按现有后台播放偏好处理，suspend 即使允许后台也暂停；仅自动暂停且 owner
未替换、用户未手动暂停的会话可恢复。服务消失不伪造 unlock/resume。
D-Bus 连接关闭后定时重连，logind 名恢复后重订阅；缺服务可诊断。
关闭仍先等待本地初始化和上游刷盘/后端退出，再停止媒体/TTS/idle/session，
保留单写者锁。失去响应的第三方 daemon 仍可能延迟 SSIP 操作和关闭，需修复服务。

单元门：`flutter analyze --no-pub`、`flutter test --no-pub --concurrency=1`。
本批不改 Rust，无需重复 cargo test。native 严格编译示例：

```bash
cmake -S native/linux -B build/native-strict \
  -DFLUTTER_LINUX_DIR="$FLUTTER_ROOT/bin/cache/artifacts/engine/linux-x64" \
  -DCMAKE_CXX_FLAGS="-Wall -Wextra -Werror"
cmake --build build/native-strict -j2
flutter build linux --release --no-pub -t test/support/linux_desktop_runtime.dart
```

独立 runtime target 需私有 HOME/XDG、D-Bus、Xvfb、ALSA null 和 task-owned
Speech Dispatcher，设置 FQAPP_DESKTOP_TEST_ROOT。监督器按该 target 的文件握手：
初始持有 org.mpris.MediaPlayer2.fqapp，disconnect 时仅终止测试 daemon，
reconnect 时重启并写 restarted；release-name 时释放竞争名并写 name-released；
mpris 时查询 metadata/status/position，依次发送 Pause、Play、PlayPause、Seek
(1000000us)、SetPosition(track/1,5000000us) 后写 controls-done；
stale-stop 时确认 Playing 后写 stale-checked；released 时确认无 owner 后写
released-checked。检查 PASS 标记、活跃朗读关窗退出码 0。它验证真实 channel、
SSIP 和 D-Bus，但 null 音频/Xvfb 不证明物理音质、GPU、实际锁屏或挂起。
测试入口不引用产品资料，不是产品包；交付前重新构建默认 target。

仓库内监督器可直接复验真实 D-Bus Rate/Volume 写入、后端确认/失败回复和
PropertiesChanged（Arch 测试依赖另需 `xorg-server-xvfb`、`dbus`、`speech-dispatcher`、`espeak-ng`）：

```bash
python test/linux_desktop_runtime_test.py
# 需 FLUTTER_ROOT 指向同一 SDK；实际 tts.cc 在途回调与析构的 ASan 压力回归：
python test/linux_tts_lifetime_test.py
flutter build linux --release --no-pub -t lib/main.dart
```

GDBusInterfaceVTable 的空 set_property 是 GLib 2.38 起支持的异步属性分发方式，
Properties.Set 会进入 method_call；不能改为同步等待 Dart 而阻塞 GTK 主线程。
官方合同：https://docs.gtk.org/gio/struct.DBusInterfaceVTable.html 。
TTS 回调取 active 指针并入队与析构撤销指针使用同一锁；关闭 libspeechd 前释放此锁，
避免 spd_close 等待其回调线程时死锁。ASan 回归仅在外置编译副本插入调度钩子，
不增加产品测试开关；它不模拟真实 daemon，须与上面的真实协议复验分别报告。

第三批审查修复补充：SSIP 拒绝 CANCEL 时 pause/stop/initialize 报 TTS_ERROR 并关闭连接，
无连接 stop 保持幂等。常亮请求串行提交，失败回滚 reader/player 意图。
MPRIS Volume/Rate 经当前 owner 的实际播放器或 SpeechDispatcher 确认后回复 Set 并发布
PropertiesChanged；读取来自后端设置，不使用独立音量模型。TTS 速率范围 .25..4，
听书页 .75..2，完整音频 controller .5..3，均包含 1；SSIP 整数速率会量化。
Rate=0 复用 Pause 路由，不向后端提交零速率，也不把 Rate 属性写成 0。
非零速率修改先按旧速率结算位置并刷新时间锚点，避免 Position 与相对 Seek 基准跳变。
Seek 越尾按 Next（受 CanGoNext 控制），SetPosition 越尾忽略；旧章节 seek 完成不发新章 Seeked。
runner 在窗口子类 dispose 调用父类前释放 bridge，保留 worker join，不关闭退出诊断。
真实协议回归目标仍为 test/support/linux_desktop_runtime.dart；拒绝 CANCEL 注入由
私有 SSIP 代理执行，ALSA null/Xvfb 的结果不代表物理声音、compositor、锁屏或挂起验收。
