import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'pages/home_page.dart';
import 'pages/cached_books_page.dart';
import 'pages/drama_page.dart';
import 'pages/library_page.dart';
import 'pages/mine_page.dart';
import 'services/app_theme.dart';
import 'services/backend_service.dart';
import 'services/digg_store.dart';
import 'services/home_feed_cache.dart';
import 'services/library_store.dart';
import 'services/shelf_store.dart';
import 'services/swipe_guide_store.dart';
import 'widgets/lazy_indexed_stack.dart';
import 'widgets/home/home_design.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: FqApp()));
}

Future<void> _initializeLocalData() async {
  await Hive.initFlutter();
  await LibraryStore.instance.init();
  // The 加入书架 collection is optional data: a failure here must not block
  // startup, which is why it shares the retryable bootstrap with the history.
  await ShelfStore.instance.init();
  // 短剧 feed 的 点赞 也是可选本地数据，与书架同一处理：开箱失败不能让
  // 启动失败，否则一个纯装饰性的集合会拖住短剧页之外的所有功能。
  try {
    await DiggStore.instance.init();
  } catch (_) {
    // DiggStore 自己把「不可用」当成「没有点赞」处理（见 _openBox）。
  }
  // 「上滑查看更多视频」的一次性标记同样是可选数据：读不到就当没弹过，
  // 弹一次的语义退化成「本次启动弹一次」也不能拖住启动。
  try {
    await SwipeGuideStore.instance.init();
  } catch (_) {
    // SwipeGuideStore 自己把「不可用」当成「未显示」处理。
  }
  // 首页 feed 的冷启动缓存也是可选数据：打不开就当没有缓存，
  // 首页退化为先加载再显示，其余行为不变。
  try {
    HomeFeedCache.hiveReady = true;
    await HomeFeedCache.instance.warmUp();
  } catch (_) {
    // HomeFeedCache 自己把「不可用」当成「没有缓存」处理。
  }
  final sp = await SharedPreferences.getInstance();
  // Note: Optional preference schemas cannot block local data startup; see
  // .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md.
  final savedTheme = sp.get(themeModeKey);
  themeModeNotifier.value = themeModeFromName(
    savedTheme is String ? savedTheme : null,
  );
}

class FqApp extends StatelessWidget {
  const FqApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: '番茄小铺',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: mode,
          home: const AppBootstrap(child: RootShell()),
        );
      },
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: appSeedColor,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? const Color(0xFF121212)
          : const Color(0xFFF5F5F7),
    );
  }
}

/// Opens local data before any page can access LibraryStore's boxes. Failed
/// initialization is retryable without clearing or replacing the user's data.
/// See .agents/notes/implemented/bug-fix/2026-09-17-reviewed-runtime-boundaries.md.
class AppBootstrap extends StatefulWidget {
  final Widget child;
  final Future<void> Function()? initializer;

  const AppBootstrap({super.key, required this.child, this.initializer});

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  bool _initializing = false;
  bool _ready = false;
  bool _failed = false;

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

    return Scaffold(
      body: LazyIndexedStack(
        index: _index,
        children: [
          const HomePage(),
          const DramaPage(),
          // 空书架上的「去书城找书」切回首页 tab。
          LibraryPage(onBrowse: () => setState(() => _index = 0)),
          const MinePage(),
        ],
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          height: 72,
          elevation: 0,
          backgroundColor: HomePalette.of(context).canvas,
          surfaceTintColor: Colors.transparent,
          indicatorColor: HomePalette.accent.withValues(alpha: 0.10),
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              size: 22,
              color: states.contains(WidgetState.selected)
                  ? HomePalette.accent
                  : HomePalette.of(context).muted,
            ),
          ),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: 11,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
              color: states.contains(WidgetState.selected)
                  ? HomePalette.of(context).accentText
                  : HomePalette.of(context).muted,
            ),
          ),
        ),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: HomePalette.of(context).line, width: 0.5),
            ),
          ),
          child: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) {
              if (i != _index) setState(() => _index = i);
            },
            // Note: 短剧是独立的底部目的地，拥有自己的 feed 实例 —— 为何不复用
            // homeProvider 见 .agents/notes/implemented/feature/2026-09-20-bottom-short-drama-tab.md
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
        ),
      ),
    );
  }
}
