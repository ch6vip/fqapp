import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book_comment.dart';
import '../models/chapter_ideas.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/chapter_cache_store.dart';
import '../services/chapter_text_formatter.dart';
import '../services/library_store.dart';
import '../services/listening_session.dart';
import '../services/reader_device.dart';
import '../services/reader_history.dart';
import '../services/reader_preferences.dart';
import '../services/reader_underline_store.dart';
import '../widgets/chapter_cache_sheet.dart';
import '../widgets/reader/reader_appearance_sheet.dart';
import '../widgets/reader/reader_bubble.dart';
import '../widgets/reader/reader_chapter_layout.dart';
import '../widgets/reader/reader_controls.dart';
import '../widgets/reader/reader_illustration.dart';
import '../widgets/reader/reader_ideas_sheet.dart';
import '../widgets/reader/reader_paged_view.dart';
import '../widgets/reader/reader_paragraph_menu.dart';
import '../widgets/reader/reader_status_bar.dart';
import '../widgets/reader/reader_text_selection.dart';
import '../widgets/reader/reader_theme.dart';
import 'audio_page.dart';

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

  /// Local 划线 storage. Defaults to the device-wide box.
  final ReaderUnderlineStore? underlineStore;

  /// Paragraph ideas for the current chapter. When both this and
  /// [commentResolver] are null the reader fetches them itself, unless a
  /// [chapterCache] was injected (an injected cache marks the caller as
  /// driving its own data).
  final ChapterIdeasLoader? ideasLoader;

  /// Resolves one paragraph's comment bodies. See [ParagraphCommentResolver].
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
    this.underlineStore,
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
    if (!mounted ||
        !_appActive ||
        ModalRoute.of(context)?.isCurrent != true ||
        !_preferences.volumeKeyTurn ||
        _controlsVisible) {
      return false;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (_paged) {
      if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
        _pauseListenFollow();
        _stopAutoTurn();
        unawaited(_turnPage(1));
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
        _pauseListenFollow();
        _stopAutoTurn();
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

  void _autoTurnStep() {
    if (!mounted) return _stopAutoTurn();
    if (_loading || !_progressReady || _changingChapter) return;
    if (_index == widget.chapters.length - 1) {
      final atEnd = _paged
          ? _pagedKey.currentState?.isAtEndPage == true
          : _scrollController.hasClients &&
                _scrollController.position.pixels >=
                    _scrollController.position.maxScrollExtent - 2;
      if (atEnd) return _stopAutoTurn();
    }
    // Share the manual page-turn path so scrolling also crosses chapters.
    unawaited(_turnPage(1));
  }

  double? _chapterSeekValue;
  int _loadGeneration = 0;
  // Legado-style reading time: deltas are settled at scroll stops, chapter
  // switches and dispose, so no background timer is needed.
  DateTime _readStart = DateTime.now();
  bool _sessionActive = false;
  bool _appActive = true;
  bool _changingChapter = false;

  /// Height of the reader's own bottom toolbar (目录/夜间/听书/设置) as measured
  /// on device, including its safe-area inset. The paragraph action bar keeps
  /// clear of it so a long press near the page foot flips above the line
  /// instead of landing on top of the controls.
  static const _bottomBarHeight = 74.0;
  /// Set while 从本段听 is waiting on a timeline fetch, so a repeated long-press
  /// cannot stack a second listening page (and a second player) on top.
  bool _openingListening = false;
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

  /// Paragraph ids of this chapter carrying a locally saved 划线.
  Set<int> _underlines = const {};

  /// Locally saved character-range 划线 of this chapter (the selection-model
  /// records; paragraph ones live in [_underlines]).
  List<ReaderRangeUnderline> _rangeUnderlines = const [];

  /// The live text selection — a whole paragraph right after a long press,
  /// then reshaped character-by-character by dragging a handle. Cleared on an
  /// outside tap, a scroll or a page turn, like the official selection.
  // Note: 选区模型（坐标空间、几何注册表、非模态操作条）—
  // 见 .agents/notes/implemented/feature/2026-09-19-reader-selection-model.md
  ReaderTextSelection? _selection;

  /// Palette plus hit-test registry, rebuilt per layout so stale blocks can
  /// never answer a drag from the previous chapter.
  ReaderSelectionScope? _marksScope;
  ReaderChapterLayout? _marksScopeLayout;
  final _selectionOverlayKey = GlobalKey();

  /// True while the action bar is up in the page overlay. It is non-modal —
  /// the official PopupWindow is too — so the drag handles stay touchable
  /// while it shows, and a tap outside it cancels the selection.
  bool _selectionBarOpen = false;

  /// The anchor (window coordinates) the bar was opened with: the long-press
  /// point or the handle position at drag end.
  Offset _selectionBarAnchor = Offset.zero;

  /// True while a long-press drag is reshaping the selection without the
  /// finger ever having grabbed a handle (官方不抬手拖动).
  bool _longPressDragging = false;

  int _underlineRevision = 0;
  int _layoutUnderlineRevision = -1;
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

  /// Long press on a paragraph: select it whole and open the action bar.
  ///
  /// Identity comes from [ReaderContentBlock.textId], which falls back to the
  /// paragraph's ordinal when the markup carried no `idx` (the plain-text
  /// `/api/content` path). Requiring `idx` here is what used to make a long
  /// press do literally nothing on those chapters.
  ///
  /// Note: .agents/notes/implemented/feature/2026-09-18-reader-paragraph-actions.md
  Future<void> _onParagraphLongPress(
    ReaderContentBlock block,
    Offset position,
  ) async {
    if (block.isTitle || block.isImage || block.textId == null) return;
    _longPressDragging = false;
    // 选中文字,暂停自动翻页 — the official selection helper does the same
    // (selection/h.java#a).
    _stopAutoTurn();
    // A second long press replaces the selection; the old bar pops without
    // cancelling — the new selection takes over.
    _closeSelectionBar(clearSelection: false);
    if (!mounted) return;
    // 官方 ke5.a.a 的 SelectTextByRange 分支: long-pressing text that already
    // carries a range underline restores that exact range instead of the
    // whole paragraph.
    ReaderRangeUnderline? hit;
    final pressed = _marksScope?.geometry.chapterOffsetAt(position);
    if (pressed != null) {
      for (final underline in _rangeUnderlines) {
        if (underline.start <= pressed && pressed < underline.end) {
          hit = underline;
          break;
        }
      }
    }
    final selection = ReaderTextSelection(
      start: hit?.start ?? block.start,
      end: hit?.end ?? block.end,
    );
    setState(() {
      _selection = selection.copyWith(
        isWholeParagraph: _isWholeParagraphSelection(selection),
      );
    });
    _updateHandlePositions();
    _openSelectionBar(anchor: position);
  }

  /// 官方的不抬手拖动 (TTMarkingHelper 的 MOVE 分支): 长按选中后手指继续
  /// 移动,选区跟着手指逐字符重算,第一帧起收条;拖哪个点按手指落在选区的
  /// 上半还是下半推断 (D() 的中点规则),不必精确抓到控点。
  void _onParagraphLongPressMoveUpdate(Offset global) {
    final selection = _selection;
    if (selection == null || !selection.isValid) return;
    if (!_longPressDragging) {
      _longPressDragging = true;
      _closeSelectionBar(clearSelection: false);
    }
    _onHandleDrag(_dragIsStartBound(global), global);
  }

  void _onParagraphLongPressEnd(Offset global) {
    if (!_longPressDragging) return;
    _longPressDragging = false;
    _onHandleDragEnd(false, global);
  }

  /// 官方 D(): finger above the selection's vertical midpoint drags the start
  /// bound, below it the end bound.
  bool _dragIsStartBound(Offset global) {
    final startTop = _selectionBoundGlobal(isStart: true)?.dy;
    final endBottom = _selectionBoundGlobal(isStart: false)?.dy;
    if (startTop == null || endBottom == null) return true;
    return global.dy < (startTop + endBottom) / 2;
  }

  /// Global position of one bound's anchor — the start bound's line top or
  /// the end bound's line bottom — or null when its block is not mounted.
  Offset? _selectionBoundGlobal({required bool isStart}) {
    final selection = _selection;
    final layout = _chapterLayout;
    final scope = _marksScope;
    if (selection == null || layout == null || scope == null) return null;
    final textOffset = isStart ? selection.start : selection.end - 1;
    final block = layout.blockForAnchor(textOffset, isStart: isStart);
    if (block == null) return null;
    final entry = scope.geometry.entryFor(block.index);
    if (entry == null) return null;
    final anchor = selectionAnchor(
      block: block,
      painter: entry.painter,
      textOffset: _boundOffsetInBlock(textOffset, block, isStart: isStart),
      isStart: isStart,
      columnWidth: layout.spec.width,
    );
    return entry.box.localToGlobal(anchor);
  }

  /// Opens the action bar for the current selection. The bar lives in the
  /// page's own overlay Stack — non-modal, like the official PopupWindow — so
  /// the drag handles stay touchable while it is up, and a tap outside it
  /// reaches the page surface, which cancels the selection.
  void _openSelectionBar({required Offset anchor}) {
    final selection = _selection;
    if (selection == null || !selection.isValid) return;
    setState(() {
      _selectionBarAnchor = anchor;
      _selectionBarOpen = true;
    });
  }

  /// Hides the action bar; [clearSelection] also cancels the selection
  /// (outside tap, scroll, page turn — anything but a handle drag).
  void _closeSelectionBar({required bool clearSelection}) {
    if (clearSelection) _clearSelection();
    if (!_selectionBarOpen) return;
    setState(() => _selectionBarOpen = false);
  }

  /// The action bar overlay, or null while no selection is active. Geometry
  /// re-resolves per build so the bar always clears the system bars and the
  /// reader's own bottom toolbar.
  ///
  // Note: 选区条坐标系、段落时间轴映射与批量审查回退的来龙去脉 —
  // 见 .agents/notes/implemented/bug-fix/2026-09-19-cross-review-batch-fixes.md
  /// [windowPadding] is the *window's* safe area, captured above the reader's
  /// own SafeArea: the anchor is a window coordinate while the bar is
  /// positioned inside the overlay Stack below that SafeArea (and below the
  /// reading-info row), so the anchor is converted into overlay-local space
  /// and the flip/clamp maths run against the overlay's own size. Using the
  /// window geometry directly shifted the bar one status-bar height down on
  /// every device whose top inset is non-zero.
  Widget? _selectionBar(ReaderThemePreset preset, EdgeInsets windowPadding) {
    final selection = _selection;
    if (!_selectionBarOpen || selection == null || !selection.isValid) {
      return null;
    }
    final media = MediaQuery.of(context);
    final underlined = _selectionUnderlined;
    var anchor = _selectionBarAnchor;
    var view = media.size;
    var safeArea = media.padding;
    var avoidBottom = _controlsVisible ? _bottomBarHeight : 0.0;
    final overlayBox =
        _selectionOverlayKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlayBox != null && overlayBox.attached) {
      anchor = overlayBox.globalToLocal(_selectionBarAnchor);
      view = overlayBox.size;
      // The system insets are already consumed by the outer SafeArea, so the
      // overlay only needs a margin of its own; the reader's bottom toolbar
      // height includes the bottom inset, so subtract what SafeArea padded.
      safeArea = EdgeInsets.zero;
      avoidBottom = (avoidBottom - windowPadding.bottom).clamp(
        0.0,
        double.infinity,
      );
    }
    final (position, below) = ReaderParagraphMenu.resolvePosition(
      anchor: anchor,
      paragraphScoped: selection.isWholeParagraph,
      view: view,
      safeArea: safeArea,
      underlined: underlined,
      avoidBottom: avoidBottom,
    );
    return Positioned(
      key: const ValueKey('reader-selection-bar'),
      left: position.dx,
      top: position.dy,
      child: ReaderParagraphMenu(
        underlined: underlined,
        paragraphScoped: selection.isWholeParagraph,
        isDark: preset.isDark,
        belowAnchor: below,
        onAction: (action) {
          unawaited(() async {
            await _applySelectionAction(action);
            // Every action consumes the selection, like the official bar.
            if (mounted) _closeSelectionBar(clearSelection: true);
          }());
        },
      ),
    );
  }

  void _clearSelection() {
    _longPressDragging = false;
    if (_selection == null) return;
    setState(() => _selection = null);
  }

  bool get _selectionUnderlined {
    final selection = _selection;
    if (selection == null) return false;
    if (selection.isWholeParagraph) {
      final textId = _chapterLayout?.blockAtOffset(selection.start)?.textId;
      if (textId != null && _underlines.contains(textId)) return true;
    }
    // A range record spanning exactly this selection outranks the paragraph
    // identity: a whole-paragraph drag can produce one, and only the range
    // store can ever remove it again.
    return _rangeUnderlines.any(
      (underline) => underline.coversExactly(selection.start, selection.end),
    );
  }

  Future<void> _applySelectionAction(ReaderParagraphAction action) async {
    final selection = _selection;
    final layout = _chapterLayout;
    if (selection == null || layout == null || !selection.isValid) return;
    switch (action) {
      case ReaderParagraphAction.copy:
        await Clipboard.setData(
          ClipboardData(
            text: layout.textInRange(selection.start, selection.end),
          ),
        );
        if (mounted) _showMessage('已复制');
      case ReaderParagraphAction.listen:
        final block = layout.blockAtOffset(selection.start);
        final textId = block?.textId;
        if (block == null || textId == null) return;
        await _openListening(fromMs: block.startMs, textId: textId);
      case ReaderParagraphAction.underline:
      case ReaderParagraphAction.removeUnderline:
        await _toggleSelectionUnderline(
          add: action == ReaderParagraphAction.underline,
        );
    }
  }

  /// 划线 on the current selection. A whole-paragraph selection keeps the
  /// paragraph-identity store (the pre-selection model, still how saved
  /// marks render); a dragged character range saves a range record.
  Future<void> _toggleSelectionUnderline({required bool add}) async {
    final selection = _selection;
    final layout = _chapterLayout;
    if (selection == null || layout == null || !selection.isValid) return;
    if (selection.isWholeParagraph) {
      final block = layout.blockAtOffset(selection.start);
      // A range record exactly spanning the paragraph (a whole-paragraph
      // drag) must be toggled in the range store — routing to the
      // paragraph-identity store here would strand it, unreachable for
      // 删除划线 forever.
      final hasExactRange = _rangeUnderlines.any(
        (underline) => underline.coversExactly(selection.start, selection.end),
      );
      if (block != null && !hasExactRange) {
        await _toggleUnderline(block, add: add);
        return;
      }
    }
    final store = widget.underlineStore ?? ReaderUnderlineStore.instance;
    final chapterId = _chapter.itemId;
    final loadGeneration = _loadGeneration;
    final existing = _rangeUnderlines
        .where((underline) => underline.coversExactly(selection.start,
            selection.end))
        .toList();
    if (!add && existing.isEmpty) return;
    final record = ReaderRangeUnderline(
      bookId: widget.bookId,
      chapterId: chapterId,
      start: selection.start,
      end: selection.end,
      text: layout.textInRange(selection.start, selection.end),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      if (add) {
        await store.addRange(record);
      } else {
        await store.remove(existing.first.key);
      }
    } catch (_) {
      if (mounted) _showMessage(add ? '划线保存失败，请重试' : '删除划线失败，请重试');
      return;
    }
    // The await can span a chapter switch; appending a record that belongs to
    // the previous chapter would paint it onto the new one (the same guard
    // _loadUnderlines applies to its reads).
    if (!mounted ||
        loadGeneration != _loadGeneration ||
        chapterId != _chapter.itemId) {
      return;
    }
    setState(() {
      if (add) {
        _rangeUnderlines = [..._rangeUnderlines, record]
          ..sort((a, b) => a.start.compareTo(b.start));
      } else {
        _rangeUnderlines = _rangeUnderlines
            .where((underline) => underline.key != existing.first.key)
            .toList();
      }
    });
    _showMessage(add ? '已划线' : '已删除划线');
  }

  Future<void> _toggleUnderline(
    ReaderContentBlock block, {
    required bool add,
  }) async {
    final textId = block.textId;
    if (textId == null) return;
    final store = widget.underlineStore ?? ReaderUnderlineStore.instance;
    final blockIndex = block.index - 1;
    final chapterId = _chapter.itemId;
    final loadGeneration = _loadGeneration;
    try {
      if (add) {
        await store.add(
          ReaderUnderline(
            bookId: widget.bookId,
            chapterId: chapterId,
            paraIndex: block.paraIndex,
            blockIndex: blockIndex,
            text: block.text,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      } else {
        await store.remove(
          ReaderUnderlineStore.keyFor(
            bookId: widget.bookId,
            chapterId: chapterId,
            paraIndex: block.paraIndex,
            blockIndex: blockIndex,
          ),
        );
      }
    } catch (_) {
      if (mounted) _showMessage(add ? '划线保存失败，请重试' : '取消划线失败，请重试');
      return;
    }
    // The await can span a chapter switch; the ids belong to the chapter the
    // underline was toggled in (same guard as _loadUnderlines).
    if (!mounted ||
        loadGeneration != _loadGeneration ||
        chapterId != _chapter.itemId) {
      return;
    }
    setState(() {
      final next = Set<int>.of(_underlines);
      if (add) {
        next.add(textId);
      } else {
        next.remove(textId);
      }
      _underlines = next;
      ++_underlineRevision;
    });
    _showMessage(add ? '已划线' : '已取消划线');
  }

  /// Loads the saved 划线 of this chapter: paragraph ids for the layout and
  /// range records for the mark painter.
  Future<void> _loadUnderlines() async {
    final generation = _loadGeneration;
    final chapterId = _chapter.itemId;
    final store = widget.underlineStore ?? ReaderUnderlineStore.instance;
    Set<int> ids;
    List<ReaderRangeUnderline> ranges;
    try {
      final saved = await store.load(widget.bookId, chapterId);
      ids = {
        for (final entry in saved.values) entry.id,
      };
      ranges = await store.loadRanges(widget.bookId, chapterId);
    } catch (_) {
      ids = const {};
      ranges = const [];
    }
    if (!mounted || generation != _loadGeneration) return;
    if (chapterId != _chapter.itemId) return;
    setState(() {
      _underlines = ids;
      _rangeUnderlines = ranges;
      ++_underlineRevision;
    });
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
        if (_chapterContent.needsRefresh()) {
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
        // Ideas and 划线 belong to the chapter, so they are dropped on every
        // load and fetched again; a stale entry would point at another chapter.
        _ideas = ChapterIdeas.empty;
        _underlines = const {};
        _rangeUnderlines = const [];
        _selection = null;
        _selectionBarOpen = false;
      });
      unawaited(_prefetchAround(_index));
      unawaited(_loadIdeas(chapter, generation));
      unawaited(_loadUnderlines());
      if (!loaded.fetched && content.needsRefresh()) {
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
        _layoutIdeasRevision == _ideasRevision &&
        _layoutUnderlineRevision == _underlineRevision) {
      return _chapterLayout!;
    }
    // Reuse the measured text layout only when nothing that feeds it changed.
    // Switching page mode keeps the same spec and page-insensitive measurements,
    // so it must not re-measure — but bubbles or 划线 must.
    final reusable =
        _chapterLayout?.spec == spec &&
        _layoutIdeasRevision == _ideasRevision &&
        _layoutUnderlineRevision == _underlineRevision;
    final layout = reusable
        ? _chapterLayout!
        : ReaderChapterLayout(
            title: _chapter.title,
            content: _chapterContent,
            spec: spec,
            paragraphBubbles: _ideas.bubbleCounts,
            paragraphBubbleVariants: _ideas.bubbleVariants,
            underlinedParagraphs: _underlines,
            bubbleBuilder: _buildParagraphBubble,
          );
    _layoutIdeasRevision = _ideasRevision;
    _layoutUnderlineRevision = _underlineRevision;
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
    // Turning the page cancels the selection: the handles belong to the text,
    // the action bar's anchor would be stale. Reselecting is one long press.
    _closeSelectionBar(clearSelection: true);
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
      await _next();
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
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SizedBox(
            height:
                (MediaQuery.sizeOf(context).height -
                    MediaQuery.viewInsetsOf(context).bottom) *
                0.78,
            child: _ChapterDirectorySheet(
              chapters: widget.chapters,
              currentIndex: _index,
              cachedIds: cachedIds,
            ),
          ),
        ),
      ),
    );
    if (selected != null && mounted) await _jumpToChapter(selected);
  }

  /// Opens the listening page for the current chapter.
  ///
  /// [fromMs] is the pressed paragraph's place on the spoken timeline the
  /// chapter shipped with (`<span start_time>`), so 从本段听 starts there
  /// instead of at the chapter's opening. [textId] non-null marks the request
  /// as paragraph-anchored: if that paragraph has no timeline the page still
  /// starts at the chapter's beginning rather than resuming old history.
  ///
  /// A cache written before the reader read that timeline carries no start
  /// times. Reading never waits on that; the timeline is fetched here, once,
  /// because the user asked to listen from a paragraph. The fetch is bounded,
  /// and a failure still opens the page at the chapter start.
  Future<void> _openListening({int? fromMs, int? textId}) async {
    final paragraphAnchored = textId != null;
    if (_openingListening) return;
    _openingListening = true;
    final chapter = _chapter;
    final chapterIndex = _index;
    try {
      _stopAutoTurn();
      await _persistProgress();
      if (!mounted) return;
      var startMs = fromMs;
      if (startMs == null &&
          paragraphAnchored &&
          !_chapterContent.timelineChecked) {
        _showMessage('正在获取本段音频…');
        await _refreshCachedChapter(chapter).timeout(
          const Duration(seconds: 12),
          onTimeout: () {},
        );
        // The user may have turned the page while the timeline was in flight.
        // Serving another chapter's paragraph position would start playback at
        // a place nobody asked for.
        if (!mounted || _chapter.itemId != chapter.itemId) return;
        startMs = _paragraphStartMs(textId);
      }
      if (!mounted) return;
      setState(() => _controlsVisible = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AudioPage(
            bookId: widget.bookId,
            title: widget.title,
            cover: widget.cover,
            chapters: widget.chapters,
            startIndex: chapterIndex,
            // A paragraph-anchored request always carries an explicit start:
            // Duration.zero means "this paragraph has no audio, begin at the
            // chapter opening" and must not fall back to saved history.
            startPosition: paragraphAnchored
                ? Duration(milliseconds: startMs ?? 0)
                : null,
            historyStore: widget.readerStore,
          ),
        ),
      );
    } finally {
      _openingListening = false;
    }
  }

  /// The spoken start of the paragraph identified by [textId], when the chapter
  /// carries a timeline.
  ///
  /// [textId] is [ReaderContentBlock.textId]: the upstream `idx` when present,
  /// otherwise the paragraph's ordinal. The ordinal fallback is resolved
  /// against the exact block order the reader laid out — the leading title
  /// stripped, the synthetic title block occupying index 0, image blocks
  /// counted — so a chapter without ids still maps. Walking the raw block
  /// list instead desynced from the layout by one (title) plus however many
  /// images precede a paragraph, and 从本段听 landed on the previous paragraph.
  int? _paragraphStartMs(int textId) {
    final body = _chapterContent.withoutLeadingTitle(_chapter.title);
    // Block 0 is the layout's synthetic title, so the first body element sits
    // at layout index 1 and its fallback id is -(1 + 0) — the same maths
    // ReaderChapterLayout uses for textId.
    var layoutIndex = 1;
    for (final element in body.blocks) {
      if (element is ChapterParagraph) {
        if (paragraphUnderlineId(
              paraIndex: element.paraIndex,
              blockIndex: layoutIndex - 1,
            ) ==
            textId) {
          return element.startMs;
        }
      }
      layoutIndex++;
    }
    return null;
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
    final windowPadding = MediaQuery.paddingOf(context);
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
                          child: _buildContent(preset, windowPadding),
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

  Widget _buildContent(ReaderThemePreset preset, EdgeInsets windowPadding) {
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
        final scope = _marksScopeFor(preset, layout);
        return GestureDetector(
          key: const ValueKey('reader-page-surface'),
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) {
            if (_selection != null) {
              // A tap outside the selection cancels it without turning the
              // page — the official reader behaves the same.
              _closeSelectionBar(clearSelection: true);
              return;
            }
            if (_autoTurnTimer != null) {
              _stopAutoTurn();
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
          child: Stack(
            key: _selectionOverlayKey,
            children: [
              Positioned.fill(
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
                          // _pageIndex never reports boundary pages, so the book end
                          // stops auto turn from here.
                          if (direction > 0 &&
                              _index == widget.chapters.length - 1) {
                            _stopAutoTurn();
                          }
                        },
                        imageProviderFactory: widget.imageProviderFactory,
                        onParagraphLongPress: (block, position) =>
                            unawaited(_onParagraphLongPress(block, position)),
                        onParagraphLongPressMoveUpdate:
                            _onParagraphLongPressMoveUpdate,
                        onParagraphLongPressEnd: _onParagraphLongPressEnd,
                        selectionScope: scope,
                        selection: _selection,
                        rangeUnderlines: _rangeUnderlines,
                      )
                    : _buildScrollContent(layout, scope),
              ),
              ..._selectionHandles(scope),
              ?_selectionBar(preset, windowPadding),
            ],
          ),
        );
      },
    );
  }

  /// The selection scope for the current layout: palette from the active
  /// theme, a fresh hit-test registry per layout so a block from the previous
  /// chapter can never answer a drag.
  ReaderSelectionScope _marksScopeFor(
    ReaderThemePreset preset,
    ReaderChapterLayout layout,
  ) {
    if (_marksScope == null || !identical(_marksScopeLayout, layout)) {
      _marksScope = ReaderSelectionScope(
        geometry: ReaderSelectionGeometry(),
        washColor: preset.selectionWashColor,
        handleColor: preset.selectionHandleColor,
        underlineColor: preset.textColor,
      );
      _marksScopeLayout = layout;
    }
    return _marksScope!;
  }

  /// The drag handles, floated above the content: handles living inside a
  /// block would fall outside every ancestor's hit-test box whenever a bound
  /// sat at the block edge (first line's top, last line's bottom, page foot).
  /// Positions resolve through the geometry registry after layout.
  List<Widget> _selectionHandles(ReaderSelectionScope scope) {
    final selection = _selection;
    if (selection == null || !selection.isValid) return const [];
    final start = _handleOverlayPosition(isStart: true);
    final end = _handleOverlayPosition(isStart: false);
    if (start == null && end == null) return const [];
    final fontSize = _chapterLayout?.spec.bodyStyle.fontSize ?? 16;
    Widget handle(bool isStart, Offset position) {
      final widget = ReaderSelectionHandle(
        isStart: isStart,
        color: scope.handleColor,
        fontSize: fontSize,
        onDragStart: _onHandleDragStart,
        onDragUpdate: (global) => _onHandleDrag(isStart, global),
        onDragEnd: (global) => _onHandleDragEnd(isStart, global),
      );
      return Positioned(
        key: ValueKey('reader-selection-handle-${isStart ? 'start' : 'end'}'),
        left: position.dx - ReaderSelectionHandle.touchWidth / 2,
        top: isStart ? position.dy - widget.height : position.dy,
        child: widget,
      );
    }

    return [
      if (start != null) handle(true, start),
      if (end != null) handle(false, end),
    ];
  }

  /// Overlay-local position of one selection bound's handle anchor, or null
  /// when the bound's block is not mounted (an off-screen page).
  Offset? _handleOverlayPosition({required bool isStart}) {
    final selection = _selection;
    final layout = _chapterLayout;
    final scope = _marksScope;
    if (selection == null || layout == null || scope == null) return null;
    final textOffset = isStart ? selection.start : selection.end - 1;
    final block = layout.blockForAnchor(textOffset, isStart: isStart);
    if (block == null) return null;
    final entry = scope.geometry.entryFor(block.index);
    if (entry == null) return null;
    final anchor = selectionAnchor(
      block: block,
      painter: entry.painter,
      textOffset: _boundOffsetInBlock(textOffset, block, isStart: isStart),
      isStart: isStart,
      columnWidth: layout.spec.width,
    );
    final overlayBox =
        _selectionOverlayKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.attached) return null;
    return overlayBox.globalToLocal(entry.box.localToGlobal(anchor));
  }

  /// [offset] (chapter space) resolved into [block]'s text space, snapping a
  /// separator offset onto the block's first or last real character.
  int _boundOffsetInBlock(
    int offset,
    ReaderContentBlock block, {
    required bool isStart,
  }) {
    return isStart
        ? offset.clamp(block.start, block.end - 1) - block.start
        : (offset + 1 > block.end ? block.end : offset + 1) - 1 - block.start;
  }

  /// Recomputes the handle overlay after the frame that (re)mounted the mark
  /// layers — their registry entries land in a post-frame callback of the
  /// same build, scheduled ahead of this one.
  void _updateHandlePositions() {
    if (_selection == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selection == null) return;
      setState(() {});
    });
  }

  void _onHandleDragStart() {
    // The bar would sit under the finger; pop it, keep the selection.
    _closeSelectionBar(clearSelection: false);
  }

  /// Reshapes the selection to the character under the finger. The drag
  /// starts on a handle but crosses paragraphs, so the point resolves
  /// through the geometry registry, not the handle's own block.
  // Note: 拖动边界对齐官方（非空不变量、分隔符守卫）—
  // 见 .agents/notes/implemented/bug-fix/2026-09-19-selection-drag-boundary.md
  void _onHandleDrag(bool isStart, Offset global) {
    final selection = _selection;
    final layout = _chapterLayout;
    if (selection == null || layout == null) return;
    final offset = _marksScope?.geometry.chapterOffsetAt(global);
    if (offset == null) return;
    final range = layout.selectableTextRange;
    if (range == null) return;
    var next = selection.withBound(
      isStart: isStart,
      offset: offset.clamp(range.$1, range.$2),
      textLength: range.$2,
    );
    // A drag can land a bound on the '\n' separator between two blocks; such
    // a range paints nothing, so grow it onto the next real character — the
    // finger must never hold an invisible selection.
    if (next.isValid &&
        next.end < range.$2 &&
        _selectionPaintsNothing(next)) {
      next = next.copyWith(end: next.end + 1);
    }
    if (next == selection) return;
    setState(() => _selection = next);
  }

  /// True when no text block overlaps [selection] — a range covering only
  /// the separators between blocks.
  bool _selectionPaintsNothing(ReaderTextSelection selection) {
    final layout = _chapterLayout;
    if (layout == null) return true;
    for (final block in layout.blocks) {
      if (block.isTitle || block.isImage) continue;
      if (blockSelectionRange(block, selection.start, selection.end) != null) {
        return false;
      }
    }
    return true;
  }

  void _onHandleDragEnd(bool isStart, Offset global) {
    final selection = _selection;
    if (selection == null || !selection.isValid) {
      _clearSelection();
      return;
    }
    // Whatever the drag did, the range is no longer necessarily the
    // long-pressed paragraph: recompute the flag from the geometry so
    // 从本段听 tracks the real range instead of inheriting the long press.
    setState(
      () => _selection = selection.copyWith(
        isWholeParagraph: _isWholeParagraphSelection(selection),
      ),
    );
    _openSelectionBar(anchor: global);
  }

  /// True when [selection] covers exactly one non-title text block — the
  /// shape a long press creates. Computed, not inherited: a drag that happens
  /// to land on another whole paragraph deserves the same bar.
  bool _isWholeParagraphSelection(ReaderTextSelection selection) {
    final block = _chapterLayout?.blockAtOffset(selection.start);
    return block != null &&
        !block.isTitle &&
        !block.isImage &&
        selection.start == block.start &&
        selection.end == block.end;
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
    _pauseListenFollow();
    if (_controlsVisible) setState(() => _controlsVisible = false);
  }

  Widget _buildScrollContent(
    ReaderChapterLayout layout,
    ReaderSelectionScope scope,
  ) {
    final spec = layout.spec;
    // The scroll list re-renders the measured span, so the bubble is already in
    // it. Its size still depends on this list's own constraints, and the
    // painter's placeholder was measured at spec.width — the same width, so the
    // two agree without a second measurement pass.
    return NotificationListener<ScrollStartNotification>(
      onNotification: (notification) {
        if (notification.dragDetails != null) {
          // Scrolling away cancels the selection (the official client keeps
          // it and repositions its toolbar after the scroll settles; here one
          // long press reselects instead).
          _closeSelectionBar(clearSelection: true);
          _hideControlsOnDrag();
        }
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
                selectionScope: scope,
                selection: _selection,
                rangeUnderlines: _rangeUnderlines,
                onParagraphLongPress: (block, position) =>
                    unawaited(_onParagraphLongPress(block, position)),
                onParagraphLongPressMoveUpdate: _onParagraphLongPressMoveUpdate,
                onParagraphLongPressEnd: _onParagraphLongPressEnd,
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
      onListen: () => unawaited(_openListening()),
      autoTurnActive: _autoTurnTimer != null,
      onAutoTurn: _toggleAutoTurn,
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
  // The directory can hold thousands of chapters; filtering on every keystroke
  // re-scans them all and rebuilds the sheet. Coalesce the input instead.
  Timer? _searchDebounce;

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
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() => _query = value);
    });
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
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText: '搜索章节名或序号',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空',
                      onPressed: () {
                        _searchDebounce?.cancel();
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
