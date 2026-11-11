import 'services/audio_downloader.dart';
import 'widgets/desktop_app_frame.dart';
import 'services/native_player.dart';
import 'services/desktop_platform.dart';
import 'services/platform_capabilities.dart';
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
import 'services/linux_platform.dart';

import 'pages/home_page.dart';
import 'pages/audio_page.dart';
import 'pages/cached_books_page.dart';
import 'pages/drama_page.dart';
import 'pages/library_page.dart';
import 'pages/mine_page.dart';
import 'pages/theme_page.dart';
import 'services/app_log.dart';
import 'services/app_theme.dart';
import 'services/app_theme_style.dart';
import 'services/api_client.dart';
import 'services/ai_reading/ai_controller.dart';
import 'services/webdav_sync_service.dart';
import 'services/audio_download_store.dart';
import 'services/audio_floating_routes.dart';
import 'services/drama_cache_preferences.dart';
import 'services/audio_preferences.dart';
import 'services/player_preferences.dart';
import 'services/player_layout_preferences.dart';
import 'services/backend_service.dart';
import 'services/network_proxy_preferences.dart';
import 'services/digg_store.dart';
import 'services/drama_channel_preferences.dart';
import 'services/drama_download_store.dart';
import 'services/drama_downloader.dart';
import 'services/fair_memory.dart';
import 'services/connectivity_status.dart';
import 'services/home_feed_cache.dart';
import 'services/haptic_preferences.dart';
import 'services/library_store.dart';
import 'services/legacy_ui_notice.dart';
import 'services/rank_cache.dart';
import 'services/player_style_config.dart';
import 'services/short_series_font_scale.dart';
import 'services/playlet_share.dart';
import 'services/poster_cache.dart';
import 'services/shelf_group_store.dart';
import 'services/shelf_store.dart';
import 'services/shelf_view_store.dart';
import 'services/swipe_guide_store.dart';
import 'services/third_party_licenses.dart';
import 'widgets/lazy_indexed_stack.dart';
import 'widgets/app_ui/app_ui_scope.dart';
import 'widgets/shell_dock.dart';
import 'widgets/unsupported_feature_page.dart';
import 'widgets/home/home_design.dart';

Future<void> main() async {
  // 绑定初始化与 runApp 必须处在同一个 Zone：此前 `ensureInitialized` 在
  // Zone 外、`runApp` 在 `runZonedGuarded` 里，Flutter 每次冷启动都会断言
  // 「Zone mismatch」并把它当成框架异常抛出来（真机 app.log 每次启动一条
  // `[E] framework: Zone mismatch`，2026-10-25），把真正的异常淹没在启动
  // 噪声里。因此整条启动流程收进同一个受保护的 Zone。
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // 装配失败不许挡住界面：记一条错误后照常 runApp，各页面自行退化。
    try {
      await _prepareRuntime();
    } catch (error, stack) {
      AppLog.e('main', '启动装配失败，继续挂载界面', error: error, stack: stack);
    }
    runApp(const ProviderScope(child: FqApp()));
  }, (error, stack) => AppLog.e('zone', '未捕获异步异常', error: error, stack: stack));
}

/// `runApp` 之前的运行时装配：桌面窗口回调、应用内日志、分享与 Rust 日志的桥。
/// 这些都不决定界面能不能起来，所以失败只记日志（见 [main]）。
Future<void> _prepareRuntime() async {
  registerPortedUiLicenses();
  if (isLinuxDesktop) await LinuxPlatform.install();
  if (isWindowsDesktop) await DesktopPlatform.instance.initialize();
  // 应用内日志：接管 debugPrint 与 FlutterError.onError，未处理异步异常由
  // [main] 的 runZonedGuarded 捕获；文件持久化异步开启，失败只退回内存模式。
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
  if (isWindowsDesktop || isLinuxDesktop) {
    DesktopPlatform.instance.beforeClose = LinuxPlatform.beforeClose = () async {
      DramaDownloader.instance.pauseAll();
      AudioDownloader.instance.pauseAll();
      await FairMemoryService.instance.flushForExit();
      try {
        if (isMediaDesktop) await NativePlayer.pauseOthers();
      } catch (error, stack) {
        // 退出路径继续往下走，但失败要留痕：否则「关闭后还有声音」无从查起。
        AppLog.w('exit', '退出前暂停播放器失败', error: error, stack: stack);
      }
      try {
        await BackendService.instance.stop();
      } catch (error, stack) {
        AppLog.w('exit', '退出前停止后端失败', error: error, stack: stack);
      }
      await Hive.close();
    };
  }
}

Future<void> _initializeLocalData() {
  final initialization = _loadLocalData();
  if (isLinuxDesktop) LinuxPlatform.localDataInitialization = initialization;
  return initialization;
}

Future<void> _loadLocalData() async {
  await Hive.initFlutter();
  // 以下初始化互相独立（各开各的 box / 各读各的配置），串行等只会把
  // 磁盘 I/O 叠加到冷启动里；并行发起，失败语义与串行时一致：必需项
  // （书架/历史）失败仍使启动失败，可选项各自吞错退化。
  Future<void> optional(Future<void> Function() run) async {
    try {
      await run();
    } catch (error, stack) {
      // 可选项失败时启动照常继续，但必须留下可检索的记录，否则一个永远
      // 打不开的可选 box 会以「某功能默默不生效」的形式表现出来。
      AppLog.w('startup', '可选本地数据初始化失败，已跳过', error: error, stack: stack);
    }
  }

  await Future.wait<void>([
    // Load before interactive pages mount, so a saved opt-out applies at launch.
    optional(HapticPreferences.instance.load),
    LibraryStore.instance.init(),
    // The 加入书架 collection is optional data: a failure here must not block
    // startup, which is why it shares the retryable bootstrap with the history.
    ShelfStore.instance.init(),
    // 书架分组与视图偏好都在书架数据之后装配：页面首帧就能读到版式，
    // 分组只在就绪后参与筛选（未就绪时读 API 安全降级）。两者都是可选数据，
    // 打不开时页面退化为「全部 / 默认版式」而不是拖住启动。
    optional(ShelfGroupStore.instance.init),
    optional(ShelfViewStore.instance.load),
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
    // AI 设置/缓存/反馈箱：失败只让 AI 功能退化，不能拖住阅读。
    optional(AiReadingController.instance.init),
  ]);
  // WebDAV 为可选功能；网络或安全存储故障不阻塞本机阅读。
  unawaited(optional(WebDavSyncService.instance.init));
  // 听书后台播放开关：异步读取 SharedPreferences，失败退化为默认开启。
  unawaited(AudioPreferences.instance.load());
  // 短剧「边看边往后缓存」的开关与集数：同一条装配链里读，避免播放页
  // 起来时还没加载完、拿默认值把用户关掉的开关又打开。
  unawaited(DramaCachePreferences.instance.load());
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
  } catch (_) {
    // 监听连通性只为自动暂停下载；拿不到不构成启动失败，但值得留一条记录，
    // 否则「断网没自动暂停」会被当成下载器自己的 bug。
    AppLog.w('startup', '连通性监听注册失败，自动暂停下载不可用');
  }
  // 海报缓存的字节预算清扫：超额时删最旧的图。失败不影响任何页面。
  unawaited(PosterCache.instance.enforceBudget());
  // 小米澎湃 OS 公平运行内存：注册 TRIM/KILL 通道回调。必须在启动时构造，
  // 否则广播到达时 Dart 侧还没有处理函数，原生侧只能按“未处理”回。
  FairMemoryService.instance.init();
  final sp = await SharedPreferences.getInstance();
  await AppThemeStyleStore.instance.load();
  // Note: Optional preference schemas cannot block local data startup; see
  // .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md.
  final savedTheme = sp.get(themeModeKey);
  themeModeNotifier.value = themeModeFromName(
    savedTheme is String ? savedTheme : null,
  );
  // 墨水屏模式与深色模式同为可选偏好：读不到退化为关闭，不拖住启动。
  einkModeNotifier.value = sp.getBool(einkModeKey) ?? false;
  // OLED 纯黑与墨水屏互斥；两个旧值同时为 true 时墨水屏优先。
  oledModeNotifier.value = sp.getBool(oledModeKey) ?? false;
  // 播放页布局（短剧上下分屏/左右分栏）同样是可选偏好：读不到退化为
  // 沉浸式，不阻塞启动。
  PlayerLayoutPreferences.mode.value = PlayerLayoutPreferences.decode(
    sp.getString(PlayerLayoutPreferences.key),
  );
  // 短剧分区上次停在哪个频道（官方 SP `last_tab_type`）：同样只读一次，
  // 页面在 initState 同步取用，首帧不会先闪「推荐」。
  DramaChannelPreferences.load(sp);
}

class FqApp extends StatefulWidget {
  const FqApp({
    super.key,
    this.initializer,
    this.backendStarter,
    this.styleStore,
  });

  /// Test seams for the real production tree. Production leaves them null:
  /// startup uses [_initializeLocalData] and the real backend, and appearance
  /// reads the device-wide [AppThemeStyleStore.instance].
  @visibleForTesting
  final Future<void> Function()? initializer;
  @visibleForTesting
  final Future<void> Function()? backendStarter;
  @visibleForTesting
  final AppThemeStyleStore? styleStore;

  @override
  State<FqApp> createState() => _FqAppState();
}

class _FqAppState extends State<FqApp> {
  AppThemeStyleStore get _styleStore =>
      widget.styleStore ?? AppThemeStyleStore.instance;
  // Official tabbar + 18dp applies on every page. Our floating dock is 64
  // high with an 8px gap; the desktop shell has no bottom bar.
  final _audioRoutes = AudioFloatingRoutes(
    defaultBottomInset: isWindowsDesktop ? 0 : 72,
  );
  // Desktop fullscreen reparents the content; keep the playback owner alive.
  final _audioScopeKey = GlobalKey();
  final _navigatorKey = isWindowsDesktop
      ? DesktopPlatform.navigatorKey
      : GlobalKey<NavigatorState>();
  final _localDataReady = Completer<void>();

  Future<void> _initializeData() async {
    await (widget.initializer ?? _initializeLocalData)();
    if (!_localDataReady.isCompleted) _localDataReady.complete();
  }

  Future<RecentListen?> _loadRecentListenWhenReady() async {
    // Keep the Navigator and playback owner mounted during startup/retries,
    // but read history only after the local stores have opened successfully.
    await _localDataReady.future;
    if (!mounted) return null;
    return loadRecentListen();
  }

  @override
  void dispose() {
    if (!_localDataReady.isCompleted) _localDataReady.complete();
    BackendService.instance.cancelStartupTimeout();
    _audioRoutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: einkModeNotifier,
          builder: (context, eink, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: oledModeNotifier,
              builder: (context, oled, _) {
                // 墨水屏强制浅色纯黑白：深色反白在墨水屏上残影最重。
                final effectiveMode = eink ? ThemeMode.light : mode;
                return ValueListenableBuilder<AppThemeStyle>(
                  valueListenable: _styleStore,
                  builder: (context, style, _) => MaterialApp(
                    navigatorKey: _navigatorKey,
                    navigatorObservers: [_audioRoutes],
                    builder: (context, child) {
                      final palette = HomePalette.of(context);
                      final playback = AudioPlaybackScope(
                        key: _audioScopeKey,
                        navigatorKey: _navigatorKey,
                        recentListen: _loadRecentListenWhenReady,
                        child: child ?? const SizedBox.shrink(),
                      );
                      // One live presentation scope above the root Navigator,
                      // so pushed routes, nested Navigators and every Overlay
                      // entry read the same discrete style. It is installed in
                      // the builder (not in a page) on purpose; see
                      // [AppUiScope].
                      return AppUiScope(
                        store: _styleStore,
                        child: AnnotatedRegion<SystemUiOverlayStyle>(
                          // Routes without an AppBar need a live fallback above
                          // the Navigator; the covered root route cannot paint
                          // its style. Reader/video annotations still override
                          // this default.
                          value:
                              (palette.dark
                                      ? SystemUiOverlayStyle.light
                                      : SystemUiOverlayStyle.dark)
                                  .copyWith(
                                    statusBarColor: palette.canvas,
                                    systemNavigationBarColor: palette.canvas,
                                    systemNavigationBarDividerColor:
                                        palette.canvas,
                                    systemNavigationBarIconBrightness:
                                        palette.dark
                                        ? Brightness.light
                                        : Brightness.dark,
                                  ),
                          child: AudioFloatingRouteScope(
                            routes: _audioRoutes,
                            child: isWindowsDesktop
                                ? DesktopAppFrame(child: playback)
                                : playback,
                          ),
                        ),
                      );
                    },
                    title: '什锦铺',
                    debugShowCheckedModeBanner: false,
                    // OLED 纯黑只在深色下生效（浅色时 createTheme 直接忽略）。
                    theme: _theme(
                      Brightness.light,
                      eink: eink,
                      oled: oled,
                      style: style,
                    ),
                    darkTheme: _theme(
                      Brightness.dark,
                      eink: eink,
                      oled: oled,
                      style: style,
                    ),
                    themeMode: effectiveMode,
                    // 全 App 文案是中文，系统文本菜单（复制/粘贴/全选）与 Material
                    // 内置文案也必须跟着中文：缺 delegates 时一律回退英文（#79）。
                    locale: const Locale('zh', 'CN'),
                    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
                    localizationsDelegates:
                        GlobalMaterialLocalizations.delegates,
                    home: AppBootstrap(
                      backendStarter:
                          widget.backendStarter ??
                          BackendService.instance.start,
                      initializer: _initializeData,
                      child: RootShell(backendStarter: widget.backendStarter),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  ThemeData _theme(
    Brightness brightness, {
    bool eink = false,
    bool oled = false,
    AppThemeStyle style = AppThemeStyle.archive,
  }) => AppTheme.createTheme(
    brightness,
    einkMode: eink,
    oledMode: oled,
    style: style,
  );
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
      // 这里不写日志：启动失败发生在持久化开启之前，而 AppLog 的写入会排到
      // 那条尚未完成的 I/O 之后（test/app_bootstrap_test.dart 的失败路径用例
      // 因此会挂到超时）。失败本身已经由界面的重试入口与 runZonedGuarded 呈现。
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

class _RootShellState extends State<RootShell> with TickerProviderStateMixin {
  int _index = 0;
  bool _backendReady = false;
  bool _legacyNoticeScheduled = false;

  /// 页面滑动过渡动画：dock 点击 / 拖动松手 / 页面回调统一经 [_selectTab]
  /// 驱动。页面用 Stack + Transform.translate 按动画值平移（与 PageView
  /// 的滑动观感一致），但挂载时机完全可控——首次访问的目标页先在静止帧
  /// 挂载完，再启动滑动，页面构建不会冻住滑动中的 dock 高亮。
  late final AnimationController _pageMotion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..value = 1;

  /// 滑动动画的起点页码（可为小数：打断上一次动画时从当前显示位置继续）。
  double _pageFrom = 0;

  /// 首次访问延迟挂载的目标页：静止帧里先挂载（不 Offstage 但 Transform
  /// 放在屏外），挂载帧结束后清除并启动滑动。
  int? _premount;

  /// 预挂载世代令牌：每次实际切换自增，使待执行的预挂载 post-frame 回调
  /// 失效——同帧多次选择时只有最新一次生效，过期回调不得覆盖 _index。
  int _premountGeneration = 0;

  /// 已挂载过的 tab。未访问的页不进 Stack，避免跨多页切换把沿途页面
  /// （短剧视频流等）全部提前挂载。
  final Set<int> _visitedTabs = {0};

  /// 页面 widget 缓存：避免 AnimatedBuilder 每帧重建 widget 对象。
  /// State 由框架保活，缓存的 widget 只是配置描述，不影响主题等
  /// inherited 依赖的正常更新。
  final Map<int, Widget> _tabCache = {};

  /// 首页 feed 的滚动控制器，由壳层持有以便底部栏触发回顶部。
  final ScrollController _homeScroll = ScrollController();

  /// 上一次「重复点击底部首页 tab」的时间，用于 800ms 防抖。
  ///
  /// 官方对重复点击用 `throttleFirst(800L, MILLISECONDS)`
  /// （BookshelfVideoMultiTabFragment.java:101）。
  DateTime? _lastHomeTabRepeatAt;

  /// 底部 tab 被选中。重复点当前 tab 时回到首页顶部。
  ///
  /// 官方把它放在底部栏而不是页内：`onBottomTabRepeatClick()` 转发到当前
  /// fragment，最终是 `scrollToPosition(0)`（BookshelfVideoTabFragment.java:247）。
  /// 首页头部是普通 sliver（不是折叠 AppBar），把 offset 归零即等价，吸顶的
  /// 分类栏会自己重新吸住。
  void _selectTab(int index) {
    if (index != _index) {
      // 任何实际切换都使待执行的预挂载回调失效，防止过期回调覆盖新选择。
      final generation = ++_premountGeneration;
      if (_visitedTabs.contains(index) ||
          einkModeNotifier.value ||
          MediaQuery.disableAnimationsOf(context)) {
        // 已访问过 / eink / 减弱动态效果：目标页已挂载（或不需要动画），
        // 直接切换，不走预挂载帧。
        final from = _currentPage();
        setState(() {
          _index = index;
          _premount = null;
          _visitedTabs.add(index);
        });
        _startPageMotion(from, index);
        return;
      }
      // 首次访问：先在静止帧把目标页挂载完（不 Offstage 但 Transform
      // 放在屏外，页面还停在旧 tab、dock 高亮未动），挂载帧结束后再
      // 同步启动页面滑动与 dock 弹簧。页面构建的开销发生在动画开始前
      // 而不是滑动中段，dock 高亮不会被冻结在中途项上再跳变。
      setState(() {
        _visitedTabs.add(index);
        _premount = index;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _premountGeneration) return;
        final from = _currentPage();
        setState(() {
          _index = index;
          _premount = null;
        });
        _startPageMotion(from, index);
      });
      return;
    }
    if (index != 0) return; // 只有首页有 feed 需要回顶
    final now = DateTime.now();
    final last = _lastHomeTabRepeatAt;
    if (last != null && now.difference(last).inMilliseconds < 800) return;
    _lastHomeTabRepeatAt = now;
    if (!_homeScroll.hasClients) return;
    // 官方是瞬间跳转（scrollToPosition(0)），没有动画。
    _homeScroll.jumpTo(_homeScroll.position.minScrollExtent);
  }

  /// 启动页面滑动：与 dock 高亮的弹簧滑动同帧开始、同起同终。
  /// [from] 必须在 setState 改变 [_index] 之前捕获（否则起点=终点，
  /// 动画无效）。eink / 系统减弱动态效果不做动画，直接落位。
  void _startPageMotion(double from, int index) {
    if (einkModeNotifier.value || MediaQuery.disableAnimationsOf(context)) {
      _pageMotion.value = 1;
      _pageFrom = index.toDouble();
      return;
    }
    _pageFrom = from;
    _pageMotion.forward(from: 0);
  }

  /// 当前显示的连续页码（动画中为小数，静止时等于 [_index]）。
  double _currentPage() =>
      _pageFrom +
      (_index - _pageFrom) * Curves.easeOutCubic.transform(_pageMotion.value);

  Widget _tabChild(int index) =>
      _tabCache.putIfAbsent(index, () => _buildTabChild(index));

  Widget _buildTabChild(int index) {
    switch (index) {
      case 0:
        return HomePage(
          scrollController: _homeScroll,
          cueLoader: ApiClient.instance.searchCue,
        );
      case 1:
        // iOS 首版没有原生播放器实现：把短剧页换成「暂不支持」占位，
        // 避免进入播放页时触发缺失的 fqapp/native_player 通道。
        return supportsVideoPlayback
            ? const DramaPage()
            : const UnsupportedFeaturePage(
                icon: LucideIcons.clapperboard,
                title: '短剧暂不支持',
                description: '当前平台没有内置视频播放器。搜书、书架和阅读可以正常使用。',
              );
      case 2:
        // 空书架上的「去书城找书」切回首页 tab；收藏空态的「找短剧」
        // 切到短剧 tab。
        return LibraryPage(
          onBrowse: () => _selectTab(0),
          onFindDrama: () => _selectTab(1),
        );
      default:
        return const MinePage();
    }
  }

  String? _backendError;

  @override
  void initState() {
    super.initState();
    // 短剧频道在推荐（视频流）与浅色页之间切换时，悬浮 dock 和系统导航栏
    // 要跟着换肤，所以停在壳层的 build 里监听。
    dramaLightPageNotifier.addListener(_onDramaChromeChanged);
    _pageMotion.addStatusListener(_onPageMotionStatus);
    _startBackend();
  }

  void _onDramaChromeChanged() {
    if (mounted) setState(() {});
  }

  /// 页面滑动动画结束时触发一次 rebuild：让 dock 恢复 BackdropFilter
  /// 实时模糊（动画期间跳过了模糊以避免逐帧全屏高斯开销）。
  void _onPageMotionStatus(AnimationStatus status) {
    if ((status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) &&
        mounted) {
      setState(() {});
    }
  }

  Future<void> _startBackend() async {
    setState(() {
      _backendError = null;
    });
    try {
      await (widget.backendStarter ?? BackendService.instance.start)();
      if (mounted) {
        setState(() => _backendReady = true);
        _scheduleLegacyUiNotice();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _backendError = '$e';
        });
      }
    }
  }

  void _scheduleLegacyUiNotice() {
    if (_legacyNoticeScheduled) return;
    _legacyNoticeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_maybeShowLegacyUiNotice());
    });
  }

  Future<void> _maybeShowLegacyUiNotice() async {
    if (!mounted || !await LegacyUiNotice.shouldShow()) return;
    if (!mounted) return;
    // Mark before showing: if the process is killed while the dialog is on
    // screen, the next launch must not show it again.
    await LegacyUiNotice.markSeen();
    if (!mounted) return;
    final goToTheme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('界面UI已升级'),
        content: const Text('新版默认使用档案界面。想继续使用经典界面，可以到「设置 → 主题」切换。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('知道了'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (!mounted || goToTheme != true) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ThemePage()));
  }

  Future<void> _retryWithDirectConnection() async {
    setState(() => _backendError = null);
    try {
      await NetworkProxyPreferences.instance.save(const NetworkProxyConfig());
      if (mounted) await _startBackend();
    } catch (_) {
      if (mounted) setState(() => _backendError = '代理配置保存失败，请重试。');
    }
  }

  @override
  void dispose() {
    dramaLightPageNotifier.removeListener(_onDramaChromeChanged);
    _pageMotion.removeStatusListener(_onPageMotionStatus);
    _homeScroll.dispose();
    _pageMotion.dispose();
    super.dispose();
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
                    if (isWindowsDesktop)
                      TextButton(
                        onPressed: _retryWithDirectConnection,
                        child: const Text('重置代理为直连并重试'),
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
        builder: (context, index, _) {
          AudioFloatingRouteScope.configure(context, hidden: index == 1);
          return LazyIndexedStack(
            index: index,
            children: [
              HomePage(cueLoader: ApiClient.instance.searchCue),
              const DramaPage(),
              LibraryPage(
                onBrowse: () => desktopTab.value = 0,
                onFindDrama: () => desktopTab.value = 1,
              ),
              const MinePage(),
            ],
          );
        },
      );
    }
    AudioFloatingRouteScope.configure(context, hidden: _index == 1);
    final palette = HomePalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDramaTab = _index == 1;
    // 短剧的推荐频道压在全屏视频流上，dock 用深色玻璃；看剧/漫剧/最近/收藏
    // 是浅色页，dock 跟主题走，否则浅色外观下页面是奶白、dock 还是黑的。
    final dramaOnVideo = isDramaTab && !dramaLightPageNotifier.value;
    // 系统导航栏（Android 底部系统自绘的那条）按当前画布取色。Flutter 的
    // light / dark 两套预设都把它写成纯黑底 + 白图标，浅色页面下会在最底部
    // 留一条突兀的黑带；短剧只有视频流（推荐）背后是视频，仍用黑。
    final lightSystemIcons = dramaOnVideo || isDark;
    return Scaffold(
      extendBody: true,
      // 状态栏图标亮度挂在壳层、按选中 tab 切换：短剧页是黑底视频流（官方
      // SeriesMallFragment 的透明顶栏直接压在 feed 上），深色图标在黑底上
      // 整条状态栏都看不见，必须浅色；其余三页浅色底用深色。样式放壳层而不是
      // 各页内部，是因为 IndexedStack 里未选中的页不参与绘制，页内
      // AnnotatedRegion 切走后会残留上一个页的样式。
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value:
            (lightSystemIcons
                    ? SystemUiOverlayStyle.light
                    : SystemUiOverlayStyle.dark)
                .copyWith(
                  // 状态栏显式铺成画布色：透明状态栏在 Android 10+ 会被系统
                  // 叠一层对比度黑纱，奶白画布会被压成灰带。短剧视频流仍透明。
                  statusBarColor: dramaOnVideo
                      ? Colors.transparent
                      : palette.canvas,
                  systemNavigationBarColor: dramaOnVideo
                      ? Colors.black
                      : palette.canvas,
                  systemNavigationBarDividerColor: dramaOnVideo
                      ? Colors.black
                      : palette.canvas,
                  systemNavigationBarIconBrightness: lightSystemIcons
                      ? Brightness.light
                      : Brightness.dark,
                ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return AnimatedBuilder(
              animation: _pageMotion,
              builder: (context, _) {
                final page = _currentPage();
                return Stack(
                  key: const ValueKey('root-page-stack'),
                  fit: StackFit.expand,
                  children: [
                    for (var i = 0; i < 4; i++)
                      if (_visitedTabs.contains(i))
                        KeyedSubtree(
                          key: ValueKey('root-tab-$i'),
                          child: Offstage(
                            key: ValueKey('root-tab-offstage-$i'),
                            // 静止时只显示当前页；预挂载帧额外显示目标页
                            // （Transform 放在屏外，完成 layout 但不显示）；
                            // 动画中显示视口范围内的页（旧页滑出 + 新页滑入）。
                            offstage:
                                !(i == _index ||
                                    i == _premount ||
                                    (_pageMotion.isAnimating &&
                                        (i - page).abs() < 1)),
                            child: Transform.translate(
                              offset: Offset((i - page) * width, 0),
                              // RepaintBoundary 把页面内容缓存为独立图层：
                              // 动画期间 Transform 只移动图层（GPU 合成），
                              // 不触发页面内容的逐帧 repaint。
                              child: RepaintBoundary(
                                child: TickerMode(
                                  enabled: i == _index,
                                  child: _tabChild(i),
                                ),
                              ),
                            ),
                          ),
                        ),
                  ],
                );
              },
            );
          },
        ),
      ),
      // 上游 Wenku8 GlassDock：胶囊、拖动预览和液态玻璃选中区；短剧视频流
      // 与 OLED 纯黑下改用同色静态底板，不对每帧变化的画面做实时折射。
      bottomNavigationBar: ShellDock(
        selectedIndex: _index,
        onSelected: _selectTab,
        overVideo: dramaOnVideo,
        staticMaterial: shellDockStaticMaterial(overVideo: dramaOnVideo),
        animating: _pageMotion.isAnimating,
      ),
    );
  }
}
