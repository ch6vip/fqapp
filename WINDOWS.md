# fqapp 电脑版

基于 ch6vip/fqapp 的 `762f0b2`，保留 GPL-3.0 许可证和原作者署名。

## 使用

Windows 10/11 x64：解压完整目录后运行 `fqapp.exe`，不要单独移动 EXE。
也可运行 `fqapp-desktop-<版本>-windows-x64-setup.exe` 安装：支持选择安装目录、
开始菜单/桌面快捷方式及卸载，无需管理员权限。卸载保留当前用户的书架、进度和缓存。
首次启动需联网初始化；已下载的书籍及媒体可从应用内离线入口打开。
数据保存在当前用户的应用数据目录，不依赖解压目录。备份使用原版 JSON 格式。
官方网页导入需要 Microsoft Edge WebView2 Runtime，并由用户在官方网页完成登录。
系统朗读使用已安装的 Windows 语音；缺少中文音色时在系统语音设置中安装。

播放器：空格播放/暂停，左右键快退/快进 10 秒，上下键音量，F 全屏，Esc 退出全屏。
推荐流 Page Up/Page Down 切换上一条/下一条。竖片完整显示，两侧留边。
阅读器使用滚轮、方向键或 Page Up/Page Down，宽窗口提供可搜索的侧边目录。
最小化后按后台播放设置继续播放，关闭窗口保存进度并退出。

## 构建和验证

需要 Flutter 3.44.6 / Dart 3.12.2、Rust stable、Visual Studio C++ 桌面工具、NuGet CLI 和 FFmpeg。
执行 `pwsh -File scripts/build_windows.ps1 -FlutterRoot <Flutter SDK 路径>`。
原生 DLL 由 Windows CMake 构建自动调用 Cargo 编译；C 解密核心由 Rust build.rs 编译。
构建脚本对中文工作区使用临时英文目录联接，不移动源码。
Flutter 插件需要开发者模式或符号链接权限；本机 `.tools/flutter` 已使用仅限该工具副本的目录联接兼容处理。
普通构建和 Windows CI 使用官方 Flutter SDK，不要求修改 SDK。
若复现 Flutter 3.44.6 在路由/提示层切换时的 Windows 无障碍树崩溃，
可对专用 SDK 显式使用 `-ApplySemanticsBackport`，或单独运行
`scripts/prepare_flutter_windows.ps1`；出处和回归用例见 `scripts/patches/README.md`。
该可选补丁不会关闭无障碍功能，也不会自动修改共享 SDK。
需要安装版时，在 release 构建和许可证收集完成后执行
`pwsh -File scripts/build_windows_installer.ps1 -IsccPath <Inno Setup 的 ISCC.exe 路径>`。

`python scripts/verify_windows_media.py` 使用真实 Windows DLL、FFmpeg 生成的 CENC 夹具，
核对视频和音频逐帧哈希、在线/离线随机 Range、访问限制和会话关闭。
这些离线测试不代表上游在线内容或用户账号导入已通过真实验收。

`dart compile exe scripts/verify_windows_player.dart -o build/verify_windows_player.exe`
后运行 `build/verify_windows_player.exe`，使用与产品一致的 AOT 模式和随包 libmpv，核对加密媒体的 H264 解码尺寸、
播放/暂停/拖动/续播、倍速和静音；该测试不显示视频窗口，窗口及 GPU 呈现需另行实机验收。

`flutter test integration_test/windows_playback_test.dart -d windows --no-pub --dart-define=FQAPP_TEST_MEDIA=<encrypted.mp4 绝对路径>`
会运行真实 Windows 播放页，验证无键盘焦点时的自动起播、连续推进、暂停、进度条拖动与续播。
夹具由上一条原生播放器校验脚本生成；测试不会读取用户的书架进度作为测试数据。

Windows 适配修复可见但未聚焦的窗口被误判为后台、导致只显示首帧的问题，
并保护窗口销毁时的原生回调，避免退出时再次访问已销毁的 Flutter 视图。
`scripts/verify_windows_shutdown.dart` 是独立的退出回归入口，可用
`flutter build windows --debug --target scripts/verify_windows_shutdown.dart --no-pub`
构建后从工作区启动 Debug 程序；它会自动执行正常关闭回调并退出。
退出检查完成后，交付版本须重新使用默认 `lib/main.dart` 入口构建 release。

Android 保留 ExoPlayer；只引用 `media_kit_libs_windows_video`，不打包 Android
libmpv/FFmpeg 原生库。执行 Flutter 测试后构建 Android release 时，须保留 pub
步骤（不要给 `flutter build apk` 加 `--no-pub`），以清除 dev-only 集成测试注册项。
`.github/workflows/windows.yml` 会在相关 PR 中使用未修改的 SDK 构建并验证
桌面布局与原生媒体解密接口；程序包仅作为 Actions artifact 保存。
额外的无界面 libmpv 诊断由手动参数 `verify_player` 显式启用：
目前托管 Windows Server 2025 在释放播放器时持续出现 `0xC0000005`，尚未解决，
不计为通过。本机交互桌面的播放/销毁及窗口集成检查通过，服务端诊断结果单独记录。

## 第三方组件

沿用 Flutter/Rust/C 架构。Windows 播放采用 media_kit/libmpv，系统媒体控制采用 smtc_windows，
文件选择采用 file_selector，系统朗读采用 flutter_tts，窗口管理采用 window_manager。
WebView2 适配器基于 webview_windows 0.4.0，其 MIT 许可和修改说明保存在 third_party/webview_windows。
原项目及第三方许可证随源码/程序一并保留；Flutter 的许可证页面可查看 Dart 依赖许可。
