import 'package:flutter/gestures.dart';
import '../services/desktop_platform.dart';
import '../services/audio_floating_routes.dart';
import '../widgets/desktop_chapter_sidebar.dart';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/book_comment.dart';
import '../models/chapter_ideas.dart';
import '../models/audio_extra.dart';
import '../models/comment_reply.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/app_theme.dart';
import '../services/chapter_cache_store.dart';
import '../services/chapter_request_tracker.dart';
import '../services/chapter_text_formatter.dart';
import '../services/text_replacement_engine.dart';
import '../services/text_replacement_store.dart';
import '../services/library_store.dart';
import '../services/listening_session.dart';
import '../services/reader_device.dart';
import '../services/reader_follow_poll.dart';
import '../widgets/reader/eink_reading.dart';
import '../widgets/reader/reader_player_pill.dart';
import '../widgets/reader/reader_narration_visibility.dart';
import '../widgets/reader/reader_sync_pill.dart';
import '../services/eink_refresh.dart';
import '../services/fair_memory.dart';
import '../services/volume_key.dart';
import '../services/reader_history.dart';
import '../services/reader_preferences.dart';
import '../services/reader_tap_zones.dart';
import '../services/reader_underline_store.dart';
import '../services/shelf_toggle.dart';
import '../services/shelf_store.dart';
import '../services/system_tts.dart';
import '../widgets/chapter_cache_sheet.dart';
import '../widgets/reader/reader_appearance_sheet.dart';
import '../widgets/reader/reader_bubble.dart';
import '../widgets/reader/reader_chapter_layout.dart';
import '../widgets/reader/cue_index.dart';
import '../widgets/reader/reader_controls.dart';
import '../widgets/reader/reader_cutout_insets.dart';
import '../widgets/reader/reader_directory_sheet.dart';
import '../widgets/reader/reader_illustration.dart';
import '../widgets/reader/reader_ideas_sheet.dart';
import '../widgets/reader/reader_paged_view.dart';
import '../widgets/reader/reader_paragraph_menu.dart';
import '../widgets/reader/reader_status_bar.dart';
import '../widgets/reader/reader_text_selection.dart';
import '../widgets/reader/reader_theme.dart';
import 'audio_page.dart';
import 'text_replacement_page.dart';

part 'reader/reader_page_fields.dart';
part 'reader/reader_page_listening.dart';
part 'reader/reader_page_listening_launch.dart';
part 'reader/reader_page_selection.dart';
part 'reader/reader_page_selection_overlay.dart';
part 'reader/reader_page_chapter_loading.dart';
part 'reader/reader_page_ideas.dart';
part 'reader/reader_page_preferences.dart';
part 'reader/reader_page_progress.dart';
part 'reader/reader_page_build.dart';
part 'reader/reader_page_content.dart';

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

/// 朗读句高亮的底色要不要画。
///
/// 用户要求单独验证「双击 / 中键跳到那一段」这件事，先把暖黄底色关掉：
/// 底色会盖住正文，也容易让人把"跳转生效"误认成"高亮亮了"。关掉之后
/// 跳转链路（字幕 → 时间 → seek）完全不变，见 `_seekToTappedSentence`。
const bool kReaderHighlightWash = false;

class ReaderPage extends StatefulWidget {
  final String bookId;
  final String title;
  final String cover;
  final List<Chapter> chapters;
  final int startIndex;
  final bool localOnly;
  final ChapterTextLoader? chapterLoader;
  final ReaderStore? readerStore;
  final ChapterCache? chapterCache;
  final ReaderDevice? readerDevice;
  final ReaderImageProviderFactory? imageProviderFactory;

  /// Local 划线 storage. Defaults to the device-wide box.
  final ReaderUnderlineStore? underlineStore;
  final TextReplacementStore? replacementStore;
  final TextReplacementEngine? replacementEngine;

  /// Paragraph ideas for the current chapter. When both this and
  /// [commentResolver] are null the reader fetches them itself, unless a
  /// [chapterCache] was injected (an injected cache marks the caller as
  /// driving its own data).
  final ChapterIdeasLoader? ideasLoader;

  /// Resolves one paragraph's comment bodies. See [ParagraphCommentResolver].
  final ParagraphCommentResolver? commentResolver;

  /// 加入书架时用的条目（issue #103）。详情页传入原 `MediaItem`，书架卡片因此
  /// 保留作者/徽标等字段；其他入口省略，按 [bookId]/[title]/[cover] 兜底成小说。
  final MediaItem? shelfItem;

  const ReaderPage({
    super.key,
    required this.bookId,
    required this.title,
    this.cover = '',
    required this.chapters,
    required this.startIndex,
    this.localOnly = false,
    this.chapterLoader,
    this.readerStore,
    this.chapterCache,
    this.readerDevice,
    this.imageProviderFactory,
    this.ideasLoader,
    this.commentResolver,
    this.shelfItem,
    this.underlineStore,
    this.replacementStore,
    this.replacementEngine,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

// Note: 菜单覆盖层与正文布局分离；见
// .agents/notes/implemented/feature/2026-09-10-reader-interface.md
class _ReaderPageState extends State<ReaderPage>
    with WidgetsBindingObserver, _ReaderPageFields {
  /// Calls [setState] on behalf of the logic split into the `reader/` parts.
  ///
  /// Those extensions are methods of this State at runtime, but the analyzer
  /// does not model that and rejects `setState` inside them as a protected
  /// member use, so they call through here instead.
  void _setState(VoidCallback fn) => setState(fn);

  Future<void> _onReplacementChanged() async {
    if (!mounted || _loading || _error != null) return;
    final generation = ++_replacementGeneration;
    final loadGeneration = _loadGeneration;
    final chapter = _chapter;
    _captureScrollProgress();
    final text = _chapterCache[chapter.itemId] ?? _content;
    final content = text == _content
        ? _chapterContent
        : ChapterContent.fromCacheText(text);
    final legacyRefresh = text != _content && !_chapterContent.hasImages;
    final position = _needsRestore
        ? _savedPosition
        : <String, dynamic>{
            'chapterId': chapter.itemId,
            'positionVersion': legacyRefresh ? 1 : 2,
            'textOffset': legacyRefresh
                ? _chapterLayout?.legacyOffsetForText(_textOffset) ??
                      _textOffset
                : _chapterLayout?.sourceOffsetForDisplay(_textOffset) ??
                      _textOffset,
          };
    final result = await _replaceContent(content, chapter.title);
    if (!mounted ||
        generation != _replacementGeneration ||
        loadGeneration != _loadGeneration) {
      return;
    }
    setState(() {
      _content = text;
      _chapterContent = content;
      _replacement = result;
      _savedPosition = position;
      _narrationRange = null;
      _selection = null;
      _selectionBarOpen = false;
      _chapterLayout = null;
      _needsRestore = true;
      _progressReady = false;
    });
    if (result.error != null) _showMessage('本章替换失败，已显示原文：${result.error}');
  }

  /// 10Hz 跟随轮询，只在有本书的听书会话且前台时运行。见 [_followPollTick]。
  late final ReaderFollowPoll _followPoll = ReaderFollowPoll(
    _followPollTick,
    () => _appActive && ListeningSession.instance.matchesBook(widget.bookId),
  );

  /// 字幕与正文之间的噪声字符：各类标点和空白。两边在全/半角、省略号写法
  /// 上经常不一致，精确匹配失败后要靠剥掉这些再比一次。
  ///
  /// 与 [CueIndex.cueNoise] 是同一份规则 —— 对照表和这里的兜底搜索必须用同
  /// 一套口径，否则一句在表里能对上、兜底却对不上。
  static final _cueNoise = CueIndex.cueNoise;

  /// 在 [text] 里找剥掉噪声后的 [needle]，返回原串的下标区间。
  static ({int start, int end})? _strippedIndex(String text, String needle) {
    final chars = <String>[];
    final origin = <int>[];
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (_cueNoise.hasMatch(ch)) continue;
      chars.add(ch);
      origin.add(i);
    }
    final at = chars.join().indexOf(needle);
    if (at < 0) return null;
    return (start: origin[at], end: origin[at + needle.length - 1] + 1);
  }

  void _onListeningTick() {
    if (!mounted) return;
    final session = ListeningSession.instance;
    final playing = session.playing && session.matchesBook(widget.bookId);
    if (playing && !_listenWasPlaying) {
      // 官方 onPlayResume（AudioSyncReaderController.java:381）恢复播放时
      // 立刻恢复跟随，不受手动翻页那 15 秒闩锁影响。
      _listenFollowPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
    }
    _listenWasPlaying = playing;
    _followPoll.sync();
    // 会话起停时即使高亮不变，也要重建双击跳读手势。
    final armed = _listenDoubleTapArmed;
    if (armed != _doubleTapArmed) {
      setState(() => _doubleTapArmed = armed);
    }
    final layout = _chapterLayout;
    final narration = layout == null ? null : _narrationLayoutRange(layout);
    _syncNarrationHighlight(narration);
    // 翻页**只**由 [_followPollTick] 负责：它按句内插值寻址到正在读的那个
    // 字。这条 1Hz 通知原来也翻，但锚的是句首；一句跨页时两路各拽一头，
    // 于是就出现每秒回闪一页。这里只剩「朗读读完本章 → 跟到下一章」。
    if (!_routeCurrent ||
        !_appActive ||
        !_preferences.listeningFollow ||
        // 没按过定位键就是不跟随：老逻辑只认偏好，开着重播就会自己翻页。
        !session.followArmed ||
        _loading ||
        _changingChapter ||
        _error != null) {
      return;
    }
    if (DateTime.now().isBefore(_listenFollowPausedUntil)) return;
    if (!session.playing || !session.matchesBook(widget.bookId)) return;
    if (!session.matchesChapter(_chapter.itemId)) {
      // 真人讲书会按时间轴把当前音频章节别名成原著章节；跟随要翻到的是
      // 原著那一章，而不是音频章节 id。
      final next = widget.chapters.indexWhere(
        (c) => c.itemId == session.readerChapterId,
      );
      // 控制栏展开 / 自动翻页中的闸门由 [_jumpToChapter] 自己再查一遍。
      if (next >= 0) unawaited(_jumpToChapter(next, followListening: true));
    }
  }

  /// Height of the reader's own bottom toolbar (目录/夜间/听书/设置) as measured
  /// on device, including its safe-area inset. The paragraph action bar keeps
  /// clear of it so a long press near the page foot flips above the line
  /// instead of landing on top of the controls.
  static const _bottomBarHeight = 74.0;

  /// Gap between the selection's last line bottom and the bar's arrow tip:
  /// the end caret's dot protrudes 6dp, plus 4dp of air.
  static const _barSelectionClearance = 10.0;

  @override
  void initState() {
    super.initState();
    VolumeKeyService.instance.setOnVolumeKey(_onVolumeKey);
    _syncVolumeKeyEnabled();
    // 官方默认跟随：起播时（d.java:143-151）页面会自动同步到朗读处。阅读页
    // 可能是在起播之后才打开的，补上这一次。
    ListeningSession.instance.followIfPlaying(widget.bookId);
    ListeningSession.instance.addListener(_onListeningTick);
    // 双击跳读的开关只在会话通知里算，而暂停的会话永远不发通知：开书前就
    // 已经暂停（或者从未播过）时手势得先就位。initState 里不能 setState，
    // 直接赋值。
    _doubleTapArmed = _listenDoubleTapArmed;
    // 迷你栏的跟随键靠这个函数决定是否可点，而它挂在 Overlay 上、不随本页
    // 重建；initState 正处于构建阶段，同步广播会撞上 markNeedsBuild 断言，
    // 所以推到帧后再注册。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ListeningSession.instance.jumpToPlaybackHandler =
            _jumpToPlaybackPosition;
      }
    });
    // 跟随用 10Hz 轮询，不走 ListeningSession 的 1Hz 通知（只在结构性变化时
    // 才来，而且不管翻页）；会话/前台变化时由 [_followPoll.sync] 启停定时器。
    _replacementStore.changes.addListener(_onReplacementChanged);
    WidgetsBinding.instance.addObserver(this);
    // 小米公平运行内存：KILL 广播到达时刷一次阅读进度，避免被杀丢进度。
    _unregisterFairMemoryFlush = FairMemoryService.instance
        .registerFlushHandler(_persistProgress);
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _followPoll.sync();
    _index = widget.chapters.isEmpty
        ? 0
        : widget.startIndex.clamp(0, widget.chapters.length - 1);
    _lastEinkRefreshChapterId = widget.chapters.isEmpty
        ? null
        : widget.chapters[_index].itemId;
    EinkRefreshService.instance.flashRequest.addListener(_onEinkFlashRequest);
    _scrollController.addListener(_onScroll);
    _preferencesFuture = _loadPreferences();
    if (widget.chapters.isEmpty) {
      _loading = false;
      _error = '暂无可阅读章节';
    } else {
      if (!widget.localOnly) {
        unawaited(_ensureCatalog().catchError((_) {}));
      }
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant ReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.chapters, widget.chapters) ||
        widget.chapters.isEmpty ||
        oldWidget.chapters.isEmpty) {
      return;
    }
    final chapterId = oldWidget.chapters[_index].itemId;
    final next = widget.chapters.indexWhere((c) => c.itemId == chapterId);
    _index = next < 0 ? _index.clamp(0, widget.chapters.length - 1) : next;
    _catalogFuture = null;
    if (!widget.localOnly) unawaited(_ensureCatalog().catchError((_) {}));
    if (next < 0) unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AudioFloatingRouteScope.configure(context, hidden: true);
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_routeCurrent == current) return;
    _routeCurrent = current;
    // The ideas sheet (#57) holds immersive while it is open. Once this
    // route is current again the sheet is gone, so the hold is released
    // here — the sheet's own finally runs before this notification lands
    // (the sheet route is still present until its close animation ends),
    // and releasing there would briefly show the status bar (one flash).
    if (current) _ideasSheetOpen = false;
    _syncSystemBars();
    _syncVolumeKeyEnabled();
  }

  /// 迷你听书栏的「跳到播放位置」：按键不受任何闸门限制。
  void _jumpToPlaybackPosition() {
    // 按键本身就是「回到朗读处」，回来之后要继续跟。不清闩锁的话轮询还要
    // 被挡最多 15 秒 —— 按钮点得动，跟随却是死的。
    _listenFollowPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _addressToPlayback();
  }

  @override
  void dispose() {
    _followPoll.dispose();
    _chapterRequestHandles.cancelAll();
    VolumeKeyService.instance.setOnVolumeKey(null);
    unawaited(VolumeKeyService.instance.setEnabled(false));
    ListeningSession.instance.removeListener(_onListeningTick);
    // 只清自己注册的：换章重建时新实例已经接管。
    if (ListeningSession.instance.jumpToPlaybackHandler ==
        _jumpToPlaybackPosition) {
      ListeningSession.instance.jumpToPlaybackHandler = null;
    }
    _replacementStore.changes.removeListener(_onReplacementChanged);
    _replacementCancellation?.cancel();
    ++_replacementGeneration;
    _unregisterFairMemoryFlush?.call();
    _unregisterFairMemoryFlush = null;
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
    EinkRefreshService.instance.flashRequest.removeListener(
      _onEinkFlashRequest,
    );
    _einkFlashTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 桌面端窗口失焦报的是 inactive，但窗口还在、内容还在跑。拿它当「退到
    // 后台」会让鼠标一点别的窗口听书跟随就停摆（见 desktopInactiveStillVisible）。
    if (state == AppLifecycleState.inactive &&
        desktopInactiveStillVisible(state)) {
      return;
    }
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
      _syncSystemBars();
      unawaited(_refreshDevice());
      if (!_loading && _content.isNotEmpty) {
        _readStart = DateTime.now();
        _sessionActive = true;
        if (_chapterContent.needsRefresh()) {
          unawaited(_refreshCachedChapter(_chapter));
        }
      }
    }
    // 前台/后台切换不影响原生层音量键拦截（在 Activity 层，与 Flutter 生命周期
    // 无关），故此处无需重挂监听；仅同步一次状态即可。
    _followPoll.sync();
    _syncVolumeKeyEnabled();
  }

  /// 软件白闪：盖一张全屏白帧 150ms 再撤掉。白帧本身就是一次可见闪烁，
  /// 墨水屏上这正是全刷的观感；连续请求进来时重计时，不叠加多闪。
  void _onEinkFlashRequest() {
    if (!mounted) return;
    _einkFlashTimer?.cancel();
    if (!_einkFlashVisible) setState(() => _einkFlashVisible = true);
    _einkFlashTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() => _einkFlashVisible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: _errorView(),
      );
    }
    return MediaQuery(
      data: readerMediaQueryWithCutoutInsets(MediaQuery.of(context)),
      child: Builder(builder: _buildReader),
    );
  }
}
