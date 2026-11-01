import '../services/desktop_platform.dart';
import '../services/audio_floating_routes.dart';
import '../widgets/desktop_chapter_sidebar.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/chapter_media.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/backend_transport.dart';
import '../services/comic_page_layout.dart';
import '../services/fair_memory.dart';
import '../services/library_store.dart';
import '../services/chapter_cache_store.dart';
import '../services/media_history_store.dart';
import '../services/reader_history.dart';
import '../services/shelf_store.dart';
import '../services/shelf_toggle.dart';
import '../services/user_facing_error.dart';
import '../widgets/comic/comic_chapter_bar.dart';
import '../widgets/comic/comic_chrome_button.dart';
import '../widgets/comic/comic_directory_sheet.dart';
import '../widgets/comic/comic_image_viewer.dart';
import '../widgets/comic/comic_reader_toolbar.dart';
import '../widgets/comic/comic_reader_viewport.dart';
import '../widgets/home/home_back_button.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_feed_states.dart';

// 漫画图的默认提供方放在 ComicImageTile 里（墨水屏包装也在那），这里转出
// 给既有调用方 / 测试继续从本页面导入。
export '../widgets/comic/comic_image_tile.dart' show defaultComicImageProvider;

part 'comic/comic_reader_build.dart';
part 'comic/comic_reader_session.dart';

typedef ComicChapterLoader = Future<List<ComicImage>> Function(Chapter chapter);
typedef ComicImageProviderFactory =
    ImageProvider<Object> Function(ComicImage image);

class ComicReaderPage extends StatefulWidget {
  final String bookId;
  final String title;
  final String cover;
  final List<Chapter> chapters;
  final int startIndex;
  final ReaderStore? readerStore;
  final ComicChapterLoader? chapterLoader;
  final ComicImageProviderFactory? imageProviderFactory;

  /// 目录缓存，供「最近阅读/书架」下次直接续读漫画用。
  ///
  /// 漫画没有正文缓存（图片带 per-launch 能力值，不能落盘），所以这里只存
  /// 目录本身；空表示用默认的 ChapterCacheStore。
  final ChapterCache? cache;

  /// 加入书架时用的条目（issue #103）。详情页传入原 `MediaItem`，书架卡片因此
  /// 保留作者/徽标；其他入口省略，按 [bookId]/[title]/[cover] 兜底成漫画条目。
  final MediaItem? shelfItem;

  const ComicReaderPage({
    super.key,
    required this.bookId,
    required this.title,
    this.cover = '',
    required this.chapters,
    required this.startIndex,
    this.readerStore,
    this.chapterLoader,
    this.imageProviderFactory,
    this.cache,
    this.shelfItem,
  });

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage>
    with WidgetsBindingObserver {
  final _scroll = ScrollController(keepScrollOffset: false);
  // 翻页模式专用；条漫模式不用控制器，位置由 _scroll 负责。
  PageController? _pageController;
  late final ReaderStore _readerStore = scopedHistoryStore(
    widget.readerStore ?? LibraryStore.instance,
    'manga',
  );
  late final _history = ReaderHistory(_readerStore);

  /// 漫画阅读器自己的书架条目（issue #103）：详情页传了原 item 就用它，否则按
  /// 本页已有的书籍字段兜底。书架 key 是 `kind:id`，漫画固定 'manga'。
  MediaItem get _shelfEntry =>
      widget.shelfItem ??
      MediaItem(
        id: widget.bookId,
        title: widget.title,
        cover: widget.cover,
        author: '',
        badge: '',
        ep: '',
        kind: 'manga',
      );
  late int _chapterIndex;
  List<ComicImage> _images = const [];
  List<double> _ratios = const [];
  final Set<int> _readyImages = {};
  ComicPageLayout? _layout;
  double _layoutWidth = 0;
  int _layoutRevision = 0;
  int _builtLayoutRevision = -1;
  double? _restoreAnchor;
  int _restoreTicket = 0;
  int _loadGeneration = 0;

  /// In-flight comic image request; cancelled when a newer chapter load wins or
  /// the page is disposed.
  BackendRequest? _imageRequest;
  int _visiblePage = 0;
  double _lastPosition = 0;
  bool _restoring = true;
  bool _loading = true;
  bool _pagedMode = false;
  bool _progressReady = false;
  bool _appActive = true;
  bool _sessionActive = false;
  DateTime _readStart = DateTime.now();
  Timer? _saveTimer;
  // 小米公平运行内存 KILL 广播的刷盘注销函数，见 reader_page.dart。
  VoidCallback? _unregisterFairMemoryFlush;
  String? _error;

  Chapter get _chapter => widget.chapters[_chapterIndex];

  /// part 里的扩展不是 [State] 子类，不能直接调受保护的 `setState`，
  /// 统一转一层（与 reader_page 的 `_setState` 相同）。
  void _setState(VoidCallback fn) => setState(fn);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AudioFloatingRouteScope.configure(context, hidden: true);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 小米公平运行内存：KILL 广播到达时刷一次漫画进度，避免被杀丢进度。
    _unregisterFairMemoryFlush = FairMemoryService.instance
        .registerFlushHandler(_saveProgress);
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _chapterIndex = widget.chapters.isEmpty
        ? 0
        : widget.startIndex.clamp(0, widget.chapters.length - 1);
    _scroll.addListener(_onScroll);
    if (widget.chapters.isEmpty) {
      _loading = false;
      _error = '暂无可阅读章节';
    } else {
      unawaited(_rememberCatalogue());
      unawaited(_loadChapter());
    }
  }

  @override
  void dispose() {
    _imageRequest?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _unregisterFairMemoryFlush?.call();
    _unregisterFairMemoryFlush = null;
    _saveTimer?.cancel();
    _settleReadTime();
    _sessionActive = false;
    unawaited(_saveProgress());
    _scroll.dispose();
    _pageController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (!active && _appActive) {
      _settleReadTime();
      _sessionActive = false;
      _appActive = false;
      unawaited(_saveProgress());
    } else if (active && !_appActive) {
      _appActive = true;
      _startReadTime();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isWindowsDesktop) return _buildSurface(context);
    return LayoutBuilder(
      builder: (context, bounds) => Row(
        children: [
          if (bounds.maxWidth >= 1000)
            DesktopChapterSidebar(
              chapters: widget.chapters,
              currentIndex: _chapterIndex,
              onSelected: (index) => _changeChapter(index),
            ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: _buildSurface(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
