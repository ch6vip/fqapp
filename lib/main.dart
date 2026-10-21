import 'services/audio_downloader.dart';
import 'widgets/desktop_app_frame.dart';
import 'services/native_player.dart';
import 'services/desktop_platform.dart';
import 'services/platform_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'pages/home_page.dart';
import 'pages/audio_page.dart';
import 'pages/cached_books_page.dart';
import 'pages/drama_page.dart';
import 'pages/library_page.dart';
import 'pages/mine_page.dart';
import 'services/app_log.dart';
import 'services/encrypted_box_migration.dart';
import 'services/app_theme.dart';
import 'services/audio_download_store.dart';
import 'services/audio_preferences.dart';
import 'services/player_preferences.dart';
import 'services/backend_service.dart';
import 'services/digg_store.dart';
import 'services/drama_download_store.dart';
import 'services/drama_downloader.dart';
import 'services/fair_memory.dart';
import 'services/connectivity_status.dart';
import 'services/home_feed_cache.dart';
import 'services/library_store.dart';
import 'services/rank_cache.dart';
import 'services/player_style_config.dart';
import 'services/short_series_font_scale.dart';
import 'services/playlet_share.dart';
import 'services/poster_cache.dart';
import 'services/shelf_store.dart';
import 'services/swipe_guide_store.dart';
import 'widgets/lazy_indexed_stack.dart';
import 'widgets/home/home_design.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isWindowsDesktop) await DesktopPlatform.instance.initialize();
  // 应用内日志：接管 debugPrint 与 FlutterError.onError，未处理异步异常由
  // runZonedGuarded 捕获；文件持久化异步开启，失败只退回内存模式。
  AppLog.instance.install();
  unawaited(AppLog.instance.startPersistence());
  // 短剧分享的「系统分享」走 Android 的 Intent.ACTION_SEND
  //（官方同一条路径）。桥不可用时 PlayletShare 自动降级为复制链接，
  // 不会把失败说成成功。
  // 插件回 false 表示没能调起选择器（没有可分享的应用），必须原样返回：
  // 「调不起来」与「已分享」是两件事。
  SharePlusLite.handler = ({required title, required text}) async {
    final launched = await const AppMethodChannel(
      'fqapp/share',
    ).invokeMethod<bool>('shareText', {'title': title, 'text': text});
    return launched ?? false;
  };
  // Rust 核心日志的读取入口：日志页「Rust」视图读 runtime_dir/rust.log。
  // 核心只在 Android 落盘（桌面/测试构建不装 logger），读不到时页面给空态。
  RustLogSource.reader = BackendService.instance.readRustLog;
  if (isWindowsDesktop) {
    DesktopPlatform.instance.beforeClose = () async {
      DramaDownloader.instance.pauseAll();
      AudioDownloader.instance.pauseAll();
      await FairMemoryService.instance.flushForExit();
      try {
        await NativePlayer.pauseOthers();
      } catch (_) {}
      try {
        await BackendService.instance.stop();
      } catch (_) {}
      await Hive.close();
    };
  }
  runZonedGuarded(
    () => runApp(const ProviderScope(child: FqApp())),
    (error, stack) => AppLog.e('zone', '未捕获异步异常', error: error, stack: stack),
  );
}

Future<void> _initializeLocalData() async {
  await Hive.initFlutter();
  // 加密存储撤销后的一次性迁移：把老版本落盘的 `<name>_enc` 加密箱搬回
  // 明文箱。迁移器内部逐箱吞错（取不到密钥/解不开就保留原文件跳过），
  // 绝不让本地数据迁移把启动锁死。
  await EncryptedBoxMigration.migrateAll(Hive);
  // 以下初始化互相独立（各开各的 box / 各读各的配置），串行等只会把
  // 磁盘 I/O 叠加到冷启动里；并行发起，失败语义与串行时一致：必需项
  // （书架/历史）失败仍使启动失败，可选项各自吞错退化。
  Future<void> optional(Future<void> Function() run) async {
    try {
      await run();
    } catch (_) {}
  }

  await Future.wait<void>([
    LibraryStore.instance.init(),
    // The 加入书架 collection is optional data: a failure here must not block
    // startup, which is why it shares the retryable bootstrap with the history.
    ShelfStore.instance.init(),
    // 短剧 feed 的 点赞 也是可选本地数据，与书架同一处理：开箱失败不能让
    // 启动失败，否则一个纯装饰性的集合会拖住短剧页之外的所有功能。
    optional(() async {
      await DiggStore.instance.init();
      // DiggStore 自己把「不可用」当成「没有点赞」处理（见 _openBox）。
    }),
    // 「上滑查看更多视频」的一次性标记同样是可选数据：读不到就当没弹过，
    // 弹一次的语义退化成「本次启动弹一次」也不能拖住启动。
    optional(() async {
      await SwipeGuideStore.instance.init();
      // SwipeGuideStore 自己把「不可用」当成「未显示」处理。
    }),
    // 首页 feed 的冷启动缓存也是可选数据：打不开就当没有缓存，
    // 首页退化为先加载再显示，其余行为不变。
    optional(() async {
      HomeFeedCache.hiveReady = true;
      await HomeFeedCache.instance.warmUp();
      // HomeFeedCache 自己把「不可用」当成「没有缓存」处理。
    }),
    // 榜单缓存同理：开箱失败只是退化为每次现拉。
    optional(() async {
      RankCache.hiveReady = true;
      await RankCache.instance.warmUp();
      // RankCache 自己把「不可用」当成「没有缓存」处理。
    }),
    // 官方播放页开关（PlayerBottomStyleConfig / 清屏反转 / 横屏锁）随同一份
    // 运行时配置读取；读不到就用默认值，不能拖住启动。
    PlayerStyleConfig.load(),
    // 官方播放页字号档（jk3/b 的 SP）同理：读失败回标准档，不拖启动。
    ShortSeriesFontScale.load(),
    // 解码器偏好必须先进内存：`NativePlayer.create` 在起播路径上直接读它，
    // 不能在那里再 await 读盘（见 DecoderPreferenceCache 的说明）。
    optional(DecoderPreferenceCache.load),
    // 离线缓存的记录箱启动即打开：播放器的离线命中只在 box 就绪时才查
    // （避免运行中途首次 openBox 失败产生游离异步错误）。可选数据，失败
    // 只退化为「本会话不查离线」。
    optional(HiveDramaDownloadStore.instance.warmUp),
    // 听书音频离线记录箱：与短剧箱分开，同样只在就绪时才查离线命中。
    optional(HiveAudioDownloadStore.instance.warmUp),
  ]);
  // 听书后台播放开关：异步读取 SharedPreferences，失败退化为默认开启。
  unawaited(AudioPreferences.instance.load());
  // 短剧切后台悬浮窗开关（#24）：异步读取，失败退化为默认关闭。
  unawaited(PlayerPreferences.loadFloatingWindow());
  // 离线缓存的网络门（官方 onNetChangeCheck）：断网/只剩计费链路时
  // 自动暂停下载队列，半成品保留。监听失败只退化为「无自动暂停」。
  try {
    Connectivity().onConnectivityChanged.listen((results) {
      final view = foldConnectivity(results);
      DramaDownloader.instance.updateConnectivity(
        online: view.online,
        metered: view.metered,
      );
      AudioDownloader.instance.updateConnectivity(
        online: view.online,
        metered: view.metered,
      );
    });
  } catch (_) {}
  // 海报缓存的字节预算清扫：超额时删最旧的图。失败不影响任何页面。
  unawaited(PosterCache.instance.enforceBudget());
  // 小米澎湃 OS 公平运行内存：注册 TRIM/KILL 通道回调。必须在启动时构造，
  // 否则广播到达时 Dart 侧还没有处理函数，原生侧只能按“未处理”回。
  FairMemoryService.instance.init();
  final sp = await SharedPreferences.getInstance();
  // Note: Optional preference schemas cannot block local data startup; see
  // .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md.
  final savedTheme = sp.get(themeModeKey);
  themeModeNotifier.value = themeModeFromName(
    savedTheme is String ? savedTheme : null,
  );
  // 墨水屏模式与深色模式同为可选偏好：读不到退化为关闭，不拖住启动。
  einkModeNotifier.value = sp.getBool(einkModeKey) ?? false;
}

class FqApp extends StatefulWidget {
  const FqApp({super.key});

  @override
  State<FqApp> createState() => _FqAppState();
}

class _FqAppState extends State<FqApp> {
  final _navigatorKey = isWindowsDesktop
      ? DesktopPlatform.navigatorKey
      : GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: einkModeNotifier,
          builder: (context, eink, _) {
            // 墨水屏强制浅色纯黑白：深色反白在墨水屏上残影最重。
            final effectiveMode = eink ? ThemeMode.light : mode;
            return MaterialApp(
              navigatorKey: _navigatorKey,
              builder: (context, child) => AudioPlaybackScope(
                navigatorKey: _navigatorKey,
                child: isWindowsDesktop
                    ? DesktopAppFrame(child: child ?? const SizedBox.shrink())
                    : child ?? const SizedBox.shrink(),
              ),
              title: 'fqapp',
              debugShowCheckedModeBanner: false,
              theme: _theme(Brightness.light, eink: eink),
              darkTheme: _theme(Brightness.dark, eink: eink),
              themeMode: effectiveMode,
              // 全 App 文案是中文，系统文本菜单（复制/粘贴/全选）与 Material
              // 内置文案也必须跟着中文：缺 delegates 时一律回退英文（#79）。
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: AppBootstrap(
                backendStarter: BackendService.instance.start,
                child: const RootShell(),
              ),
            );
          },
        );
      },
    );
  }

  ThemeData _theme(Brightness brightness, {bool eink = false}) =>
      AppTheme.createTheme(brightness, einkMode: eink);
}

/// Opens local data before any page can access LibraryStore's boxes. Failed
/// initialization is retryable without clearing or replacing the user's data.
/// See .agents/notes/implemented/bug-fix/2026-09-17-reviewed-runtime-boundaries.md.
///
/// When [backendStarter] is provided, the backend starts concurrently with
/// local-data init instead of waiting for it (the two chains are independent:
/// the backend only needs the asset bundle + app dir, never Hive/SharedPrefs
/// stores). The backend future is deliberately NOT awaited here: RootShell
/// awaits the same shared future (BackendService.start is idempotent) and
/// owns backend-error UI. When null (widget tests), no backend starts here.
class AppBootstrap extends StatefulWidget {
  final Widget child;
  final Future<void> Function()? initializer;
  final Future<void> Function()? backendStarter;

  const AppBootstrap({
    super.key,
    required this.child,
    this.initializer,
    this.backendStarter,
  });

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  bool _initializing = false;
  bool _ready = false;
  bool _failed = false;
  Future<void>? _backendFuture;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    if (_initializing || _ready) return;
    setState(() {
      _initializing = true;
      _failed = false;
    });
    // Start the backend before awaiting local data (see class doc): the
    // two chains run concurrently; a retry must not start it twice.
    _backendFuture ??= widget.backendStarter?.call();
    // Attach a no-op error handler so a backend failure is never reported
    // as an unhandled async error if RootShell never mounts to await the
    // same future (e.g. local-data init keeps failing). RootShell awaiting
    // the original future still observes the error.
    unawaited(_backendFuture?.then<void>((_) {}, onError: (_) {}));
    try {
      await (widget.initializer ?? _initializeLocalData)();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _initializing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.child;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_failed)
                  Icon(
                    LucideIcons.triangle_alert,
                    color: Theme.of(context).colorScheme.error,
                  )
                else
                  const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_failed ? '无法读取本地数据' : '正在读取本地数据…'),
                if (_failed) ...[
                  const SizedBox(height: 8),
                  const Text('请检查设备可用空间后重试。', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: _initialize,
                    child: const Text('重试'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RootShell extends StatefulWidget {
  final Future<void> Function()? backendStarter;

  const RootShell({super.key, this.backendStarter});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;
  bool _backendReady = false;
  String? _backendError;

  @override
  void initState() {
    super.initState();
    _startBackend();
  }

  Future<void> _startBackend() async {
    setState(() {
      _backendError = null;
    });
    try {
      await (widget.backendStarter ?? BackendService.instance.start)();
      if (mounted) {
        setState(() => _backendReady = true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _backendError = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_backendReady) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_backendError == null)
                    const CircularProgressIndicator()
                  else
                    Icon(
                      LucideIcons.triangle_alert,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  const SizedBox(height: 16),
                  Text(_backendError == null ? '正在启动本地服务...' : '启动失败'),
                  TextButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CachedBooksPage(),
                      ),
                    ),
                    icon: const Icon(LucideIcons.download),
                    label: const Text('离线阅读'),
                  ),
                  if (_backendError != null) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        _backendError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, color: Colors.red),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _startBackend,
                      child: const Text('重试'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (isWindowsDesktop) {
      return ValueListenableBuilder<int>(
        valueListenable: desktopTab,
        builder: (context, index, _) => LazyIndexedStack(
          index: index,
          children: [
            const HomePage(),
            const DramaPage(),
            LibraryPage(onBrowse: () => desktopTab.value = 0),
            const MinePage(),
          ],
        ),
      );
    }
    final palette = HomePalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDramaTab = _index == 1;
    final glassDark = isDark || isDramaTab;
    // 墨水屏模式：本 build 由 Theme 变化触发重建（上面读了 Theme.of），
    // 这里直接读 notifier 当前值即可拿到最新开关，不另加监听。
    final eink = einkModeNotifier.value;
    final navBar = NavigationBarTheme(
      data: NavigationBarThemeData(
        height: 64,
        elevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        indicatorColor: eink
            ? Colors.black
            : HomePalette.accent.withValues(alpha: glassDark ? 0.20 : 0.12),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? (eink ? Colors.white : HomePalette.accent)
                : (eink
                      ? Colors.black
                      : (glassDark
                            ? Colors.white.withValues(alpha: 0.65)
                            : palette.muted)),
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? (eink
                      ? Colors.black
                      : (glassDark ? HomePalette.accent : palette.accentText))
                : (eink
                      ? Colors.black
                      : (glassDark
                            ? Colors.white.withValues(alpha: 0.65)
                            : palette.muted)),
          ),
        ),
      ),
      child: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          if (i != _index) setState(() => _index = i);
        },
        backgroundColor: Colors.transparent,
        elevation: 0,
        destinations: const [
          NavigationDestination(
            icon: Icon(LucideIcons.house),
            selectedIcon: Icon(LucideIcons.house),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(LucideIcons.clapperboard),
            selectedIcon: Icon(LucideIcons.clapperboard),
            label: '短剧',
          ),
          NavigationDestination(
            icon: Icon(LucideIcons.library_big),
            selectedIcon: Icon(LucideIcons.library_big),
            label: '书架',
          ),
          NavigationDestination(
            icon: Icon(LucideIcons.circle_user_round),
            selectedIcon: Icon(LucideIcons.circle_user_round),
            label: '我的',
          ),
        ],
      ),
    );

    // 静态半透明底：与毛玻璃同色，供短剧 tab 复用（短剧 tab 背后是每帧
    // 变化的视频流，BackdropFilter 每帧重算模糊，GPU 满负荷；该 tab 下
    // 用静态底，外观几乎不变；切出短剧 tab 后恢复毛玻璃）。
    final staticNavBar = Container(
      decoration: BoxDecoration(
        color: glassDark
            ? const Color(0xFF161619).withValues(alpha: 0.72)
            : Colors.white.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: glassDark
              ? Colors.white.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.75),
          width: 0.8,
        ),
      ),
      child: navBar,
    );

    return Scaffold(
      extendBody: true,
      // 状态栏图标亮度挂在壳层、按选中 tab 切换：短剧页是黑底视频流（官方
      // SeriesMallFragment 的透明顶栏直接压在 feed 上），深色图标在黑底上
      // 整条状态栏都看不见，必须浅色；其余三页浅色底用深色。样式放壳层而不是
      // 各页内部，是因为 IndexedStack 里未选中的页不参与绘制，页内
      // AnnotatedRegion 切走后会残留上一个页的样式。
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _index == 1
            ? SystemUiOverlayStyle.light
            : (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark),
        child: LazyIndexedStack(
          index: _index,
          children: [
            const HomePage(),
            const DramaPage(),
            // 空书架上的「去书城找书」切回首页 tab。
            LibraryPage(onBrowse: () => setState(() => _index = 0)),
            const MinePage(),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        left: false,
        right: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: RepaintBoundary(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                // 墨水屏：阴影是灰阶 + 刷新残影来源，直接去掉，改用实线边框。
                boxShadow: eink
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: glassDark ? 0.38 : 0.08,
                          ),
                          blurRadius: 22,
                          offset: const Offset(0, 8),
                        ),
                        BoxShadow(
                          color: HomePalette.accent.withValues(
                            alpha: glassDark ? 0.06 : 0.03,
                          ),
                          blurRadius: 14,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                // 墨水屏：BackdropFilter 毛玻璃会把底部栏变成一团灰，改实色。
                // 短剧 tab：背后是每帧变化的视频流，BackdropFilter 每帧都要
                // 重算模糊，GPU 一直满负荷；该 tab 下改用同色静态半透明底，
                // 外观几乎不变，省掉每帧重栅格化。切出短剧 tab 后恢复毛玻璃。
                child: eink
                    ? Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: Colors.black, width: 0.8),
                        ),
                        child: navBar,
                      )
                    : isDramaTab
                    ? staticNavBar
                    : BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                        child: staticNavBar,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
