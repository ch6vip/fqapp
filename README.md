# fqapp — 番茄小说/短剧 Flutter 客户端

一个运行在 **Android 手机本地** 的番茄小说聚合客户端：内置 Go 版 `` 后端（签名、解密全在手机本地完成），Flutter 原生 UI 提供小说阅读、短剧播放、漫画、听书、搜索、历史等完整功能。

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
| 🏠 首页 | 推荐内容流（走搜索推荐接口） |
| 📱 纯本地 | 旧后端 + 前端全部在手机内运行，无外部服务器 |

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
                        │ Process.start / JNI
                        ▼
              ┌─────────────────────┐
              │   Go  后端      │
              │  (assets/bin/) │
              │  签名 · 解密 · 代理  │
              └─────────┬───────────┘
                        │ HTTPS
                        ▼
              番茄上游 API (fanqie)
```

### 数据流

1. **启动**：`main.dart` → `BackendService.start()` 把 `assets/bin/`（Android arm64 ELF）+ config/filters/web 部署到 app 私有目录 → 启动子进程 → 轮询 `/health` 直到 200。
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
│   │   ├── backend_service.dart     # 旧后端进程管理(部署/启动/健康检查/日志)
│   │   ├── api_client.dart          # 后端 HTTP 客户端(对接 /api/* 桥接层)
│   │   └── library_store.dart       # 历史/阅读时长本地存储
│   ├── pages/
│   │   ├── home_page.dart           # 首页(推荐流)
│   │   ├── search_page.dart         # 搜索(分 tab)
│   │   ├── detail_page.dart         # 详情(简介+目录)
│   │   ├── reader_page.dart         # 小说阅读器
│   │   ├── player_page.dart         # 短剧播放器(video_player)
│   │   ├── library_page.dart        # 书架(阅读历史)
│   │   └── mine_page.dart           # 我的(服务状态)
│   └── widgets/
│       └── media_card.dart          # 封面卡片组件
├── assets/
│   ├── bin/                    # 旧后端二进制(android-arm64, ~16MB)
│   ├── config/                      # config.json / filter.json / device_pool
│   ├── filters/                     # 15 个 JS 过滤脚本(goja 运行时)
│   ├── web/                         # 后端自带 Web UI(浏览器备用)
│   └── plugins/                     # manga_reader / player HTML 插件
├── android/                         # Android 工程(Gradle Kotlin DSL)
├── scripts/
│   ├── build_backend.sh             # 从  源码交叉编译后端 + 同步运行时文件
│   └── build_backend.ps1            # 同上，Windows PowerShell 版
├── test/widget_test.dart            # 冒烟测试
└── pubspec.yaml                     # Flutter 依赖与资源声明
```

> **仓库不含后端二进制**：`assets/bin/`（约 16MB）体积大且可由源码完整重建，已加入
> `.gitignore`。clone 后请先跑 `scripts/build_backend.sh`，否则 APK 里没有后端、本地服务起不来。

---

## 快速开始

### 环境要求

| 工具 | 版本 | 用途 |
|---|---|---|
| Flutter | 3.44+ (stable) | 构建 App |
| Dart SDK | 3.12+ | 随 Flutter |
| Android SDK | 36 (platform) + Build-Tools | 编译 APK |
| Go | 1.26+ | 交叉编译后端二进制 |
| Android NDK | 28.x (可选) | JNI 方案(见下) |

> Windows 下构建注意：Kotlin 增量编译在部分环境会报 `Could not close incremental caches`，已在 `android/gradle.properties` 中关闭（`kotlin.incremental=false`）。

### 1. 编译后端并同步运行时文件

一条命令完成交叉编译 + 配置 / 过滤器 / 网页资源同步：

```bash
./scripts/build_backend.sh                  # 默认把 ../ 当作源码目录
./scripts/build_backend.sh /path/to/   # 或手动指定源码目录
```

Windows PowerShell：

```powershell
.\scripts\build_backend.ps1                 # 默认 ..\
.\scripts\build_backend.ps1 C:\path\to\
.\scripts\build_backend.ps1 -Jni            # 同时编译 Android JNI 库
```

脚本内部做的事等价于下面这段（想手动执行也可以）：

```powershell
cd    # 即  仓库
$env:GOOS="android"; $env:GOARCH="arm64"; $env:CGO_ENABLED="0"
go build -trimpath -ldflags "-s -w" -o ..\fqapp\assets\bin\ .

Copy-Item \filters\*  fqapp\assets\filters\ -Recurse
Copy-Item \web\*      fqapp\assets\web\     -Recurse
Copy-Item \plugins\*  fqapp\assets\plugins\ -Recurse
```

> ⚠️ 脚本只拷贝 `config.json`、`filter.json`、`device_pool.example.json` 三个确定的配置文件，
> **不会**整目录复制 `config/`。真实设备池 `device_pool.json` 里带 `secret_key`，
> 一旦打进 APK 等于把设备凭据发出去；脚本会跳过它并删掉已存在的副本。

### 2. 构建 APK

```powershell
cd fqapp
flutter pub get
# 当前 JNI 后端只提供 arm64-v8a，构建时显式指定目标 ABI
flutter build apk --debug --target-platform android-arm64
flutter build apk --release --target-platform android-arm64
```

生成的 APK 仅支持 `arm64-v8a`；如果要支持 32 位或 x86 设备，需要先为
对应 ABI 编译并打包 `liblegacy.so`。

### 3. 安装运行

```powershell
# 真机 USB 调试连接后
adb install -r build\app\outputs\flutter-apk\app-debug.apk
adb shell am start -n com.fqapp.fqapp/.MainActivity
```

首次启动：App 把后端二进制 + 配置部署到 `files/backend/`，启动进程，健康检查通过后进入主界面（约 1-3 秒）。

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

1. `rootBundle.load('assets/bin/')` → 写入 `files/backend/`
2. `chmod 755` 赋予执行权限
3. 复制 `config.json`、`filter.json`、`device_pool.example.json`
4. 首次启动：把 `device_pool.example.json` 复制为 `device_pool.json`（后端会按需注册真实设备并持久化）
5. 复制 15 个 JS 过滤脚本 + 6 个 Web 页面

### 启动流程（`BackendService.start`）

```dart
// Android: MethodChannel → Kotlin → liblegacy.so (JNI)
// Desktop / JNI 不可用时：
_proc = await Process.start(bin, [
    '-config', ..., '-pool', ..., '-filter', ..., '-runtime-dir', dir.path,
  ], workingDirectory: dir.path);
```

- stdout/stderr 实时写入 `backend.log`（诊断用）
- `_waitHealthy` 每 300ms 轮询 `/health`，超时 15s 抛错
- 进程退出时自动置空 `_proc`（下次 `start()` 可重启）

### ⚠️ SELinux 关键限制（已实测）

| 执行方式 | 结果 |
|---|---|
| Flutter `Process.start`（untrusted_app 域） | ❌ `Permission denied` |
| `adb shell run-as <pkg> ./`（shell 域） | ✅ 可执行 |

**Android 的 `untrusted_app` SELinux 域禁止执行 `app_data_file` 下的二进制**（安全设计）。当前已知的可靠方案：

1. **JNI 方案（推荐）**：Go 用 `-buildmode=c-shared` 编译成 `liblegacy.so` 放入 `android/app/src/main/jniLibs/arm64-v8a/`，Kotlin 侧 `System.loadLibrary("")` 触发 dlopen（`apk_data_file` 域允许）。需要：
   - 安装 NDK（`sdkmanager "ndk;28.2.13676358"`）
   - Go 代码改造：`main` 逻辑移到导出的 `JNI_OnLoad` 或 `Java_...` 函数，在后台 goroutine 启动 HTTP server
2. **Termux 思路**：把二进制放到 Termux 环境（`~/.termux` 域）——不适用本项目（无 Termux 依赖）。
3. **Root 设备**：`su -c` 提权执行——不推荐，违背"免 root"设计。

> **当前状态**：JNI 路径已经实现。`BackendService` 在 Android 上先加载
> `liblegacy.so`，桌面或 JNI 不可用时才回退 `Process.start`。由于 Android
> SELinux 限制，真机发布包应使用 arm64 JNI 构建：

```powershell
.\scripts\build_backend.ps1 -Jni
```

Go JNI 入口会使用配置文件推导运行目录，静态页面、过滤器和 `src/` 均按绝对路径加载；HTTP 服务只绑定 `127.0.0.1`。

---

## API 对接说明

App 通过 `ApiClient` 调用后端 **`/api/*` 桥接层**（`webui.go`），响应已归一化，无需解析番茄原始格式：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/search?source=番茄&query=&page=` | 搜索（返回 `{code,message,data:{search_tabs:[{title,data:[]}]}}`） |
| GET | `/api/detail?source=番茄&book_id=&tab=` | 详情（tab=听书 走有声详情） |
| GET | `/api/directory?source=番茄&book_id=&tab=` | 目录（短剧走剧集；输出 `chapterListWithVolume` 格式） |
| GET | `/api/content?source=番茄&item_id=&tab=` | 正文（小说/漫画/听书/短剧分发） |
| GET | `/api/resolve?url=` | 分享链接解析 |
| GET | `/api/download?source=番茄&book_id=` | 整本 TXT 下载 |
| GET | `/health` | 健康检查（返回设备池数量） |

**响应信封**：成功 `{code:200, message:"success", data:...}`；错误 `{code:非200, message:...}`。

**搜索 tab 归一化**：后端把"综合"tab 的数据复制到 书籍/漫画/听书/短剧 各 tab（`normalizeSearchTabs`），App 直接按 tab 展示。

---

## 数据模型

### `MediaItem`（归一化条目）

`MediaItem.fromRaw()` 兼容番茄 API 的各种字段形状（参考 早期前端 `norm()`）：

| 字段 | 来源优先级 |
|---|---|
| `id` | 小说/漫画/听书使用内容 ID；短剧优先使用系列 `pseries_id`/`series_id`，单集结果保留 `episodeId` |
| `kind` | 检测显式 `kind` 及 `video_id`/`vid`/`video_platform` → 短剧；`manga_id`/`comic_id` → 漫画；`album_id`/`audio_book_id` → 听书；否则小说 |
| `title` | `cell_name` → 高亮 → `book_name` → `title`/`name` |
| `cover` | `thumb_url` → `cover`/`cover_url`/`poster` |
| `author` | `author`/`author_name` |
| `badge` | `category`/`type`/`cell_alias`/`card_tips` |
| `ep` | `serial_count`/`item_count`/`episode_count` |

### `Chapter`（目录章节）

`chapterListWithVolume` 格式 → `itemId`/`title`/`volume_name`，按卷分组。

短剧上游的 `data.episodes`、`item_data_list` 和 `lists` 也会统一转换为同一模型，客户端因此可以兼容新旧后端二进制。

### `SearchTab`（搜索 tab）

`title` + `items[]`，支持嵌套 `video_data` 展开。

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
- 加载章节正文（后端解密后返回纯文本）
- 左右点击先滚动一屏，到章节边界才换章；中间点击显示或隐藏控制栏
- 字号、字重、行距、段距、边距和阅读主题实时预览并保存
- 目录支持搜索、倒序、当前章定位与缓存标记
- 章节、滚动位置和封面写入历史，重新进入可续读
- 正文和目录自动保存到磁盘，底部“缓存”可下载后续 20/50/100 章并随时停止
- 缓存上限为 500 章或 80 MB，超出后清理较久未读的章节

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

### 1. JNI 构建与真机验证
- **现象**：`ProcessException: Permission denied`
- **验证**：`adb shell run-as com.fqapp.fqapp ./files/backend/ -h` 可执行 → 确认是 app 进程域限制
- **方案**：执行 `scripts/build_backend.ps1 -Jni`，安装 arm64 APK 后验证 `/health`。
- `liblegacy.so` 和 `assets/bin/` 均为可重建产物，默认不入库；发布构建机必须先执行脚本。

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
- [ ] 短剧流式播放（当前加密视频仍需先下载解密；已支持本地 Range）
- [ ] 漫画阅读页（图片平铺/翻页）
- [ ] 听书播放页（音频播放器）
- [x] 小说章节下载/离线缓存
- [ ] Release 签名配置
- [ ] 整本 TXT 导出

---

## 许可

请遵守上游项目许可与相关法律法规，仅限个人学习研究使用。
