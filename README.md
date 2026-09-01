# fqapp — 番茄小说/短剧 Flutter 客户端

一个运行在 **Android 手机本地** 的番茄小说聚合客户端：内置 Go 版 `` 后端（签名、解密全在手机本地完成），Flutter 原生 UI 提供小说阅读、短剧播放、漫画、听书、搜索、收藏、历史等完整功能。

> **核心设计**：后端跑在 `127.0.0.1:8080`，UI 通过 HTTP 调用本地后端。不需要服务器，不需要 root，数据不出手机。

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
| 🖼 漫画 | 内容类型识别（开发中，目录结构已支持） |
| 🎧 听书 | 内容类型识别（开发中） |
| 🔍 搜索 | 跨类型搜索，按 小说/漫画/听书/短剧 分 tab |
| ❤️ 收藏 | 本地持久化（SharedPreferences） |
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
│  │(收藏/历史)│   │(进程管理)   │                 │
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
3. **存储**：收藏/历史走 `LibraryStore`（SharedPreferences JSON）。

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
│   │   └── library_store.dart       # 收藏/历史本地存储
│   ├── pages/
│   │   ├── home_page.dart           # 首页(推荐流)
│   │   ├── search_page.dart         # 搜索(分 tab)
│   │   ├── detail_page.dart         # 详情(简介+目录+收藏)
│   │   ├── reader_page.dart         # 小说阅读器
│   │   ├── player_page.dart         # 短剧播放器(video_player)
│   │   ├── library_page.dart        # 书架(收藏/历史)
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
flutter build apk --debug        # 调试版(169MB, 含全部 ABI)
flutter build apk --release     # 发布版(更小)
```

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
_proc = await Process.start(bin, ['-config', ..., '-pool', ..., '-filter', ...],
    workingDirectory: dir.path, environment: {'HOME': dir.path});
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

> **当前状态**：`Process.start` 方案在真机上报 `Permission denied`，JNI 方案是下一步改造方向（见[开发计划](#开发计划)）。

#### JNI 方案的实际进度：0（尚未开始）

别被 `android/app/src/main/jniLibs/arm64-v8a/liblegacy.so` 误导。实测结论：

- 该文件与 `assets/bin/` **md5 完全相同**，只是可执行文件的字节级拷贝，**不是真正的 shared library**；
- 二进制内搜不到 `JNI_OnLoad`，也搜不到任何 `Java_com_fqapp_*` 导出符号；
- `MainActivity.kt` 至今只有 `class MainActivity : FlutterActivity()`，**没有** `System.loadLibrary("")`。

两者都已加入 `.gitignore`，不随仓库分发。要真正落地 JNI，需要同时补上三件事：

1. Go 侧用 `-buildmode=c-shared` 重新编译，导出 `JNI_OnLoad` / `Java_com_fqapp_fqapp_MainActivity_startBackend`，在后台 goroutine 里起 HTTP server（注意不能再走 `flag.Parse()`，参数要改成从 JNI 传入）；
2. Kotlin 侧 `System.loadLibrary("")` 并调用导出的启动函数；
3. `BackendService` 改为先尝试 JNI 启动，失败再回退 `Process.start`（桌面/调试环境仍可用）。

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
| `id` | `book_id` → `video_id`/`vid`/`series_id`/`id`/`item_id` |
| `kind` | 检测 `video_id`/`vid`/`video_platform` → 短剧；`manga_id`/`comic_id` → 漫画；`album_id`/`audio_book_id` → 听书；否则小说 |
| `title` | `cell_name` → 高亮 → `book_name` → `title`/`name` |
| `cover` | `thumb_url` → `cover`/`cover_url`/`poster` |
| `author` | `author`/`author_name` |
| `badge` | `category`/`type`/`cell_alias`/`card_tips` |
| `ep` | `serial_count`/`item_count`/`episode_count` |

### `Chapter`（目录章节）

`chapterListWithVolume` 格式 → `itemId`/`title`/`volume_name`，按卷分组。

### `SearchTab`（搜索 tab）

`title` + `items[]`，支持嵌套 `video_data` 展开。

---

## 页面说明

### 首页（`home_page.dart`）
- 搜索"推荐"关键词取结果流（后端归一化后取全部 tab 条目）
- 3 列封面网格，下拉刷新

### 搜索（`search_page.dart`）
- 顶部搜索框（回车/图标触发）
- 结果按 tab 用 ChoiceChip 切换

### 详情（`detail_page.dart`）
- 封面 + 标题 + 作者 + 简介
- 目录网格（4 列），卷名分组
- 底部：收藏按钮 + 开始阅读/播放
- 短剧类型 → 播放器；其他 → 阅读器

### 阅读器（`reader_page.dart`）
- 加载章节正文（后端解密后返回纯文本）
- 点左 1/3 上一章、右 1/3 下一章
- 字号调节（16-24）
- 进度写入历史

### 播放器（`player_page.dart`）
- `video_player` 播放后端返回的直链
- 自动连播（播完自动下一集）
- 上/下一集按钮 + 集数指示
- 播放进度定时写入历史

### 书架（`library_page.dart`）
- 收藏 tab：封面网格
- 历史 tab：列表（含进度、集数）
- 清空功能

### 我的（`mine_page.dart`）
- 服务状态（健康检查）
- 后端地址展示

---

## 已知问题与调试

### 1. SELinux 阻止后端进程启动（当前主阻塞）
- **现象**：`ProcessException: Permission denied`
- **验证**：`adb shell run-as com.fqapp.fqapp ./files/backend/ -h` 可执行 → 确认是 app 进程域限制
- **方案**：JNI 化（见上文）

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

---

## 开发计划

- [ ] **JNI 集成后端**：Go c-shared → `liblegacy.so` → `System.loadLibrary` 启动（解决 SELinux）
- [ ] 漫画阅读页（图片平铺/翻页）
- [ ] 听书播放页（音频播放器）
- [ ] 短剧流式播放（后端 `/stream` 路由）
- [ ] 下载/离线缓存
- [ ] 首页真实推荐接口（`/api/v1/recommend/homepage`）
- [ ] Release 签名配置
- [ ] 整本 TXT 导出

---

## 许可

请遵守上游项目许可与相关法律法规，仅限个人学习研究使用。
