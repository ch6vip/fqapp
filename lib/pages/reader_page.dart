import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../models/book_comment.dart';
import '../models/chapter_ideas.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/chapter_cache_store.dart';
import '../services/chapter_text_formatter.dart';
import '../services/library_store.dart';
import '../services/reader_history.dart';
import '../services/listening_session.dart';
import '../services/reader_device.dart';
import '../services/reader_preferences.dart';
import '../widgets/chapter_cache_sheet.dart';
import '../widgets/reader/reader_appearance_sheet.dart';
import '../widgets/reader/reader_bubble.dart';
import '../widgets/reader/reader_chapter_layout.dart';
import '../widgets/reader/reader_controls.dart';
import '../widgets/reader/reader_illustration.dart';
import '../widgets/reader/reader_ideas_sheet.dart';
import '../widgets/reader/reader_paged_view.dart';
import '../widgets/reader/reader_status_bar.dart';
import '../widgets/reader/reader_theme.dart';

typedef ChapterTextLoader = Future<String> Function(Chapter chapter);
typedef _LoadedChapter = ({String text, bool fetched});

/// Loads a chapter's paragraph ideas (段评).
typedef ChapterIdeasLoader = Future<ChapterIdeas> Function(String itemId);

/// Resolves the comment bodies for one paragraph's idea bucket. [cursor] is
/// the previous page's offset while paging, null on the first request.
typedef ParagraphCommentResolver =
    Future<BookCommentPage> Function(
      String itemId,
      ParagraphIdeas paragraph,
      String? cursor,
    );

class ReaderPage extends StatefulWidget {
  final String bookId;
  final String title;
  final String cover;
  final List<Chapter> chapters;
  final int startIndex;
  final ChapterTextLoader? chapterLoader;
  final ReaderStore? readerStore;
  final ChapterCache? chapterCache;
  final ReaderDevice? readerDevice;
  final ReaderImageProviderFactory? imageProviderFactory;

  /// Paragraph ideas for the current chapter. When both this and
  /// [commentResolver] are null the reader fetches them itself, unless a
  /// [chapterCache] was injected (an injected cache marks the caller as
  /// driving its own data).
  final ChapterIdeasLoader? ideasLoader;
  final ParagraphCommentResolver? commentResolver;

  const ReaderPage({
    super.key,
    required this.bookId,
    required this.title,
    this.cover = '',
    required this.chapters,
    required this.startIndex,
    this.chapterLoader,
    this.readerStore,
    this.chapterCache,
    this.readerDevice,
    this.imageProviderFactory,
    this.ideasLoader,
    this.commentResolver,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

// Note: 菜单覆盖层与正文布局分离；见
// .agents/notes/implemented/feature/2026-09-10-reader-interface.md
class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  late int _index;
  final ScrollController _scrollController = ScrollController();
  Timer? _saveTimer;
  String _content = '';
  ChapterContent _chapterContent = ChapterContent(blocks: const []);
  ChapterIdeas _ideas = ChapterIdeas.empty;
  bool _loading = true;
  bool _progressReady = false;
  double _lastPosition = 0;
  double _lastMaxScroll = 0;
  String? _error;
  ReaderPreferences _preferences = const ReaderPreferences();
  ReaderThemePreset _dayTheme = ReaderThemePreset.light;
  bool _controlsVisible = false;

  /// 自动翻页: a repeating timer flips forward every [ReaderPreferences.autoTurnSeconds]
  /// seconds; any tap or drag stops it. See
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  Timer? _autoTurnTimer;

  bool get _paged => _preferences.pageMode == ReaderPageMode.paged;

  bool _handleVolumeKey(KeyEvent event) {
    if (!_preferences.volumeKeyTurn || _controlsVisible) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (_paged) {
      if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
        _pauseListenFollow();
        _stopAutoTurn();
        unawaited(_stopTtsRead());
        unawaited(_turnPage(1));
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
        _pauseListenFollow();
        _stopAutoTurn();
        unawaited(_stopTtsRead());
        unawaited(_turnPage(-1));
        return true;
      }
    }
    return false;
  }

  void _toggleAutoTurn() {
    if (_autoTurnTimer != null) {
      _stopAutoTurn();
      return;
    }
    unawaited(_stopTtsRead());
    _controlsVisible = false;
    _autoTurnTimer = Timer.periodic(
      Duration(seconds: _preferences.autoTurnSeconds),
      (_) => _autoTurnStep(),
    );
    if (mounted) setState(() {});
  }

  void _stopAutoTurn() {
    _autoTurnTimer?.cancel();
    _autoTurnTimer = null;
    if (mounted) setState(() {});
  }

  /// 听书跟随翻页: the audio page is narrating this chapter, so land on the
  /// page holding the estimated playback position. Instant jumps — the
  /// narration keeps moving and an animated chase would always lag.
  ///
  /// 用户接管闩锁: a manual page turn pauses following briefly, so the reader
  /// does not yank the page back within a second.
  DateTime _listenFollowPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  void _pauseListenFollow() {
    _listenFollowPausedUntil = DateTime.now().add(const Duration(seconds: 15));
  }

  void _onListeningTick() {
    if (!mounted ||
        !_preferences.listeningFollow ||
        _autoTurnTimer != null ||
        _ttsActive ||
        _controlsVisible ||
        _loading ||
        _error != null) {
      return;
    }
    if (DateTime.now().isBefore(_listenFollowPausedUntil)) return;
    final session = ListeningSession.instance;
    if (!session.matches(widget.bookId, _chapter.itemId)) return;
    final progress = session.progress;
    if (_paged) {
      _pagedKey.currentState?.followProgress(progress);
    } else if (_scrollController.hasClients) {
      final position = _scrollController.position;
      if (position.maxScrollExtent > 0) {
        _scrollController.jumpTo(progress * position.maxScrollExtent);
      }
    }
  }

  /// 边走边读: system TTS narrates the reader page by page and flips forward
  /// on completion — the official AudioTtsDepend behaviour with our own
  /// engine. Any tap/drag/chapter change stops it.
  FlutterTts? _tts;
  bool _ttsActive = false;

  /// Bumped whenever a start begins or is stopped. An in-flight startup that
  /// resumes after a platform await checks it, so it can neither install
  /// handlers nor setState/speak after the reader moved on or was disposed.
  int _ttsGeneration = 0;

  Future<void> _toggleTtsRead() async {
    if (_ttsActive) {
      await _stopTtsRead();
      return;
    }
    _controlsVisible = false;
    _stopAutoTurn();
    final generation = ++_ttsGeneration;
    final tts = _tts ??= FlutterTts();
    try {
      await tts.setLanguage('zh-CN');
      await tts.setSpeechRate(0.5);
      await tts.awaitSpeakCompletion(true);
    } catch (_) {
      if (mounted && generation == _ttsGeneration) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('当前设备没有可用的中文语音引擎')));
      }
      return;
    }
    if (!mounted || generation != _ttsGeneration) return;
    tts.setCompletionHandler(() {
      if (!_ttsActive || !mounted) return;
      // The page finished narrating: flip forward and keep going. Loading
      // windows and the chapter end (本章完 / 最后一章) stop the chain.
      unawaited(
        _turnPage(1).then((_) {
          if (!_ttsActive || !mounted) return null;
          if (_loading || _chapterLayout == null) return _stopTtsRead();
          return _speakCurrentPage();
        }),
      );
    });
    setState(() => _ttsActive = true);
    await _speakCurrentPage();
  }

  Future<void> _speakCurrentPage() async {
    final tts = _tts;
    final layout = _chapterLayout;
    if (tts == null || layout == null || !_paged) {
      await _stopTtsRead();
      return;
    }
    final page = _pageIndex < layout.pages.length
        ? layout.pages[_pageIndex]
        : null;
    if (page == null) {
      await _stopTtsRead();
      return;
    }
    final text = page.fragments
        .where((f) => !f.block.isImage)
        .map((f) => f.text)
        .join('\n');
    if (text.trim().isEmpty) {
      // An illustration-only page has nothing to narrate: keep the chain
      // moving instead of stalling until the next completion event.
      unawaited(
        _turnPage(1).then((_) {
          if (_ttsActive && mounted) return _speakCurrentPage();
        }),
      );
      return;
    }
    try {
      await tts.speak(text);
    } catch (_) {
      await _stopTtsRead();
    }
  }

  Future<void> _stopTtsRead() async {
    if (!_ttsActive && _tts == null) return;
    ++_ttsGeneration;
    _ttsActive = false;
    try {
      await _tts?.stop();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _autoTurnStep() {
    if (!mounted) return _stopAutoTurn();
    if (_paged) {
      unawaited(_turnPage(1));
    } else if (_scrollController.hasClients) {
      final position = _scrollController.position;
      final target = (position.pixels + position.viewportDimension * 0.85)
          .clamp(0.0, position.maxScrollExtent);
      unawaited(
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  double? _chapterSeekValue;
  int _loadGeneration = 0;
  // Legado-style reading time: deltas are settled at scroll stops, chapter
  // switches and dispose, so no background timer is needed.
  DateTime _readStart = DateTime.now();
  bool _sessionActive = false;
  bool _appActive = true;
  bool _changingChapter = false;
  final LinkedHashMap<String, String> _chapterCache = LinkedHashMap();
  final Map<String, Future<_LoadedChapter>> _chapterRequests = {};
  final Map<String, int> _chapterCacheRevisions = {};
  final Map<String, Future<void>> _chapterRefreshes = {};
  Future<void>? _catalogFuture;
  late final ReaderHistory _history = ReaderHistory(_readerStore);
  late final ReaderDevice _device = widget.readerDevice ?? ReaderDevice();
  late final Future<void> _preferencesFuture;
  StreamSubscription<ReaderDeviceStatus>? _deviceSubscription;
  ReaderDeviceStatus _deviceStatus = ReaderDeviceStatus(time: DateTime.now());
  bool _deviceAvailable = false;
  bool _preferencesReady = false;
  bool _preferencesDirty = false;
  int _deviceGeneration = 0;
  int _brightnessGeneration = 0;
  int _fontGeneration = 0;
  String? _fontFamily;
  final _viewportKey = GlobalKey();
  final _pagedKey = GlobalKey<ReaderPagedViewState>();
  ReaderChapterLayout? _chapterLayout;
  ReaderPageMode? _layoutMode;
  int _layoutRevision = 0;

  /// Bumped whenever [_ideas] changes. Cached layouts remember the revision they
  /// were measured with, so a chapter is re-measured once its paragraph bubbles
  /// arrive even though the text, font and viewport are unchanged.
  int _ideasRevision = 0;
  int _layoutIdeasRevision = -1;
  int _textOffset = 0;
  int _pageIndex = 0;
  Map<String, dynamic>? _savedPosition;
  bool _needsRestore = true;
  bool _requestedStartAtEnd = false;

  Chapter get _chapter => widget.chapters[_index];
  ReaderStore get _readerStore => widget.readerStore ?? LibraryStore.instance;
  ChapterCache get _diskCache =>
      widget.chapterCache ?? ChapterCacheStore.instance;
  CachedBook get _cachedBook => CachedBook(
    id: widget.bookId,
    title: widget.title,
    cover: widget.cover,
    chapters: widget.chapters,
  );

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleVolumeKey);
    ListeningSession.instance.addListener(_onListeningTick);
    WidgetsBinding.instance.addObserver(this);
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _index = widget.chapters.isEmpty
        ? 0
        : widget.startIndex.clamp(0, widget.chapters.length - 1);
    _scrollController.addListener(_onScroll);
    _preferencesFuture = _loadPreferences();
    if (widget.chapters.isEmpty) {
      _loading = false;
      _error = '暂无可阅读章节';
    } else {
      unawaited(_ensureCatalog().catchError((_) {}));
      _load();
    }
  }

  Future<void> _loadPreferences() async {
    ReaderPreferences preferences;
    try {
      preferences = await ReaderPreferences.load();
    } catch (_) {
      preferences = const ReaderPreferences();
    }
    if (!mounted) return;
    setState(() {
      _preferences = preferences;
      _preferencesReady = true;
      if (preferences.themePreset != ReaderThemePreset.dark) {
        _dayTheme = preferences.themePreset;
      }
    });
    await _loadFont(preferences.fontPath);
    if (mounted && _appActive) unawaited(_refreshDevice());
  }

  Future<void> _refreshDevice() async {
    if (!_preferencesReady || !_appActive || widget.chapters.isEmpty) return;
    final generation = ++_deviceGeneration;
    final status = await _device.start(
      followSystem: _preferences.followSystemBrightness,
      brightness: _preferences.brightness,
    );
    if (!mounted || generation != _deviceGeneration || !_appActive) return;
    setState(() {
      _deviceAvailable = status != null;
      if (status != null) _deviceStatus = status;
    });
    if (status != null) {
      _deviceSubscription ??= _device.changes.listen((status) {
        if (mounted && _appActive) setState(() => _deviceStatus = status);
      }, onError: (Object _) {});
    }
    // 进入阅读器即按偏好应用常亮(否则只有动过设置才生效)。
    unawaited(_device.keepScreenOn(_preferences.keepScreenOn));
  }

  Future<void> _loadFont(String path) async {
    final generation = ++_fontGeneration;
    try {
      final family = await ReaderFonts.load(path);
      if (!mounted || generation != _fontGeneration) return;
      setState(() => _fontFamily = family);
    } on ReaderFontLimitException {
      if (!mounted || generation != _fontGeneration) return;
      setState(() => _fontFamily = null);
      _showMessage('已导入字体过多，重启应用后可继续更换字体');
    } catch (_) {
      if (!mounted || generation != _fontGeneration) return;
      setState(() {
        _fontFamily = null;
        _preferences = _preferences.copyWith(fontPath: '', fontName: '');
        _preferencesDirty = true;
      });
      _showMessage('字体无法读取，已使用系统字体');
    }
  }

  Future<ReaderFont?> _pickFont() async {
    final font = await _device.pickFont();
    if (font == null) return null;
    try {
      await ReaderFonts.load(font.path);
    } on ReaderFontLimitException {
      if (mounted) _showMessage('已导入字体过多，重启应用后可继续更换字体');
      return null;
    }
    return font;
  }

  Future<void> _savePreferences({bool applyKeepScreenOn = true}) async {
    if (applyKeepScreenOn) {
      unawaited(_device.keepScreenOn(_preferences.keepScreenOn));
    }
    if (!_preferencesReady || !_preferencesDirty) return;
    final snapshot = _preferences;
    _preferencesDirty = false;
    try {
      await snapshot.save();
    } catch (_) {
      _preferencesDirty = true;
      if (mounted) _showMessage('设置保存失败，请重试');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _changeBrightness(double value, {bool followSystem = false}) {
    _preferencesDirty = true;
    final generation = ++_brightnessGeneration;
    setState(
      () => _preferences = _preferences.copyWith(
        brightness: value,
        followSystemBrightness: followSystem,
      ),
    );
    unawaited(
      _device.setBrightness(followSystem: followSystem, brightness: value).then(
        (applied) {
          if (!applied && mounted && generation == _brightnessGeneration) {
            _showMessage('暂时无法调整亮度，请重新进入阅读界面');
          }
        },
      ),
    );
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleVolumeKey);
    ListeningSession.instance.removeListener(_onListeningTick);
    _autoTurnTimer?.cancel();
    ++_ttsGeneration;
    unawaited(_tts?.stop());
    WidgetsBinding.instance.removeObserver(this);
    ++_deviceGeneration;
    unawaited(_deviceSubscription?.cancel());
    // The save must not re-apply keepScreenOn after the explicit clear below,
    // or the screen would stay awake after leaving the reader.
    unawaited(_savePreferences(applyKeepScreenOn: false));
    unawaited(_device.keepScreenOn(false));
    unawaited(_device.close());
    _saveTimer?.cancel();
    _settleReadTime();
    _sessionActive = false;
    unawaited(_persistProgress());
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (!resumed && _appActive) {
      _stopAutoTurn();
      unawaited(_stopTtsRead());
      ++_deviceGeneration;
      unawaited(_device.suspend());
      _settleReadTime();
      _sessionActive = false;
      _appActive = false;
      unawaited(_persistProgress());
    } else if (resumed && !_appActive) {
      _appActive = true;
      unawaited(_refreshDevice());
      if (!_loading && _content.isNotEmpty) {
        _readStart = DateTime.now();
        _sessionActive = true;
        if (_chapterContent.needsImageRefresh()) {
          unawaited(_refreshCachedChapter(_chapter));
        }
      }
    }
  }

  Future<void> _load({bool startAtEnd = false}) async {
    if (widget.chapters.isEmpty) return;
    final generation = ++_loadGeneration;
    final chapter = _chapter;
    _saveTimer?.cancel();
    setState(() {
      _loading = true;
      _progressReady = false;
      _error = null;
      _content = '';
      _chapterContent = ChapterContent(blocks: const []);
      _chapterLayout = null;
      _layoutMode = null;
      _textOffset = 0;
      _pageIndex = 0;
      _needsRestore = true;
      _requestedStartAtEnd = startAtEnd;
      _sessionActive = false;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);

    try {
      final loaded = await _chapterText(chapter);
      await _preferencesFuture;
      if (!mounted || generation != _loadGeneration) return;
      Map<String, dynamic>? saved;
      try {
        saved = await _history.load(widget.bookId);
        if (saved?['kind'] != null && saved?['kind'] != 'book') saved = null;
      } catch (_) {
        // History storage must not prevent an available chapter from opening.
      }
      if (!mounted || generation != _loadGeneration) return;
      // Cache updates may arrive while preferences/history are being read.
      final text = _chapterCache[chapter.itemId] ?? loaded.text;
      final content = ChapterContent.fromCacheText(text);
      if (content.withoutLeadingTitle(chapter.title).isEmpty) {
        throw ApiException('正文为空');
      }
      setState(() {
        _content = text;
        _chapterContent = content;
        _savedPosition = saved;
        _loading = false;
        // Ideas belong to the chapter, so they are dropped on every load and
        // fetched again; a stale count would otherwise point at another chapter.
        _ideas = ChapterIdeas.empty;
      });
      unawaited(_prefetchAround(_index));
      unawaited(_loadIdeas(chapter, generation));
      if (!loaded.fetched && content.needsImageRefresh()) {
        unawaited(_refreshCachedChapter(chapter));
      }
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Loads the chapter's paragraph ideas. Decoration only: a failure leaves the
  /// reader fully usable with the段评 action hidden.
  Future<void> _loadIdeas(Chapter chapter, int generation) async {
    final loader = widget.ideasLoader;
    if (loader == null && widget.chapterCache != null) {
      // An injected cache means the caller drives its own data; do not reach
      // for the network behind its back.
      return;
    }
    try {
      final ideas = await (loader ?? _defaultIdeas)(chapter.itemId);
      if (!mounted || generation != _loadGeneration) return;
      if (chapter.itemId != widget.chapters[_index].itemId) return;
      setState(() {
        _ideas = ideas;
        ++_ideasRevision;
      });
      // Note: Old image-aware caches can still lack paragraph ids. Refresh
      // only when ideas need them; never fabricate ids from display order.
      // .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
      if (!_chapterContent.paragraphIdsChecked &&
          ideas.paragraphs.any((paragraph) => paragraph.showsBubble)) {
        unawaited(_refreshCachedChapter(chapter));
      }
    } catch (_) {
      // Keep the section hidden rather than surfacing a failure. Catches Error
      // as well as Exception: ideas are decoration, not a page-level failure.
    }
  }

  /// The in-text paragraph-comment bubble, built during layout so it can be
  /// measured as a placeholder at the end of the paragraph.
  ///
  /// Note: 气泡的门槛与几何规格取自官方客户端 — 见
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  Widget _buildParagraphBubble(
    int paraIndex,
    int count,
    ParagraphBubbleVariant variant,
  ) => ReaderParagraphBubble(
    count: count,
    metrics: ReaderBubbleMetrics.forFontSize(
      MediaQuery.textScalerOf(context).scale(_preferences.fontSize),
      variant: variant,
    ),
    preset: _preferences.themePreset,
    onTap: () => unawaited(_showIdeas(focusParaIndex: paraIndex)),
  );

  Future<void> _showIdeas({int? focusParaIndex}) async {
    if (_ideas.isEmpty) return;
    setState(() => _controlsVisible = false);
    final ideaSnapshot = _ideas;
    final chapter = widget.chapters[_index];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      backgroundColor: _preferences.themePreset.isDark
          ? _preferences.themePreset.panelColor
          : Colors.white,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (context) => FractionallySizedBox(
        // Match the supplied official screenshot, keeping the paragraph visible
        // above the comments. Note: 2026-09-11-reader-paragraph-bubble.md.
        heightFactor: 0.69,
        child: ReaderIdeasSheet(
          ideas: ideaSnapshot,
          preset: _preferences.themePreset,
          // Each bubble opens only that paragraph's comments.
          initialParaIndex: focusParaIndex,
          loadComments: (paragraph, cursor) async {
            final resolver = widget.commentResolver;
            if (resolver != null) {
              return resolver(chapter.itemId, paragraph, cursor);
            }
            return _defaultComments(
              chapter,
              paragraph,
              ideaSnapshot.itemVersion,
              cursor,
            );
          },
        ),
      ),
    );
  }

  /// Default idea fetch and comment resolution; see [ReaderPage.ideasLoader].
  Future<ChapterIdeas> _defaultIdeas(String itemId) =>
      ApiClient.instance.chapterIdeas(itemId);

  /// Loads one paragraph's comments.
  ///
  /// Note: the upstream wants `server_channel=38` here, not the 43 the official
  /// presenter assigns, and it needs the chapter version — see
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  Future<BookCommentPage> _defaultComments(
    Chapter chapter,
    ParagraphIdeas paragraph,
    String ideaVersion,
    String? cursor,
  ) {
    return ApiClient.instance.paragraphComments(
      widget.bookId,
      chapter.itemId,
      itemVersion: chapter.version.isNotEmpty ? chapter.version : ideaVersion,
      paraIndex: paragraph.paraIndex,
      cursor: cursor,
    );
  }

  Future<_LoadedChapter> _chapterText(Chapter chapter) async {
    final id = chapter.itemId;
    final cached = _chapterCache.remove(id);
    if (cached != null) {
      _chapterCache[id] = cached;
      return (text: cached, fetched: false);
    }
    final pending = _chapterRequests[id];
    if (pending != null) return pending;

    final request = _loadChapterText(chapter);
    _chapterRequests[id] = request;
    try {
      return await request;
    } finally {
      if (identical(_chapterRequests[id], request)) {
        _chapterRequests.remove(id);
      }
    }
  }

  Future<String> _fetchChapter(Chapter chapter) async {
    final loader = widget.chapterLoader;
    final ChapterContent content;
    if (loader == null) {
      content = await ApiClient.instance.chapterContent(chapter.itemId);
    } else {
      final text = await loader(chapter);
      content = ChapterContent.isStructuredCache(text)
          ? ChapterContent.fromCacheText(text)
          : ChapterContent.fromPlainText(text, illustrationsChecked: true);
    }
    if (content.withoutLeadingTitle(chapter.title).isEmpty) {
      throw const ApiException('正文为空');
    }
    return content.toCacheText();
  }

  Future<void> _refreshCachedChapter(Chapter chapter) async {
    final pending = _chapterRefreshes[chapter.itemId];
    if (pending != null) return pending;
    final request = _upgradeChapter(chapter);
    _chapterRefreshes[chapter.itemId] = request;
    try {
      await request;
    } finally {
      if (identical(_chapterRefreshes[chapter.itemId], request)) {
        _chapterRefreshes.remove(chapter.itemId);
      }
    }
  }

  Future<void> _upgradeChapter(Chapter chapter) async {
    final revision = _chapterCacheRevisions[chapter.itemId] ?? 0;
    try {
      final text = await _fetchChapter(chapter);
      if (!mounted ||
          revision != (_chapterCacheRevisions[chapter.itemId] ?? 0)) {
        return;
      }
      final content = ChapterContent.fromCacheText(text);
      // This request only refreshes an existing cache, even if its memory
      // entry was evicted while fetching. Partial content cannot improve it.
      if (!content.illustrationsChecked) return;
      var catalogReady = true;
      try {
        await _ensureCatalog();
      } catch (_) {
        catalogReady = false;
      }
      if (!mounted ||
          revision != (_chapterCacheRevisions[chapter.itemId] ?? 0)) {
        return;
      }
      _onChapterContentAvailable(chapter, text);
      if (!catalogReady) return;
      try {
        await _diskCache.write(
          bookId: widget.bookId,
          chapterId: chapter.itemId,
          title: chapter.title,
          text: text,
        );
      } catch (_) {
        // A disk failure does not hide newly fetched illustrations.
      }
    } catch (_) {
      // Legacy text remains immediately readable, including while offline.
    }
  }

  void _rememberChapter(String id, String text) {
    _chapterCache.remove(id);
    _chapterCache[id] = text;
    while (_chapterCache.length > 5) {
      _chapterCache.remove(
        _chapterCache.keys.firstWhere((id) => id != _chapter.itemId),
      );
    }
  }

  // Note: 批量补图与预取共享缓存版本，迟到旧结果不能覆盖新图文；见
  // .agents/notes/implemented/bug-fix/2026-09-10-reader-illustrations.md
  void _onChapterContentAvailable(Chapter chapter, String text) {
    // A cache hit must not invalidate an in-flight signature refresh.
    if (!mounted || _chapterCache[chapter.itemId] == text) return;
    final fetched = ChapterContent.fromCacheText(text);
    final cached = _chapterCache[chapter.itemId];
    final previous = cached == null
        ? null
        : ChapterContent.fromCacheText(cached);
    final content = fetched.preferCompleteCache(previous);
    if (!identical(content, fetched)) return;
    _chapterCacheRevisions.update(
      chapter.itemId,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    _rememberChapter(chapter.itemId, text);
    // The same chapter may have been left and reopened while this one
    // deduplicated refresh was pending. Its identity still makes it current.
    if (_loading || chapter.itemId != _chapter.itemId || text == _content) {
      return;
    }
    final hasImages = _chapterContent.hasImages;
    final restoring = _needsRestore;
    final offset = hasImages
        ? _textOffset
        : _chapterLayout?.legacyOffsetForText(_textOffset) ?? _textOffset;
    setState(() {
      if (restoring) {
        // A fast refresh may finish before the old cache's first layout.
        // Preserve the history/start-at-end request until it is restored.
        if (!hasImages && _savedPosition?['positionVersion'] == 2) {
          _savedPosition = {...?_savedPosition, 'positionVersion': 1};
        }
      } else {
        _savedPosition = {
          'chapterId': chapter.itemId,
          'positionVersion': hasImages ? 2 : 1,
          'textOffset': offset,
        };
        _requestedStartAtEnd = false;
      }
      _content = text;
      _chapterContent = content;
      _chapterLayout = null;
      _layoutMode = null;
      _needsRestore = true;
      _progressReady = false;
    });
  }

  Future<void> _ensureCatalog() => _catalogFuture ??= _diskCache
      .saveBook(_cachedBook)
      .catchError((Object error) {
        _catalogFuture = null;
        throw error;
      });

  Future<_LoadedChapter> _loadChapterText(Chapter chapter) async {
    final revision = _chapterCacheRevisions[chapter.itemId] ?? 0;
    bool superseded() =>
        revision != (_chapterCacheRevisions[chapter.itemId] ?? 0);
    String? text;
    try {
      final cached = await _diskCache.read(
        bookId: widget.bookId,
        chapterId: chapter.itemId,
      );
      if (cached != null &&
          cached.trim().isNotEmpty &&
          !ChapterContent.fromCacheText(
            cached,
          ).withoutLeadingTitle(chapter.title).isEmpty) {
        text = cached;
      }
    } catch (_) {
      // A storage failure must not prevent online reading.
    }
    if (superseded()) return _latestChapterText(chapter);
    final fetched = text == null;
    if (fetched) {
      try {
        text = await _fetchChapter(chapter);
      } catch (_) {
        if (superseded()) return _latestChapterText(chapter);
        rethrow;
      }
      if (superseded()) return _latestChapterText(chapter);
      if (mounted) {
        try {
          await _ensureCatalog();
          if (superseded()) return _latestChapterText(chapter);
          if (mounted) {
            await _diskCache.write(
              bookId: widget.bookId,
              chapterId: chapter.itemId,
              title: chapter.title,
              text: text,
            );
          }
        } catch (_) {
          // Cache management reports storage errors; keep the fetched text usable.
        }
      }
    }
    if (superseded()) return _latestChapterText(chapter);
    if (mounted) _rememberChapter(chapter.itemId, text);
    return (text: text, fetched: fetched);
  }

  Future<_LoadedChapter> _latestChapterText(Chapter chapter) async {
    final cached = _chapterCache[chapter.itemId];
    return cached == null
        ? _loadChapterText(chapter)
        : (text: cached, fetched: false);
  }

  Future<void> _prefetchAround(int index) async {
    final nearby = <Chapter>[
      if (index > 0) widget.chapters[index - 1],
      if (index + 1 < widget.chapters.length) widget.chapters[index + 1],
    ];
    await Future.wait(
      nearby.map((chapter) async {
        try {
          await _chapterText(chapter);
        } catch (_) {
          // Prefetch is opportunistic; the foreground load still reports a
          // useful error and offers retry if this chapter is opened later.
        }
      }),
    );
  }

  ReaderChapterLayout _prepareLayout(BoxConstraints constraints) {
    final spec = ReaderLayoutSpec(
      viewport: constraints.biggest,
      textScaler: MediaQuery.textScalerOf(context),
      preferences: _preferences,
      fontFamily:
          _fontFamily ?? Theme.of(context).textTheme.bodyLarge?.fontFamily,
    );
    if (_chapterLayout?.spec == spec &&
        _layoutMode == _preferences.pageMode &&
        _layoutIdeasRevision == _ideasRevision) {
      return _chapterLayout!;
    }
    // Reuse the measured text layout only when nothing that feeds it changed.
    // Switching page mode keeps the same spec and page-insensitive measurements,
    // so it must not re-measure — but a change in paragraph bubbles must.
    final reusable =
        _chapterLayout?.spec == spec && _layoutIdeasRevision == _ideasRevision;
    final layout = reusable
        ? _chapterLayout!
        : ReaderChapterLayout(
            title: _chapter.title,
            content: _chapterContent,
            spec: spec,
            paragraphBubbles: _ideas.bubbleCounts,
            paragraphBubbleVariants: _ideas.bubbleVariants,
            bubbleBuilder: _buildParagraphBubble,
          );
    _layoutIdeasRevision = _ideasRevision;
    final initialRestore = _needsRestore;
    final restored = initialRestore
        ? layout.restore(
            _savedPosition,
            chapterId: _chapter.itemId,
            startAtEnd: _requestedStartAtEnd,
            paged: _paged,
          )
        : (
            textOffset: _textOffset,
            scroll: layout.scrollForTextOffset(_textOffset),
          );
    _chapterLayout = layout;
    _layoutMode = _preferences.pageMode;
    _textOffset = restored.textOffset;
    _pageIndex = layout.pageForOffset(_textOffset);
    _needsRestore = false;
    _progressReady = false;
    final revision = ++_layoutRevision;
    final generation = _loadGeneration;
    // Layout and restoration must both finish before a new snapshot may save.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _loadGeneration ||
          revision != _layoutRevision ||
          !identical(layout, _chapterLayout)) {
        return;
      }
      if (!_paged) {
        if (!_scrollController.hasClients) return;
        _scrollController.jumpTo(
          restored.scroll.clamp(0, _scrollController.position.maxScrollExtent),
        );
      }
      setState(() => _progressReady = true);
      if (_appActive && !_sessionActive) {
        _sessionActive = true;
        _readStart = DateTime.now();
      }
      unawaited(_persistProgress(createHistory: initialRestore));
    });
    return layout;
  }

  void _onScroll() {
    _saveTimer?.cancel();
    if (!_progressReady || _paged) return;
    _captureScrollProgress(updateTextOffset: true);
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _settleReadTime();
      unawaited(_persistProgress());
    });
  }

  /// Settles the reading-time delta since the last event, legado-style:
  /// the time between this event and the previous one counts as reading.
  void _settleReadTime() {
    if (!_sessionActive || _content.isEmpty) return;
    final now = DateTime.now();
    final delta = now.difference(_readStart).inMilliseconds / 1000;
    if (delta >= 1) {
      unawaited(
        _readerStore
            .accumulateReadTime(widget.bookId, 'book', delta)
            .catchError((_) {}),
      );
    }
    _readStart = now;
  }

  void _captureScrollProgress({bool updateTextOffset = false}) {
    final layout = _chapterLayout;
    if (_paged) {
      if (layout != null) {
        _lastPosition = layout.scrollForTextOffset(_textOffset);
        _lastMaxScroll = layout.maxScroll;
      }
      return;
    }
    if (!_scrollController.hasClients) return;
    _lastPosition = _scrollController.offset;
    _lastMaxScroll = _scrollController.position.maxScrollExtent;
    if (updateTextOffset && layout != null) {
      _textOffset = layout.textOffsetAtScroll(_lastPosition);
    }
  }

  void _onPageChanged(int page) {
    if (!_progressReady || _changingChapter || page == _pageIndex) return;
    setState(() {
      _pageIndex = page;
      _textOffset = _chapterLayout!.pages[page].start;
    });
    _settleReadTime();
    unawaited(_persistProgress());
  }

  Future<void> _pageBoundary(int direction) async {
    if (!_progressReady || _changingChapter || _loading) return;
    if (direction < 0) {
      if (_index == 0) {
        _showMessage('已是第一页');
      } else {
        await _prev(startAtEnd: true);
      }
    } else {
      final canAdvance = _index < widget.chapters.length - 1;
      await _next();
      // Only stop when the book truly has no next chapter — entering the last
      // chapter must NOT cut narration short.
      if (_ttsActive && !canAdvance) {
        await _stopTtsRead();
      }
    }
  }

  Future<void> _persistProgress({bool createHistory = false}) async {
    if (!_progressReady) return;
    // The scrollable may already be detached when the reader is disposed.
    _captureScrollProgress();
    final index = _index;
    final chapterId = _chapter.itemId;
    final position = _lastPosition;
    final max = _lastMaxScroll;
    final progress = _chapterProgress(
      position: position,
      maxScroll: max,
      index: index,
    );
    final entry = {
      'id': widget.bookId,
      'kind': 'book',
      'title': widget.title,
      'bookId': widget.bookId,
      'chapterId': chapterId,
      'episode': index,
      'position': position,
      'maxScroll': max,
      'positionVersion': 2,
      'textOffset': _textOffset,
      'progress': progress,
      'cover': widget.cover,
      'time': DateTime.now().millisecondsSinceEpoch,
    };
    await _history.save(entry, createHistory: createHistory);
  }

  double _chapterProgress({double? position, double? maxScroll, int? index}) {
    if (widget.chapters.isEmpty) return 0;
    if (_paged) {
      final pageCount = _chapterLayout?.pages.length ?? 1;
      final fraction = pageCount > 1 ? _pageIndex / (pageCount - 1) : 0.0;
      return ((index ?? _index) + fraction) / widget.chapters.length;
    }
    final fraction =
        (maxScroll ??
                (_scrollController.hasClients
                    ? _scrollController.position.maxScrollExtent
                    : 0)) >
            0
        ? (position ??
                  (_scrollController.hasClients
                      ? _scrollController.offset
                      : 0)) /
              (maxScroll ?? _scrollController.position.maxScrollExtent)
        : 0.0;
    return ((index ?? _index) + fraction.clamp(0.0, 1.0)) /
        widget.chapters.length;
  }

  Future<void> _prev({bool startAtEnd = false}) async {
    if (_index <= 0 || _changingChapter) return;
    _changingChapter = true;
    try {
      _settleReadTime();
      await _persistProgress();
      if (!mounted) return;
      setState(() => _index--);
      await _load(startAtEnd: startAtEnd);
    } finally {
      _changingChapter = false;
    }
  }

  Future<void> _next() async {
    if (_changingChapter) return;
    if (_index >= widget.chapters.length - 1) {
      _showMessage('已是最后一章');
      return;
    }
    _changingChapter = true;
    try {
      _settleReadTime();
      await _persistProgress();
      if (!mounted) return;
      setState(() => _index++);
      await _load();
    } finally {
      _changingChapter = false;
    }
  }

  Future<void> _jumpToChapter(int index) async {
    if (_changingChapter ||
        index == _index ||
        index < 0 ||
        index >= widget.chapters.length) {
      return;
    }
    _changingChapter = true;
    try {
      _settleReadTime();
      await _persistProgress();
      if (!mounted) return;
      setState(() {
        _index = index;
        _chapterSeekValue = null;
      });
      await _load();
    } finally {
      _changingChapter = false;
    }
  }

  Future<void> _turnPage(int direction) async {
    if (_loading || !_progressReady || _changingChapter) return;
    if (_paged) {
      await _pagedKey.currentState?.turnPage(direction);
      return;
    }
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    const boundaryTolerance = 2.0;
    if (direction < 0 &&
        position.pixels <= position.minScrollExtent + boundaryTolerance) {
      await _prev(startAtEnd: true);
      return;
    }
    if (direction > 0 &&
        position.pixels >= position.maxScrollExtent - boundaryTolerance) {
      await _next();
      return;
    }

    final delta = position.viewportDimension * 0.86 * direction;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    await _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _toggleControls() {
    _stopAutoTurn();
    unawaited(_stopTtsRead());
    if (!_controlsVisible) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
    setState(() => _controlsVisible = !_controlsVisible);
  }

  void _previewPreferences(ReaderPreferences preferences) {
    _preferencesDirty = true;
    final fontChanged = preferences.fontPath != _preferences.fontPath;
    setState(() {
      _preferences = preferences.normalized();
      if (_preferences.themePreset != ReaderThemePreset.dark) {
        _dayTheme = _preferences.themePreset;
      }
    });
    if (fontChanged) unawaited(_loadFont(preferences.fontPath));
  }

  Future<void> _showAppearanceSettings() async {
    setState(() => _controlsVisible = false);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => ReaderAppearanceSheet(
        initialValue: _preferences,
        onChanged: _previewPreferences,
        onPickFont: _pickFont,
      ),
    );
    await _savePreferences();
  }

  void _toggleNightTheme() {
    final nextPreset = _preferences.themePreset == ReaderThemePreset.dark
        ? _dayTheme
        : ReaderThemePreset.dark;
    _previewPreferences(_preferences.copyWith(themePreset: nextPreset));
    unawaited(_savePreferences());
  }

  Future<void> _showDirectory() async {
    setState(() => _controlsVisible = false);
    Set<String> cachedIds = {};
    try {
      cachedIds = await _diskCache.cachedChapterIds(widget.bookId);
    } catch (_) {}
    if (!mounted) return;
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: _preferences.themePreset.panelColor,
      builder: (context) => Theme(
        data: _preferences.themePreset.theme(Theme.of(context)),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.78,
          child: _ChapterDirectorySheet(
            chapters: widget.chapters,
            currentIndex: _index,
            cachedIds: cachedIds,
          ),
        ),
      ),
    );
    if (selected != null && mounted) await _jumpToChapter(selected);
  }

  Future<void> _showCache() {
    setState(() => _controlsVisible = false);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: _preferences.themePreset.panelColor,
      builder: (context) => Theme(
        data: _preferences.themePreset.theme(Theme.of(context)),
        child: ChapterCacheSheet(
          book: _cachedBook,
          currentIndex: _index,
          cache: _diskCache,
          loader: _fetchChapter,
          onContentAvailable: _onChapterContentAvailable,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: _errorView(),
      );
    }
    final preset = _preferences.themePreset;
    final overlayStyle = preset.isDark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    return PopScope<Object?>(
      canPop: !_controlsVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _controlsVisible) _toggleControls();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle.copyWith(
          statusBarColor: preset.backgroundColor,
          systemNavigationBarColor: preset.backgroundColor,
        ),
        child: Theme(
          data: preset.theme(Theme.of(context)),
          child: Scaffold(
            backgroundColor: preset.backgroundColor,
            body: Stack(
              fit: StackFit.expand,
              children: [
                SafeArea(
                  child: Column(
                    children: [
                      if (_preferences.showReadingInfo)
                        GestureDetector(
                          onTap: _toggleControls,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: preset.mutedTextColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Flexible(
                                  child: Text(
                                    _chapter.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: TextStyle(
                                      color: preset.mutedTextColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Expanded(
                        child: SizedBox.expand(
                          key: _viewportKey,
                          child: _buildContent(preset),
                        ),
                      ),
                      if (_preferences.showReadingInfo)
                        ListenableBuilder(
                          listenable: _scrollController,
                          builder: (context, _) => ReaderStatusBar(
                            key: const ValueKey('reader-status-bar'),
                            preset: preset,
                            status: _deviceStatus,
                            progress: _chapterProgress(),
                            chapterIndex: _index,
                            chapterCount: widget.chapters.length,
                            paged: _paged,
                            pageIndex: _chapterLayout == null
                                ? null
                                : _pageIndex,
                            pageCount: _chapterLayout?.pages.length,
                          ),
                        ),
                    ],
                  ),
                ),
                _menuEdge(top: true, child: _buildToolbar(preset)),
                _menuEdge(top: false, child: _buildReaderControls(preset)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuEdge({required bool top, required Widget child}) => Positioned(
    top: top ? 0 : null,
    bottom: top ? null : 0,
    left: 0,
    right: 0,
    child: IgnorePointer(
      ignoring: !_controlsVisible,
      child: ExcludeSemantics(
        excluding: !_controlsVisible,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween<Offset>(
              begin: Offset(0, top ? -1 : 1),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
            children: [...previousChildren, ?currentChild],
          ),
          child: _controlsVisible ? child : const SizedBox.shrink(),
        ),
      ),
    ),
  );

  Widget _buildToolbar(ReaderThemePreset preset) => Material(
    key: const ValueKey('reader-toolbar'),
    color: preset.panelColor,
    elevation: 2,
    shadowColor: Colors.black12,
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            IconButton(
              tooltip: '返回书籍',
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(Icons.arrow_back_rounded, color: preset.textColor),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: preset.textColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '正在阅读 · 第 ${_index + 1} 章',
                    style: TextStyle(
                      color: preset.mutedTextColor,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '收起阅读菜单',
              onPressed: _toggleControls,
              icon: Icon(
                Icons.keyboard_arrow_up_rounded,
                color: preset.textColor,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildContent(ReaderThemePreset preset) {
    if (_loading || _error != null) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggleControls,
        child: _loading
            ? Center(
                child: CircularProgressIndicator(color: preset.accentColor),
              )
            : _errorView(textColor: preset.textColor),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _prepareLayout(constraints);
        return GestureDetector(
          key: const ValueKey('reader-page-surface'),
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) {
            if (_autoTurnTimer != null || _ttsActive) {
              _stopAutoTurn();
              unawaited(_stopTtsRead());
            } else if (_controlsVisible) {
              _toggleControls();
            } else if (details.localPosition.dx < constraints.maxWidth / 3) {
              _pauseListenFollow();
              _turnPage(-1);
            } else if (details.localPosition.dx >
                constraints.maxWidth * 2 / 3) {
              _pauseListenFollow();
              _turnPage(1);
            } else {
              _toggleControls();
            }
          },
          child: _paged
              ? ReaderPagedView(
                  key: _pagedKey,
                  layout: layout,
                  pageIndex: _pageIndex,
                  hasPreviousChapter: _index > 0,
                  hasNextChapter: _index < widget.chapters.length - 1,
                  onPageChanged: _onPageChanged,
                  onBoundary: _pageBoundary,
                  onDragStart: _hideControlsOnDrag,
                  turnStyle: _preferences.pageTurnStyle,
                  backgroundColor: preset.backgroundColor,
                  endPage: _buildChapterEndPage(preset),
                  startPage: _buildChapterStartPage(preset),
                  onBoundaryLanded: (direction) {
                    // 章末是朗读的终点: land on it stops the TTS chain even
                    // though _pageIndex never reports boundary pages.
                    if (direction > 0 && _ttsActive) {
                      unawaited(_stopTtsRead());
                    }
                  },
                  imageProviderFactory: widget.imageProviderFactory,
                )
              : _buildScrollContent(layout),
        );
      },
    );
  }

  /// 章末页: shown as the trailing page of a finished chapter — the chapter's
  /// comment entry (the ideas response's end bucket) plus the next-chapter
  /// action, the official 章末章评 landing without its circle/ad modules.
  Widget _buildChapterEndPage(ReaderThemePreset preset) {
    final endBucket = _chapterEndParagraph();
    final commentCount = _ideas.total;
    return ColoredBox(
      color: preset.backgroundColor,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '本章完',
              style: TextStyle(color: preset.mutedTextColor, fontSize: 13),
            ),
            const SizedBox(height: 20),
            if (commentCount > 0 && endBucket != null)
              FilledButton.tonal(
                key: const ValueKey('reader-chapter-comments'),
                onPressed: () =>
                    unawaited(_showIdeas(focusParaIndex: endBucket)),
                child: Text('查看本章评论 · $commentCount'),
              ),
            const SizedBox(height: 12),
            if (_index < widget.chapters.length - 1)
              FilledButton(
                onPressed: () => unawaited(_next()),
                child: const Text('下一章'),
              ),
          ],
        ),
      ),
    );
  }

  /// 章首页: landing page for flipping backwards past the first page.
  Widget _buildChapterStartPage(ReaderThemePreset preset) => ColoredBox(
    color: preset.backgroundColor,
    child: Center(
      child: _index > 0
          ? FilledButton(
              onPressed: () => unawaited(_prev(startAtEnd: true)),
              child: const Text('上一章'),
            )
          : null,
    ),
  );

  /// The chapter-end aggregate bucket: the ideas response's greatest paragraph
  /// key (e.g. para 10000), which the official client opens for 章末章评.
  int? _chapterEndParagraph() =>
      _ideas.paragraphs.isEmpty ? null : _ideas.paragraphs.last.paraIndex;

  void _hideControlsOnDrag() {
    _stopAutoTurn();
    unawaited(_stopTtsRead());
    _pauseListenFollow();
    if (_controlsVisible) setState(() => _controlsVisible = false);
  }

  Widget _buildScrollContent(ReaderChapterLayout layout) {
    final spec = layout.spec;
    // The scroll list re-renders the measured span, so the bubble is already in
    // it. Its size still depends on this list's own constraints, and the
    // painter's placeholder was measured at spec.width — the same width, so the
    // two agree without a second measurement pass.
    return NotificationListener<ScrollStartNotification>(
      onNotification: (notification) {
        if (notification.dragDetails != null) _hideControlsOnDrag();
        return false;
      },
      child: ListView.builder(
        key: const ValueKey('reader-paragraph-list'),
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
          spec.horizontalPadding,
          spec.verticalPadding,
          spec.horizontalPadding,
          spec.verticalPadding + 32,
        ),
        itemCount: layout.blocks.length + 1,
        // Exact extents let a distant saved text position restore in one frame;
        // a lazy variable-height list otherwise only estimates its scroll range.
        itemExtentBuilder: (index, _) => index < layout.blocks.length
            ? layout.blocks[index].lines.isEmpty
                  ? 0
                  : layout.blocks[index].height + spec.paragraphSpacing
            : spec.footerHeight,
        itemBuilder: (context, itemIndex) {
          if (itemIndex < layout.blocks.length) {
            if (layout.blocks[itemIndex].lines.isEmpty) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: EdgeInsets.only(bottom: spec.paragraphSpacing),
              child: ReaderBlockContent(
                block: layout.blocks[itemIndex],
                spec: spec,
                imageProviderFactory: widget.imageProviderFactory,
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: const Icon(Icons.chevron_left, size: 18),
                    label: const Text(
                      '上一章',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, height: 1.4),
                    ),
                    onPressed: _index > 0
                        ? () => _prev(startAtEnd: true)
                        : null,
                  ),
                ),
                const SizedBox(width: 16),
                if (_ideas.isNotEmpty)
                  OutlinedButton.icon(
                    key: const ValueKey('reader-scroll-chapter-comments'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => unawaited(
                      _showIdeas(focusParaIndex: _chapterEndParagraph()),
                    ),
                    icon: const Icon(Icons.forum_outlined, size: 18),
                    label: Text(
                      '本章评论 ${_ideas.total}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, height: 1.4),
                    ),
                  ),
                if (_ideas.isNotEmpty) const SizedBox(width: 16),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: const Icon(Icons.chevron_right, size: 18),
                    label: const Text(
                      '下一章',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, height: 1.4),
                    ),
                    onPressed: _index < widget.chapters.length - 1
                        ? _next
                        : null,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildReaderControls(ReaderThemePreset preset) {
    final seekValue = _chapterSeekValue ?? _index.toDouble();
    final previewIndex = seekValue.round().clamp(0, widget.chapters.length - 1);
    return ReaderControls(
      key: const ValueKey('reader-controls'),
      preferences: _preferences,
      chapterIndex: previewIndex,
      chapterCount: widget.chapters.length,
      chapterTitle: widget.chapters[previewIndex].title,
      seekValue: seekValue,
      deviceAvailable: _deviceAvailable,
      systemBrightness: _deviceStatus.systemBrightness,
      onPrevious: _index > 0 ? () => _prev(startAtEnd: true) : null,
      onNext: _index < widget.chapters.length - 1 ? _next : null,
      onSeek: (value) => setState(() => _chapterSeekValue = value),
      onSeekEnd: (value) {
        setState(() => _chapterSeekValue = null);
        _jumpToChapter(value.round());
      },
      onBrightness: _changeBrightness,
      onBrightnessEnd: () => unawaited(_savePreferences()),
      onFollowSystem: () {
        _changeBrightness(
          _preferences.followSystemBrightness
              ? _deviceStatus.systemBrightness ?? _preferences.brightness
              : _preferences.brightness,
          followSystem: !_preferences.followSystemBrightness,
        );
        unawaited(_savePreferences());
      },
      onDirectory: _showDirectory,
      onNight: _toggleNightTheme,
      onAppearance: _showAppearanceSettings,
      onCache: _showCache,
      autoTurnActive: _autoTurnTimer != null,
      onAutoTurn: _toggleAutoTurn,
      ttsActive: _ttsActive,
      onTtsRead: _toggleTtsRead,
    );
  }

  Widget _errorView({Color? textColor}) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _error ?? '加载失败',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textColor ?? Theme.of(context).colorScheme.error,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => _load(startAtEnd: _requestedStartAtEnd),
            child: const Text('重试'),
          ),
        ],
      ),
    ),
  );
}

class _ChapterDirectorySheet extends StatefulWidget {
  final List<Chapter> chapters;
  final int currentIndex;
  final Set<String> cachedIds;

  const _ChapterDirectorySheet({
    required this.chapters,
    required this.currentIndex,
    required this.cachedIds,
  });

  @override
  State<_ChapterDirectorySheet> createState() => _ChapterDirectorySheetState();
}

class _ChapterDirectorySheetState extends State<_ChapterDirectorySheet> {
  static const _itemExtent = 58.0;

  final TextEditingController _searchController = TextEditingController();
  late final ScrollController _scrollController;
  bool _reversed = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    final initialOffset = (widget.currentIndex * _itemExtent - 120).clamp(
      0.0,
      double.infinity,
    );
    _scrollController = ScrollController(initialScrollOffset: initialOffset);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<int> get _visibleIndexes {
    Iterable<int> indexes = Iterable<int>.generate(widget.chapters.length);
    if (_reversed) indexes = indexes.toList(growable: false).reversed;
    final query = _query.trim().toLowerCase();
    if (query.isNotEmpty) {
      indexes = indexes.where((index) {
        final chapter = widget.chapters[index];
        return chapter.title.toLowerCase().contains(query) ||
            '${index + 1}'.contains(query);
      });
    }
    return indexes.toList(growable: false);
  }

  void _toggleOrder() {
    setState(() => _reversed = !_reversed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients || _query.isNotEmpty) return;
      final displayIndex = _reversed
          ? widget.chapters.length - 1 - widget.currentIndex
          : widget.currentIndex;
      final target = (displayIndex * _itemExtent - 120).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final indexes = _visibleIndexes;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '目录 · ${widget.chapters.length} 章',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: _reversed ? '切换为正序' : '切换为倒序',
                onPressed: _toggleOrder,
                icon: Icon(
                  _reversed ? Icons.arrow_upward : Icons.arrow_downward,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              hintText: '搜索章节名或序号',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空',
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(Icons.close),
                    ),
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: indexes.isEmpty
              ? const Center(child: Text('没有匹配的章节'))
              : ListView.builder(
                  controller: _scrollController,
                  itemExtent: _itemExtent,
                  itemCount: indexes.length,
                  itemBuilder: (context, position) {
                    final index = indexes[position];
                    final chapter = widget.chapters[index];
                    final current = index == widget.currentIndex;
                    return Material(
                      color: current
                          ? scheme.primaryContainer.withValues(alpha: 0.72)
                          : Colors.transparent,
                      child: ListTile(
                        dense: true,
                        selected: current,
                        onTap: () => Navigator.pop(context, index),
                        leading: SizedBox(
                          width: 42,
                          child: Text(
                            '${index + 1}',
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              color: current
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                              fontWeight: current
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        title: Text(
                          chapter.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.cachedIds.contains(chapter.itemId))
                              const Tooltip(
                                message: '已缓存',
                                child: Icon(
                                  Icons.offline_pin_outlined,
                                  size: 18,
                                ),
                              ),
                            if (current)
                              Icon(Icons.my_location, color: scheme.primary),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
