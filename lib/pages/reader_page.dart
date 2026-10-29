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
import '../services/backend_transport.dart';
import '../services/chapter_cache_store.dart';
import '../services/chapter_text_formatter.dart';
import '../services/text_replacement_engine.dart';
import '../services/text_replacement_store.dart';
import '../services/library_store.dart';
import '../services/listening_session.dart';
import '../services/reader_device.dart';
import '../widgets/reader/eink_reading.dart';
import '../widgets/reader/reader_player_pill.dart';
import '../widgets/reader/reader_narration_visibility.dart';
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
import '../widgets/reader/reader_illustration.dart';
import '../widgets/reader/reader_ideas_sheet.dart';
import '../widgets/reader/reader_paged_view.dart';
import '../widgets/reader/reader_paragraph_menu.dart';
import '../widgets/reader/reader_status_bar.dart';
import '../widgets/reader/reader_text_selection.dart';
import '../widgets/reader/reader_theme.dart';
import 'audio_page.dart';
import 'text_replacement_page.dart';

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
class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  late int _index;
  final ScrollController _scrollController = ScrollController();
  Timer? _saveTimer;
  // 小米公平运行内存 KILL 广播的刷盘注销函数：dispose 时注销，避免 KILL
  // 到达时调用已 dispose 页面的保存。
  VoidCallback? _unregisterFairMemoryFlush;

  /// 滚动模式下拖过边界的累计量：超过阈值才触发连续阅读跨章，避免轻微
  /// 回弹误触（与分页视图的 32px 边界阈值一致）。带符号：拖过底部为正，
  /// 拖过顶部为负；同一拖拽内反向会抵消累计量。
  double _scrollOverscroll = 0;

  /// In-flight chapter fetch. Switching chapters or leaving the reader cancels
  /// it, so a slow chapter cannot keep the upstream request alive.
  BackendRequest? _chapterRequest;

  String _content = '';
  ChapterContent _chapterContent = ChapterContent(blocks: const []);
  TextReplacementResult? _replacement;
  TextReplacementCancellation? _replacementCancellation;
  int _replacementGeneration = 0;
  TextReplacementStore get _replacementStore =>
      widget.replacementStore ?? TextReplacementStore.instance;

  Future<TextReplacementResult> _replaceContent(
    ChapterContent content,
    String title,
  ) async {
    _replacementCancellation?.cancel();
    final cancellation = _replacementCancellation =
        TextReplacementCancellation();
    await _replacementStore.load();
    while (true) {
      final snapshot = _replacementStore.snapshot;
      final result =
          await (widget.replacementEngine ?? TextReplacementEngine.instance)
              .transform(
                source: content,
                chapterTitle: title,
                snapshot: snapshot,
                cancellation: cancellation,
              );
      if (cancellation.cancelled ||
          snapshot.revision == _replacementStore.snapshot.revision) {
        return result;
      }
    }
  }

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

  List<ReaderRangeUnderline> get _displayRangeUnderlines {
    final layout = _chapterLayout;
    if (layout == null || _replacement == null) return _rangeUnderlines;
    return [
      for (final mark in _rangeUnderlines)
        if (layout.displayOffsetForSource(
              mark.end,
              bias: TextBoundaryBias.end,
            ) >
            layout.displayOffsetForSource(mark.start))
          ReaderRangeUnderline(
            bookId: mark.bookId,
            chapterId: mark.chapterId,
            start: layout.displayOffsetForSource(mark.start),
            end: layout.displayOffsetForSource(
              mark.end,
              bias: TextBoundaryBias.end,
            ),
            text: mark.text,
            createdAt: mark.createdAt,
          ),
    ];
  }

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

  /// 阅读器自己的书架条目（issue #103）：详情页传了原 item 就用它，否则按本页
  /// 已有的书籍字段兜底。书架 key 是 `kind:id`，这里固定 'book'——漫画走自己的
  /// 阅读器（kind 'manga'），两者在书架上本就是两条。
  MediaItem get _shelfEntry =>
      widget.shelfItem ??
      MediaItem(
        id: widget.bookId,
        title: widget.title,
        cover: widget.cover,
        author: '',
        badge: '',
        ep: '',
        kind: 'book',
      );

  /// 全局墨水屏模式覆盖阅读器显示预设（#15/#9）：开启时阅读器强制纯黑白，
  /// 不改用户保存的预设，关闭后恢复原预设。夜间切换等仍写保存的预设。
  ///
  /// 全局 OLED 纯黑同理：只在深色外观下生效，所以阅读背景强制到夜间预设
  ///（颜色再由 [ReaderThemeColors.isOled] 降到 #000000），退出深色后回到
  /// 原预设。
  ReaderThemePreset get _effectivePreset {
    if (einkModeNotifier.value) return ReaderThemePreset.eink;
    if (oledActive()) return ReaderThemePreset.dark;
    return _preferences.themePreset;
  }

  /// 排版用的偏好：墨水屏模式下把预设换成 eink，正文/标题才是 #000000。
  ///
  /// 页面背景早就走 [_effectivePreset]，但 [ReaderLayoutSpec] 的正文、标题
  /// 颜色和 [ReaderControls] 自己的读色都取自这里传入的 preferences。之前
  /// 两处直接传 [_preferences]，于是全局墨水屏开启后正文仍用用户保存预设的
  /// textColor（默认米白 #292724）——实测设备上正文主色 RGB(41,39,36)，
  /// 墨水屏把它量化成明显发灰的一档。保存的预设不动，关闭墨水屏即恢复。
  ReaderPreferences get _displayPreferences {
    if (einkModeNotifier.value) {
      return _preferences.copyWith(
        themePreset: ReaderThemePreset.eink,
        // 墨水屏最低 500 字重：Flutter 没有关亚像素抗锯齿的 API，
        // 加粗是唯一能用的笔画加深手段。
        fontWeight: einkEffectiveFontWeight(
          eink: true,
          fontWeight: _preferences.fontWeight,
        ),
      );
    }
    // OLED：正文 / 标题颜色同样要走夜间，否则排版层会继续用保存预设的浅色
    // 纸面正文色，在纯黑底上既刺眼又和背景对不上。
    if (oledActive()) {
      return _preferences.copyWith(themePreset: ReaderThemePreset.dark);
    }
    return _preferences;
  }

  /// 原生层（MainActivity.dispatchKeyEvent）拦截到音量键后回调：仅在阅读页
  /// 当前路由、未显示控制栏、已开启音量键翻页、且为分页模式时翻页。
  void _onVolumeKey(int direction) {
    if (!mounted ||
        !_routeCurrent ||
        _controlsVisible ||
        !_preferences.volumeKeyTurn ||
        !_paged) {
      return;
    }
    _pauseListenFollow();
    _stopAutoTurn();
    unawaited(_turnPage(direction));
  }

  /// 根据当前状态同步原生是否拦截音量键：仅当阅读页是当前路由、未显示控制栏、
  /// 已开启音量键翻页、且为分页模式时启用。其余情况放行系统音量。
  void _syncVolumeKeyEnabled() {
    unawaited(
      VolumeKeyService.instance.setEnabled(
        _routeCurrent &&
            _preferences.volumeKeyTurn &&
            !_controlsVisible &&
            _paged,
      ),
    );
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
    // 用户自己翻页 = 不想被拽回去，直接退出跟随（图标变回空心）。以前只
    // 暂停 15 秒，按钮还显示「跟随中」，看着像坏了。
    ListeningSession.instance.setFollowArmed(false);
  }

  /// 朗读句高亮：与跟随翻页独立同步，跟随关闭时高亮仍可显示；暂停、
  /// 切章或未在读本章时清空。
  (int, int)? _narrationRange;

  /// 双击跳读是否可用：正在听这本书就行，本章或别的章都可以（跨章跳）。
  ///
  /// 单独存一份是因为它得跟着会话变，而高亮没变化时不会触发重建。
  bool _doubleTapArmed = false;

  /// 10Hz 跟随轮询。见 [_followPollTick]。
  Timer? _followPoll;

  bool get _listenDoubleTapArmed =>
      _narrationRange != null ||
      ListeningSession.instance.bookId == widget.bookId;

  /// 「正文字符位置 ↔ 音频时间」对照表，句高亮 / 跟随翻页 / 双击跳读共用。
  ///
  /// 排版（换字号、换分页方式）或字幕轨换了才重建；两者都用 identical 判断，
  /// 日常 tick 不会重建。
  CueIndex _cueIndex = CueIndex.empty;
  Object? _cueIndexLayout;
  SubtitleTrack? _cueIndexTrack;

  /// 非当前播放章的字幕轨，键 = 章节 id。
  ///
  /// 会话里只存在正在播那一章的轨。停在别的章时双击跳读要先有本章字幕，
  /// 所以按章补取一次留着，翻回来不用再请求。
  final _cueTracks = <String, SubtitleTrack>{};
  final _cueTrackRequests = <String, Future<SubtitleTrack>>{};

  /// 本章该用哪条字幕轨：正在播的就是本章时用会话里的，否则用补取的。
  SubtitleTrack? _cueTrackFor(String chapterId) {
    final session = ListeningSession.instance;
    if (session.chapterId == chapterId) return session.subtitles;
    return _cueTracks[chapterId];
  }

  void _ensureCueIndex(ReaderChapterLayout layout) {
    final track = _cueTrackFor(_chapter.itemId);
    if (identical(_cueIndexLayout, layout) &&
        identical(_cueIndexTrack, track)) {
      return;
    }
    _cueIndexLayout = layout;
    _cueIndexTrack = track;
    _cueIndex = track == null || track.isEmpty
        ? CueIndex.empty
        : CueIndex.build(layout: layout, track: track);
  }

  /// 取本章字幕，取到就缓存。跨章跳读用；同章直接返回会话里的那条。
  Future<SubtitleTrack?> _fetchCueTrack() async {
    final chapterId = _chapter.itemId;
    final session = ListeningSession.instance;
    if (session.chapterId == chapterId) return session.subtitles;
    final cached = _cueTracks[chapterId];
    if (cached != null) return cached;
    final pending = _cueTrackRequests[chapterId];
    if (pending != null) return pending;
    final future = AudioPlaybackScope.timelineForChapter(context, chapterId);
    _cueTrackRequests[chapterId] = future;
    try {
      final track = await future;
      if (track.isNotEmpty) _cueTracks[chapterId] = track;
      return track;
    } catch (_) {
      return null;
    } finally {
      _cueTrackRequests.remove(chapterId);
    }
  }

  /// The passage being narrated, in layout coordinates, or null when this
  /// chapter is not the one on the voice.
  ///
  /// Two sources, two coordinate systems. System TTS reports offsets into the
  /// TTS text blob; 听书 reports the backend's (paragraph, offset) timeline.
  /// Each is translated by its own mapper so neither can smear the highlight
  /// onto the wrong paragraph.
  (int, int)? _narrationLayoutRange(ReaderChapterLayout layout) {
    final session = ListeningSession.instance;
    if (!session.matches(widget.bookId, _chapter.itemId)) return null;
    final audioRange = session.audioParaRange;
    if (audioRange != null) {
      final translated = audioTimePointLayoutRange(
        layout,
        audioRange.startPara,
        audioRange.startOff,
        audioRange.endPara,
        // The upstream end offset is inclusive (official
        // `toTargetTextBlock` passes `endParaOff + 1`); this side is
        // half-open, so the +1 belongs here.
        audioRange.endOff + 1,
        startElementIndex: audioRange.elemIndex,
        startElementOffset: audioRange.elemOff,
      );
      // 官方时间点译不出来时不能直接返回 null：下面那条字幕兜底本来就是为
      // 这种章节写的（多源项章节会重置时间轴），提前返回等于把它跳过。
      if (translated != null) return (translated.start, translated.end);
    }
    final ttsRange = session.sentenceRange;
    if (ttsRange != null &&
        session.textReplacementRevision ==
            (_replacement?.snapshotRevision ?? 0)) {
      final translated = narrationLayoutRange(layout, ttsRange);
      if (translated != null) return (translated.start, translated.end);
    }
    // 官方时间点在多源项章节会重置时间轴（`para 0` 可能从 198 秒才开始），
    // TTS 那条又不适用于音频朗读；这时按播放位置到字幕里查当前句。字幕是
    // 逐句连续的，位置也对得上。
    _ensureCueIndex(layout);
    final span = _cueIndex.spanAtPositionMs(session.position.inMilliseconds);
    if (span != null) return (span.start, span.end);
    // 逐句搜索兜底：句尾落到下一页这类跨页情形索引对不上，但正文里能找到。
    return _locateCue(layout, session.cue);
  }

  void _syncNarrationHighlight((int, int)? narration) {
    if (!mounted) return;
    // 还在读本章、只是这一拍没匹配上（字幕与正文偶有标点差异）时保留上一拍
    // 的区间：清空会让整页突然变黑，观感比「晚半拍」差得多。确实不在读本章
    // 才清。
    final session = ListeningSession.instance;
    final active = session.matches(widget.bookId, _chapter.itemId);
    final held = narration ?? (active ? _narrationRange : null);
    // The follow anchor still uses [narration] when the wash is switched off;
    // only painting depends on the preference.
    final next = _preferences.narrationHighlight ? held : null;
    if (next != _narrationRange) {
      setState(() => _narrationRange = next);
    }
  }

  /// 字幕与正文之间的噪声字符：各类标点和空白。两边在全/半角、省略号写法
  /// 上经常不一致，精确匹配失败后要靠剥掉这些再比一次。
  ///
  /// 与 [CueIndex.cueNoise] 是同一份规则 —— 对照表和这里的兜底搜索必须用同
  /// 一套口径，否则一句在表里能对上、兜底却对不上。
  static final _cueNoise = CueIndex.cueNoise;

  /// 把字幕的当前句映射到本章正文的字符区间（布局坐标）。
  ///
  /// 先整句精确匹配；失败后把两边的标点空白都剥掉再匹配，并把命中位置换算
  /// 回原串下标。两次都找不到返回 null —— 宁可这一拍没有高亮，也不留下上一
  /// 句的错位底色。
  (int, int)? _locateCue(ReaderChapterLayout layout, String? rawCue) {
    final cue = rawCue?.trim();
    if (cue == null || cue.isEmpty) return null;
    for (var i = 1; i < layout.blocks.length; i++) {
      final block = layout.blocks[i];
      if (block.isImage || block.text.isEmpty) continue;
      final at = block.text.indexOf(cue);
      if (at >= 0) return (block.start + at, block.start + at + cue.length);
    }
    final needle = cue.replaceAll(_cueNoise, '');
    if (needle.isEmpty) return null;
    for (var i = 1; i < layout.blocks.length; i++) {
      final block = layout.blocks[i];
      if (block.isImage || block.text.isEmpty) continue;
      final hit = _strippedIndex(block.text, needle);
      if (hit != null) {
        return (block.start + hit.start, block.start + hit.end);
      }
    }
    // 跨页兜底：一句从页尾起头、后半句落到下一页时，新页里只有这句的尾巴
    // （甚至只剩一两个字），整句匹配必然失败，高亮就整段消失。这里改用句尾
    // 若干字逐个尝试，能对上多少就亮多少——亮一两个字也好过全页无高亮。
    //
    // 只看前几个块：残余部分一定落在新页开头，没必要全页扫一遍。
    for (var take = 2; take <= 8; take++) {
      if (take >= needle.length) break;
      final tail = needle.substring(needle.length - take);
      for (var i = 1; i < layout.blocks.length && i <= 3; i++) {
        final block = layout.blocks[i];
        if (block.isImage || block.text.isEmpty) continue;
        final hit = _strippedIndex(block.text, tail);
        if (hit != null) {
          return (block.start + hit.start, block.start + hit.end);
        }
      }
    }
    return null;
  }

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
        !ListeningSession.instance.followArmed ||
        _loading ||
        _changingChapter ||
        _error != null) {
      return;
    }
    if (DateTime.now().isBefore(_listenFollowPausedUntil)) return;
    final session = ListeningSession.instance;
    if (!session.playing || session.bookId != widget.bookId) return;
    if (session.chapterId != _chapter.itemId) {
      final next = widget.chapters.indexWhere(
        (c) => c.itemId == session.chapterId,
      );
      // 控制栏展开 / 自动翻页中的闸门由 [_jumpToChapter] 自己再查一遍。
      if (next >= 0) unawaited(_jumpToChapter(next, followListening: true));
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
  bool _routeCurrent = false;
  bool _changingChapter = false;

  /// 墨水屏整屏刷新计数器：每翻一页 +1，达到 [_ReaderState._einkRefreshInterval]
  /// 阈值（来自 [_preferences.einkRefreshInterval]）就调用一次海信 EPD 全刷压残影，
  /// 然后归零。仅在全局墨水屏模式开启时累加。
  int _einkPageCounter = 0;

  /// 墨水屏软件白闪显隐：[EinkRefreshService] 在厂商接口不可用时发请求，
  /// 这里盖一张全屏白帧再撤掉，迫使 EPD 控制器做一次全量刷新。
  bool _einkFlashVisible = false;
  Timer? _einkFlashTimer;

  /// 滚动模式下的墨水屏刷新累积：滚动没有“翻页”计数，改按滚动距离累积，
  /// 每滚够约 3 屏刷一次，避免滚动模式残影只增不减。
  double _einkScrollDistance = 0;
  double _einkLastScrollOffset = 0;

  /// 上一次已触发过切章刷新的章节 id：首章打开不闪，只有切章才刷。
  String? _lastEinkRefreshChapterId;

  /// Chapter-boundary transition handed to [ReaderPagedView]; see
  /// [ReaderChapterTurn]. Set by [_next] / [_prev] and cleared once the slide
  /// finishes, or when the chapter fails to load.
  // Note: .agents/notes/implemented/bug-fix/2026-10-15-reader-chapter-turn-animation.md
  ReaderChapterTurn? _chapterTurnRequest;

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

  /// Whether the cached layout was measured with bubbles visible. Toggling
  /// the 段评气泡 switch must re-measure: the bubble placeholders change
  /// the text layout, so the cached layout is not reusable across a toggle.
  bool _layoutBubblesVisible = true;

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
  /// point or the handle position at drag end, with y re-based onto the
  /// selection's bottom so the bar can never cover the selected lines.
  Offset _selectionBarAnchor = Offset.zero;

  /// The selection's top edge (window coordinates) — the flip reference when
  /// the bar has to move above the selection instead of below it.
  Offset? _selectionBarTopAnchor;

  /// Gap between the selection's last line bottom and the bar's arrow tip:
  /// the end caret's dot protrudes 6dp, plus 4dp of air.
  static const _barSelectionClearance = 10.0;

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
    VolumeKeyService.instance.setOnVolumeKey(_onVolumeKey);
    _syncVolumeKeyEnabled();
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
    // 跟随用 10Hz 轮询，不走 ListeningSession 的监听（那条每秒最多通知一次，
    // 只在结构性变化时才来，而且不管翻页）。定位键每次都准，所以轮询直接调
    // 同一个函数。
    _followPoll = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _followPollTick(),
    );
    _replacementStore.changes.addListener(_onReplacementChanged);
    WidgetsBinding.instance.addObserver(this);
    // 小米公平运行内存：KILL 广播到达时刷一次阅读进度，避免被杀丢进度。
    _unregisterFairMemoryFlush = FairMemoryService.instance
        .registerFlushHandler(_persistProgress);
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
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

  // Note: Route/lifecycle ownership and SDK 36 compatibility; see
  // .agents/notes/implemented/bug-fix/2026-10-12-reader-system-bars.md.
  // The paragraph-ideas sheet is the reader's own modal (#57): opening it
  // pushes a route, which would otherwise flip [_routeCurrent] off and
  // bring the status bar back. While the sheet is open the viewer is still
  // reading, so immersive stays on; other routes still release it.
  bool _ideasSheetOpen = false;

  void _syncSystemBars() {
    if (!_preferencesReady) return;
    unawaited(
      _device.setImmersive(
        _appActive &&
            (_routeCurrent || _ideasSheetOpen) &&
            widget.chapters.isNotEmpty,
        showStatusBar: _preferences.showSystemStatusBar,
      ),
    );
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
    _syncSystemBars();
    _syncVolumeKeyEnabled();
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
  /// 迷你听书栏的「跳到播放位置」：把页面跳到正在读的那一句。
  ///
  /// 与跟随走同一条寻址链（对照表 → 句内插值 → 第几页），区别只是它是用户
  /// 主动按的，所以不受「跟随开关」和「用户接管闩锁」限制。
  /// 10Hz 跟随轮询：正在听本章、且用户没在主动翻页时，把页面挪到正在读的字。
  ///
  /// 走 [_addressToPlayback]，与迷你栏的定位键**同一段代码**。闸门只留「什么
  /// 时候不该抢」那几条：跟随关着、工具条展开、自动翻页进行中、用户刚手动
  /// 翻过页。
  void _followPollTick() {
    if (!mounted || !_routeCurrent || !_appActive) return;
    // 跟随开关由迷你栏那个按钮管：关着就是自由翻页，什么都不做。
    if (!ListeningSession.instance.followArmed) return;
    // 设置里的「跟随翻页」是总闸，关掉就永不跟。
    if (!_preferences.listeningFollow) return;
    // 工具条展开时不翻页（用户正在操作页面），自动翻页进行时也不抢。
    if (_controlsVisible || _autoTurnTimer != null) return;
    final session = ListeningSession.instance;
    if (!session.playing) return;
    if (session.bookId != widget.bookId) return;
    if (_loading || _changingChapter || _error != null) return;
    // 用户刚手动翻过页：15 秒内不抢，之后再跟上。这一条必须在「换章」分支
    // 前面 —— 否则被闩锁挡住的那次切章每 100ms 还会走一遍结算+存盘。
    if (DateTime.now().isBefore(_listenFollowPausedUntil)) return;
    // 朗读已经读完本章、进了下一章：跟随就该把页面带过去。原来这里直接
    // return，于是跟着跟着停在旧章不动了（用户报的「读完一章不翻章」）。
    if (session.chapterId != _chapter.itemId) {
      final next = widget.chapters.indexWhere(
        (c) => c.itemId == session.chapterId,
      );
      if (next >= 0) unawaited(_jumpToChapter(next, followListening: true));
      return;
    }
    _addressToPlayback(quiet: true);
  }

  /// 把页面寻址到正在读的那个字。返回 false 表示这次没法定位。
  ///
  /// 迷你栏的定位键和 10Hz 跟随轮询**共用这一个函数**——按键每次都准、跟随
  /// 却不准，说明差别不在定位而在跟随那条路上的闸门，所以两条路必须走同一段
  /// 代码。[quiet] 为 true 时（轮询）不弹提示。
  bool _addressToPlayback({bool quiet = false}) {
    if (!mounted) return false;
    final layout = _chapterLayout;
    if (layout == null) return false;
    final session = ListeningSession.instance;
    if (session.bookId != widget.bookId) {
      if (!quiet) _showMessage('没在听这本书');
      return false;
    }
    // 正在听别的章：先把本页切到那一章再说，切章后轮询会接手。
    if (session.chapterId != _chapter.itemId) {
      if (quiet) return false;
      final next = widget.chapters.indexWhere(
        (c) => c.itemId == session.chapterId,
      );
      if (next >= 0) {
        unawaited(_jumpToChapter(next, followListening: true));
      } else {
        _showMessage('正在播放别的章节');
      }
      return true;
    }
    _ensureCueIndex(layout);
    final positionMs = session.position.inMilliseconds;
    final span = _cueIndex.spanAtPositionMs(positionMs);
    // [_narrationRange] 是**显示**状态：某一拍没匹配上时故意留着不清，好让
    // 高亮晚半拍而不是整页变黑。它绝不能当导航锚点 —— 字幕第一句从 3 秒才
    // 开始（`[3025, 0]`）时，位置 0 查不到句，用它寻址会把页面停到本章最后
    // 一句上，而且再也回不来。只有整章没有字幕表（官方时间点是唯一锚点）时
    // 才退回它。
    final offset =
        span?.spokenOffset(positionMs) ??
        (_cueIndex.isEmpty ? _narrationRange?.$1 : null);
    if (offset == null) {
      if (!quiet) _showMessage('找不到当前朗读句');
      return false;
    }
    if (_paged) {
      _pagedKey.currentState?.followOffset(offset);
    } else if (_scrollController.hasClients) {
      final max = _scrollController.position.maxScrollExtent;
      final length = layout.textLength;
      if (max > 0) {
        final ratio = length > 0
            ? (offset / length).clamp(0.0, 1.0)
            : session.progress;
        _scrollController.jumpTo(ratio * max);
      }
    }
    return true;
  }

  /// 迷你听书栏的「跳到播放位置」：按键不受任何闸门限制。
  void _jumpToPlaybackPosition() {
    // 按键本身就是「回到朗读处」，回来之后要继续跟。不清闩锁的话轮询还要
    // 被挡最多 15 秒 —— 按钮点得动，跟随却是死的。
    _listenFollowPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _addressToPlayback();
  }

  /// 双击正文：把朗读跳到手指所指的那一句，可以跨章。
  ///
  /// 全局坐标换算成正文字符下标交给选区几何的 `chapterOffsetAt` —— 它已经在
  /// 处理行内折行、标题占位这些偏移修正，没必要再实现一遍；拿到字符下标后去
  /// 对照表里查出这句的起点时间，再让播放器跳过去。听的是同一本书的别的章时，
  /// 播放器会先切到本章再按位置起播。
  Future<void> _seekToTappedSentence(Offset globalPosition) async {
    final layout = _chapterLayout;
    if (layout == null) return;
    final session = ListeningSession.instance;
    if (session.bookId == null) {
      _showMessage('先开始听书，再双击跳读');
      return;
    }
    if (session.bookId != widget.bookId) {
      _showMessage('正在听别的书');
      return;
    }
    final offset = _marksScope?.geometry.chapterOffsetAt(globalPosition);
    if (offset == null) return;
    _ensureCueIndex(layout);
    if (_cueIndex.isEmpty) {
      // 跨章时手里的字幕轨是「正在播那一章」的，对不上本章正文。现场取本章
      // 字幕再跳 —— 否则用户得先手动切到播放中的那章，再翻回来点。
      final track = await _fetchCueTrack();
      if (!mounted || !identical(_chapterLayout, layout)) return;
      if (track == null || track.isEmpty) {
        _showMessage('本章没有逐句字幕，无法跳读');
        return;
      }
      _ensureCueIndex(layout);
      if (_cueIndex.isEmpty) {
        // 字幕取到了，但一句都没对上正文（章节文本被改过，或语音文本不是原文）。
        _showMessage('本章字幕和正文对不上，无法跳读');
        return;
      }
    }
    final span = _cueIndex.spanAtChar(offset);
    if (span == null) {
      _showMessage('这一点没有对应字幕，换一句试试');
      return;
    }
    if (!AudioPlaybackScope.jumpToChapter(
      context,
      _chapter.itemId,
      span.startPosition,
    )) {
      _showMessage('朗读还没准备好，稍后再试');
      return;
    }
    HapticFeedback.selectionClick();
    // 立刻把高亮移到这句：下一次 tick 要等 200ms，等待期间旧句子还亮着，
    // 看上去像点错了。跨章时本章本来没高亮，这条跳过即可。
    if (kReaderHighlightWash &&
        mounted &&
        (span.start, span.end) != _narrationRange) {
      setState(() => _narrationRange = (span.start, span.end));
    }
  }

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
      for (final underline in _displayRangeUnderlines) {
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
  ///
  /// 官方条子锚在整个选区上,绝不遮选区([yd5.j] 的条子几何): y 取选区
  /// 末端行的行底再让开末端圆点,x 跟手指;选区顶端作为翻转参考传下去。
  void _openSelectionBar({required Offset anchor}) {
    final selection = _selection;
    if (selection == null || !selection.isValid) return;
    final bottom = _selectionBoundGlobal(isStart: false);
    final top = _selectionBoundGlobal(isStart: true);
    setState(() {
      _selectionBarAnchor = Offset(
        anchor.dx,
        bottom == null ? anchor.dy : bottom.dy + _barSelectionClearance,
      );
      _selectionBarTopAnchor = top;
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
    var topAnchor = _selectionBarTopAnchor;
    var view = media.size;
    var safeArea = media.padding;
    var avoidBottom = _controlsVisible ? _bottomBarHeight : 0.0;
    final overlayBox =
        _selectionOverlayKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlayBox != null && overlayBox.attached) {
      anchor = overlayBox.globalToLocal(_selectionBarAnchor);
      topAnchor = _selectionBarTopAnchor == null
          ? null
          : overlayBox.globalToLocal(_selectionBarTopAnchor!);
      view = overlayBox.size;
      // The system insets are already consumed by the outer SafeArea, so the
      // overlay only needs a margin of its own; the reader's bottom toolbar
      // height includes the bottom inset, so subtract what SafeArea padded.
      safeArea = EdgeInsets.zero;
      avoidBottom = (avoidBottom - windowPadding.bottom).clamp(
        0.0,
        double.infinity,
      );
    } else {
      // No overlay box (loading/error fallback): the top anchor would be in a
      // different coordinate space than the bar maths — drop the flip
      // reference rather than flip to a wrong place.
      topAnchor = null;
    }
    final (position, below) = ReaderParagraphMenu.resolvePosition(
      anchor: anchor,
      topAnchor: topAnchor,
      paragraphScoped: selection.isWholeParagraph,
      view: view,
      safeArea: safeArea,
      underlined: underlined,
      showListening: true,
      avoidBottom: avoidBottom,
    );
    return Positioned(
      key: const ValueKey('reader-selection-bar'),
      left: position.dx,
      top: position.dy,
      child: ReaderParagraphMenu(
        underlined: underlined,
        paragraphScoped: selection.isWholeParagraph,
        showListening: true,
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

  bool _markMatchesSelection(
    ReaderRangeUnderline mark,
    ReaderTextSelection selection,
  ) {
    final layout = _chapterLayout;
    return layout != null &&
        layout.displayOffsetForSource(mark.start) == selection.start &&
        layout.displayOffsetForSource(mark.end, bias: TextBoundaryBias.end) ==
            selection.end;
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
      (underline) => _markMatchesSelection(underline, selection),
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
        (underline) => _markMatchesSelection(underline, selection),
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
        .where((underline) => _markMatchesSelection(underline, selection))
        .toList();
    if (!add && existing.isEmpty) return;
    final record = ReaderRangeUnderline(
      bookId: widget.bookId,
      chapterId: chapterId,
      start: layout.sourceOffsetForDisplay(selection.start),
      end: layout.sourceOffsetForDisplay(
        selection.end,
        bias: TextBoundaryBias.end,
      ),
      text: layout.sourceTextInRange(
        layout.sourceOffsetForDisplay(selection.start),
        layout.sourceOffsetForDisplay(
          selection.end,
          bias: TextBoundaryBias.end,
        ),
      ),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      if (add) {
        await store.addRange(record);
      } else {
        for (final mark in existing) {
          await store.remove(mark.key);
        }
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
            .where(
              (underline) => !existing.any((mark) => mark.key == underline.key),
            )
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
            text: _chapterLayout!.sourceTextInRange(
              _chapterLayout!.sourceOffsetForDisplay(block.start),
              _chapterLayout!.sourceOffsetForDisplay(
                block.end,
                bias: TextBoundaryBias.end,
              ),
            ),
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
      ids = {for (final entry in saved.values) entry.id};
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
    _followPoll?.cancel();
    _followPoll = null;
    _chapterRequest?.cancel();
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
    _syncVolumeKeyEnabled();
  }

  Future<void> _load({
    bool startAtEnd = false,
    ReaderChapterTurn? chapterTurn,
  }) async {
    if (widget.chapters.isEmpty) return;
    final generation = ++_loadGeneration;
    _replacementCancellation?.cancel();
    ++_replacementGeneration;
    final chapter = _chapter;
    _saveTimer?.cancel();
    setState(() {
      _loading = true;
      _progressReady = false;
      _error = null;
      _content = '';
      _replacement = null;
      _chapterContent = ChapterContent(blocks: const []);
      _chapterLayout = null;
      _layoutMode = null;
      _textOffset = 0;
      _pageIndex = 0;
      _needsRestore = true;
      _requestedStartAtEnd = startAtEnd;
      _sessionActive = false;
      _chapterTurnRequest = chapterTurn;
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
      final replacement = await _replaceContent(content, chapter.title);
      if (!mounted || generation != _loadGeneration) return;
      if (_chapterCache[chapter.itemId] != null &&
          _chapterCache[chapter.itemId] != text) {
        await _load(startAtEnd: startAtEnd, chapterTurn: chapterTurn);
        return;
      }
      setState(() {
        _replacement = replacement;
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
      // 墨水屏切章刷一次：弹窗/翻页之外的残影来源。首章打开不闪
      // （_lastEinkRefreshChapterId 在 initState 已记为首章）。
      if (einkModeNotifier.value &&
          _lastEinkRefreshChapterId != chapter.itemId) {
        _lastEinkRefreshChapterId = chapter.itemId;
        unawaited(EinkRefreshService.instance.requestRefresh());
      }
      if (replacement.error != null) {
        _showMessage('本章替换失败，已显示原文：${replacement.error}');
      }
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
        _chapterTurnRequest = null;
      });
    }
  }

  /// Loads the chapter's paragraph ideas. Decoration only: a failure leaves the
  /// reader fully usable with the段评 action hidden.
  Future<void> _loadIdeas(Chapter chapter, int generation) async {
    if (widget.localOnly) return;
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
    preset: _effectivePreset,
    onTap: () => unawaited(_showIdeas(focusParaIndex: paraIndex)),
  );

  Future<void> _showIdeas({int? focusParaIndex}) async {
    if (_ideas.isEmpty) return;
    setState(() => _controlsVisible = false);
    final ideaSnapshot = _ideas;
    final chapter = widget.chapters[_index];
    // Keep immersive on while the sheet is open (#57): the sheet pushes a
    // route, which would otherwise release the system bars. The flag is
    // read by [_syncSystemBars] when the route change lands.
    _ideasSheetOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: false,
        backgroundColor: _effectivePreset.isDark
            ? _effectivePreset.panelColor
            : Colors.white,
        // E-ink (#57): a dimmed scrim forces a full-screen gray wash and
        // ghosts on e-ink. Transparent keeps the page readable behind the
        // sheet; tapping outside still dismisses it.
        barrierColor: einkModeNotifier.value
            ? Colors.transparent
            : Colors.black.withValues(alpha: 0.4),
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
            preset: _effectivePreset,
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
            // 回复按需展开（issue #95）。与段评正文同一套「注入即离线」
            // 约定：调用方自己提供数据时不接网络，也就不给可点的回复入口。
            replyLoader: _ideasReplyLoader(),
          ),
        ),
      );
    } finally {
      // The sheet is gone. Release the immersive hold here only if this
      // route is already current again; otherwise didChangeDependencies
      // releases it once the route regains current status (#57). The
      // sheet route stays present until its close animation ends, so an
      // unconditional release here would sync "not immersive" before
      // that notification lands and flash the status bar for a frame.
      // Guard mounted: if the reader was disposed while the sheet was
      // open, dispose already closed the device session and no stale
      // call may follow it.
      if (mounted && _routeCurrent) {
        _ideasSheetOpen = false;
        _syncSystemBars();
      }
      // 墨水屏：段评面板关闭后刷一次，清掉面板残影。
      _maybeEinkRefresh();
    }
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

  /// Loads one comment's replies for the paragraph sheet.
  ///
  /// Null when the caller injected its own comment data or when a chapter
  /// cache was injected (both mark an offline caller), which keeps the reply
  /// counter a plain read-only number for them.
  Future<CommentReplyPage> Function(String commentId)? _ideasReplyLoader() {
    if (widget.commentResolver != null ||
        widget.ideasLoader != null ||
        widget.chapterCache != null) {
      return null;
    }
    if (widget.bookId.isEmpty) return null;
    return (commentId) => ApiClient.instance.commentReplies(
      widget.bookId,
      commentId,
      groupId: widget.bookId,
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
      _chapterRequest?.cancel();
      final request = _chapterRequest = BackendRequest();
      content = await ApiClient.instance.withCancellation(
        request,
        () => ApiClient.instance.chapterContent(chapter.itemId),
      );
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
    if (widget.localOnly) return;
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
      final update = _onChapterContentAvailable(chapter, text);
      // The callback publishes its raw cache revision synchronously before
      // awaiting conversion. A newer batch may supersede it during that await.
      final publishedRevision = _chapterCacheRevisions[chapter.itemId] ?? 0;
      await update;
      if (!catalogReady ||
          !mounted ||
          publishedRevision != (_chapterCacheRevisions[chapter.itemId] ?? 0) ||
          _chapterCache[chapter.itemId] != text) {
        return;
      }
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
  Future<void> _onChapterContentAvailable(Chapter chapter, String text) async {
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
    final generation = ++_replacementGeneration;
    final loadGeneration = _loadGeneration;
    final replacement = await _replaceContent(content, chapter.title);
    if (!mounted ||
        generation != _replacementGeneration ||
        loadGeneration != _loadGeneration ||
        chapter.itemId != _chapter.itemId ||
        _chapterCache[chapter.itemId] != text) {
      return;
    }
    final hasImages = _chapterContent.hasImages;
    final restoring = _needsRestore;
    final offset = hasImages
        ? _chapterLayout?.sourceOffsetForDisplay(_textOffset) ?? _textOffset
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
      _replacement = replacement;
      _selection = null;
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
    if (!widget.localOnly) {
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
      if (mounted && !widget.localOnly) {
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
      preferences: _displayPreferences,
      fontFamily:
          _fontFamily ?? Theme.of(context).textTheme.bodyLarge?.fontFamily,
    );
    if (_chapterLayout?.spec == spec &&
        _layoutMode == _preferences.pageMode &&
        _layoutIdeasRevision == _ideasRevision &&
        _layoutUnderlineRevision == _underlineRevision &&
        _layoutBubblesVisible == _preferences.showParagraphBubbles) {
      return _chapterLayout!;
    }
    // Reuse the measured text layout only when nothing that feeds it changed.
    // Switching page mode keeps the same spec and page-insensitive measurements,
    // so it must not re-measure — but bubbles or 划线 must.
    // The bubble switch gates the data itself (not just the builder):
    // the layout reserves placeholder space from bubbleCount, so a null
    // builder alone would leave an empty gap at the paragraph end.
    final bubblesVisible = _preferences.showParagraphBubbles;
    final reusable =
        _chapterLayout?.spec == spec &&
        _layoutIdeasRevision == _ideasRevision &&
        _layoutUnderlineRevision == _underlineRevision &&
        _layoutBubblesVisible == bubblesVisible;
    final layout = reusable
        ? _chapterLayout!
        : ReaderChapterLayout(
            title: _chapter.title,
            content: _chapterContent,
            replacement: _replacement,
            spec: spec,
            paragraphBubbles: bubblesVisible ? _ideas.bubbleCounts : const {},
            paragraphBubbleVariants: bubblesVisible
                ? _ideas.bubbleVariants
                : const {},
            underlinedParagraphs: _underlines,
            bubbleBuilder: bubblesVisible ? _buildParagraphBubble : null,
          );
    _layoutIdeasRevision = _ideasRevision;
    _layoutUnderlineRevision = _underlineRevision;
    _layoutBubblesVisible = bubblesVisible;
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
    // 墨水屏滚动模式：按滚动距离累积，每滚够约 3 屏刷一次。
    if (einkModeNotifier.value && _scrollController.hasClients) {
      final offset = _scrollController.offset;
      _einkScrollDistance += (offset - _einkLastScrollOffset).abs();
      _einkLastScrollOffset = offset;
      final viewport = _scrollController.position.viewportDimension;
      if (viewport > 0 && _einkScrollDistance >= viewport * 3) {
        _einkScrollDistance = 0;
        unawaited(EinkRefreshService.instance.requestRefresh());
      }
    }
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
    // 分页模式的实际翻页：累加墨水屏刷新计数（覆盖音量键/自动翻页/点按翻页）。
    _recordEinkPageTurn();
  }

  /// 墨水屏：弹窗/菜单关闭后刷一次，清掉弹窗残影。非墨水屏不做事。
  void _maybeEinkRefresh() {
    if (!einkModeNotifier.value) return;
    unawaited(EinkRefreshService.instance.requestRefresh());
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

  /// 墨水屏整屏刷新：翻够 [_preferences.einkRefreshInterval] 页触发一次海信 EPD
  /// 全刷压残影。全局墨水屏未开或间隔为 0 时直接跳过，计数不累加。
  void _recordEinkPageTurn() {
    if (!einkModeNotifier.value) return;
    final interval = _preferences.einkRefreshInterval;
    if (interval <= 0) return;
    _einkPageCounter++;
    if (_einkPageCounter >= interval) {
      _einkPageCounter = 0;
      unawaited(EinkRefreshService.instance.requestRefresh());
    }
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

  /// Captures the page on screen so a chapter boundary can animate. Returns
  /// null when paging is off or the reader is set to turn without animation.
  ReaderChapterTurn? _captureChapterTurn(int direction) {
    if (!_paged || _preferences.pageTurnStyle == ReaderPageTurnStyle.none) {
      return null;
    }
    final layout = _chapterLayout;
    if (layout == null || layout.pages.isEmpty) return null;
    return ReaderChapterTurn(
      direction: direction,
      page: layout.pages[_pageIndex.clamp(0, layout.pages.length - 1)],
      spec: layout.spec,
    );
  }

  /// The boundary slide finished: drop the overlay so the rebuilt pagination
  /// shows through. The chapter switch itself was already committed.
  void _onChapterTurnCompleted() {
    if (!mounted || _chapterTurnRequest == null) return;
    setState(() => _chapterTurnRequest = null);
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
      // 总章数：书架靠「第 N/M 章」区分「读到末尾」与「全书读完」
      // （issue #110 第 3 条）。官方存的是 itemCounts，见 ChaseUpdateModel。
      'chapterCount': widget.chapters.length,
      'position': position,
      'maxScroll': max,
      'positionVersion': 2,
      'textOffset':
          _chapterLayout?.sourceOffsetForDisplay(_textOffset) ?? _textOffset,
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

  /// Goes to the previous chapter.
  ///
  /// [startAtEnd] exists for the *continuous reading* paths only: paging past
  /// the first page of a chapter, overscrolling at the top, or a tap zone that
  /// means "back one chapter while scrolling". Those land on the previous
  /// chapter's end so reading continues where it left off.
  ///
  /// An explicit「上一章」controls (toolbar button, chapter slider arrow, menu
  /// row) must NOT pass it: the official client addresses chapters as
  /// `Y(chapterId, 0, …)` — always the chapter start — and landing on the last
  /// page while「下一章」lands on the first made the pair feel broken
  /// (issue #110).
  Future<void> _prev({bool startAtEnd = false}) async {
    if (_index <= 0 || _changingChapter) return;
    // 用户主动换章 = 不想被朗读拽回去，否则轮询 100ms 后又跳回正在播的那章。
    _pauseListenFollow();
    _changingChapter = true;
    try {
      _settleReadTime();
      await _persistProgress();
      if (!mounted) return;
      final turn = _captureChapterTurn(-1);
      setState(() => _index--);
      await _load(startAtEnd: startAtEnd, chapterTurn: turn);
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
    // 同 [_prev]：主动翻到下一章也要退出跟随。
    _pauseListenFollow();
    _changingChapter = true;
    try {
      _settleReadTime();
      await _persistProgress();
      if (!mounted) return;
      final turn = _captureChapterTurn(1);
      setState(() => _index++);
      await _load(chapterTurn: turn);
    } finally {
      _changingChapter = false;
    }
  }

  Future<void> _jumpToChapter(int index, {bool followListening = false}) async {
    if (!followListening) _pauseListenFollow();
    if (_changingChapter ||
        index == _index ||
        index < 0 ||
        index >= widget.chapters.length) {
      return;
    }
    _changingChapter = true;
    try {
      // 闸门要排在结算/存盘**前面**：被闩锁挡住的这次跟随切章什么都没做，
      // 而在后面的话轮询每 100ms 都会存一次进度。
      if (followListening &&
          (!_routeCurrent ||
              !_appActive ||
              _controlsVisible ||
              !_preferences.listeningFollow ||
              _autoTurnTimer != null ||
              DateTime.now().isBefore(_listenFollowPausedUntil) ||
              !ListeningSession.instance.matches(
                widget.bookId,
                widget.chapters[index].itemId,
              ))) {
        return;
      }
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
    // 滚动模式的离散翻页（音量键/点按边缘/自动翻页）记一次，连续拖拽不计入。
    _recordEinkPageTurn();
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
    _syncVolumeKeyEnabled();
  }

  /// 点击区域九宫格分发：按点按位置取九宫格动作执行。
  void _handleTapZone(Offset position, BoxConstraints constraints) {
    final action = readerTapZoneActionAt(
      zones: _preferences.tapZones,
      dx: position.dx,
      dy: position.dy,
      width: constraints.maxWidth,
      height: constraints.maxHeight,
    );
    switch (action) {
      case ReaderTapZoneAction.none:
        break;
      case ReaderTapZoneAction.menu:
        _toggleControls();
      case ReaderTapZoneAction.prevPage:
        _pauseListenFollow();
        unawaited(_turnPage(-1));
      case ReaderTapZoneAction.nextPage:
        _pauseListenFollow();
        unawaited(_turnPage(1));
      case ReaderTapZoneAction.prevChapter:
        unawaited(_prev());
      case ReaderTapZoneAction.nextChapter:
        unawaited(_next());
      case ReaderTapZoneAction.toc:
        unawaited(_showDirectory());
    }
  }

  void _previewPreferences(ReaderPreferences preferences) {
    _preferencesDirty = true;
    final fontChanged = preferences.fontPath != _preferences.fontPath;
    final intervalChanged =
        preferences.einkRefreshInterval != _preferences.einkRefreshInterval;
    setState(() {
      _preferences = preferences.normalized();
      if (_preferences.themePreset != ReaderThemePreset.dark) {
        _dayTheme = _preferences.themePreset;
      }
      // 刷新间隔改变时清零计数，避免沿用旧阈值导致久不刷新或立刻刷新。
      if (intervalChanged) _einkPageCounter = 0;
    });
    _syncSystemBars();
    if (fontChanged) unawaited(_loadFont(preferences.fontPath));
  }

  Future<void> _showTextReplacement() => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => TextReplacementPage(store: _replacementStore),
    ),
  );

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
        einkOverride: einkModeNotifier.value,
        oledOverride: oledActive(),
        onChanged: _previewPreferences,
        onPickFont: _pickFont,
        onTextReplacement: () {
          Navigator.pop(context);
          unawaited(_showTextReplacement());
        },
      ),
    );
    // 墨水屏：排版面板关闭后刷一次，清掉面板残影。
    _maybeEinkRefresh();
    await _savePreferences();
  }

  void _toggleNightTheme() {
    // 全局墨水屏覆盖显示，点夜间不会有任何可见变化，先提示而非静默无响应。
    if (einkModeNotifier.value) {
      _showMessage('全局墨水屏已开启，先在 设置 → 外观 换成其它主题');
      return;
    }
    // OLED 同理：阅读背景被全局纯黑接管，点夜间看不出变化。
    if (oledActive()) {
      _showMessage('全局 OLED 纯黑已开启，先在 设置 → 外观 关闭它再切换背景');
      return;
    }
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
      backgroundColor: _effectivePreset.panelColor,
      builder: (context) => Theme(
        data: _effectivePreset.theme(Theme.of(context)),
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
    // 墨水屏：目录关闭后刷一次（选了章节时切章本身也会刷一次，不叠加也无妨）。
    _maybeEinkRefresh();
    if (selected != null && mounted) await _jumpToChapter(selected);
  }

  /// Local books use system TTS; online books offer both available sources.
  Future<void> _openListening({int? fromMs, int? textId}) async {
    if (_openingListening || _loading || _error != null) return;
    final chapterId = _chapter.itemId;
    var system = widget.localOnly;
    if (!system) {
      _openingListening = true;
      try {
        // 0 = 从头/续播，1 = 从本页播放，2 = 系统朗读。
        final choice = await showModalBottomSheet<int>(
          context: context,
          useSafeArea: true,
          showDragHandle: true,
          backgroundColor: _effectivePreset.panelColor,
          builder: (context) => Theme(
            data: _effectivePreset.theme(Theme.of(context)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.headphones),
                  title: const Text('听书'),
                  subtitle: const Text('使用作品自带音频与音色'),
                  onTap: () => Navigator.pop(context, 0),
                ),
                ListTile(
                  leading: const Icon(Icons.my_location),
                  title: const Text('从本页播放'),
                  subtitle: const Text('从当前页第一段开始听'),
                  onTap: () => Navigator.pop(context, 1),
                ),
                ListTile(
                  leading: const Icon(Icons.record_voice_over),
                  title: const Text('系统朗读'),
                  subtitle: const Text('使用手机已安装的 TTS 引擎'),
                  onTap: () => Navigator.pop(context, 2),
                ),
              ],
            ),
          ),
        );
        if (!mounted || choice == null || chapterId != _chapter.itemId) return;
        if (choice == 1) {
          final anchor = _currentPageAnchor();
          await _openUpstreamListening(
            fromMs: anchor.startMs ?? fromMs,
            textId: anchor.textId ?? textId,
          );
          return;
        }
        system = choice == 2;
      } finally {
        _openingListening = false;
      }
    }
    if (!system) {
      await _openUpstreamListening(fromMs: fromMs, textId: textId);
      return;
    }
    _openingListening = true;
    try {
      _stopAutoTurn();
      final snapshot = _replacementStore.snapshot;
      final replacement = _replacement;
      if (replacement == null ||
          replacement.snapshotRevision != snapshot.revision) {
        _showMessage('正文替换正在更新，请稍后重试');
        return;
      }
      final content = _chapterContent;
      final chapter = _chapter;
      var offset = 0;
      if (textId != null) {
        final body = replacement.bodyBlocks(chapter.title);
        var found = false;
        for (var i = 0; i < body.length; i++) {
          final block = body[i];
          if (block is! ChapterParagraph) continue;
          if (paragraphUnderlineId(paraIndex: block.paraIndex, blockIndex: i) ==
              textId) {
            found = true;
            break;
          }
          offset += block.text.length + 1;
        }
        if (!found) offset = 0;
      }
      // Capture data and source references before awaiting; the app session
      // never calls this State's cache/prefetch methods after the page leaves.
      final book = SystemTtsBook(
        bookId: widget.bookId,
        title: widget.title,
        coverUrl: widget.cover,
        chapters: widget.chapters,
        startIndex: _index,
        initialContent: content,
        replacementSnapshot: snapshot,
        replacementStore: _replacementStore,
        startOffset: offset,
        localOnly: widget.localOnly,
        textLoader: widget.chapterLoader,
        cache: widget.chapterCache,
      );
      await _persistProgress();
      if (!mounted || chapterId != _chapter.itemId) return;
      setState(() => _controlsVisible = false);
      await AudioPlaybackScope.startSystemTts(context, book);
    } catch (e) {
      if (mounted) _showMessage(SystemTts.errorMessage(e));
    } finally {
      _openingListening = false;
    }
  }

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
  Future<void> _openUpstreamListening({int? fromMs, int? textId}) async {
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
        await _refreshCachedChapter(
          chapter,
        ).timeout(const Duration(seconds: 12), onTimeout: () {});
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
            resumeSession: false,
            // 沿用正在听的那个音色：不传的话播放页只能挑默认音色，
            // 「从本页播放」就会把真人讲书换成内置 TTS。
            initialToneId: _listeningToneId(),
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

  /// 本会话正在用的音色；不在听这本书时为 null（交给播放页按历史/默认决定）。
  String? _listeningToneId() {
    final session = ListeningSession.instance;
    if (session.bookId != widget.bookId) return null;
    final tone = session.toneId;
    return (tone == null || tone.isEmpty) ? null : tone;
  }

  /// 「从本页播放」的锚点：当前页第一个正文段落的段落 ID 与它的起播时间。
  ///
  /// 时间取 [ReaderContentBlock.startMs]（章节自带的 `<span start_time>`），
  /// 与「从本段听」同源。没有时间轴的章返回 startMs 为 null，调用方退回续播。
  ({int? startMs, int? textId}) _currentPageAnchor() {
    final layout = _chapterLayout;
    if (layout == null || layout.pages.isEmpty) {
      return (startMs: null, textId: null);
    }
    final page = layout.pages[_pageIndex.clamp(0, layout.pages.length - 1)];
    for (final fragment in page.fragments) {
      final block = fragment.block;
      if (block.isTitle || block.isImage || block.text.isEmpty) continue;
      return (startMs: block.startMs, textId: block.textId);
    }
    return (startMs: null, textId: null);
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
      backgroundColor: _effectivePreset.panelColor,
      builder: (context) => Theme(
        data: _effectivePreset.theme(Theme.of(context)),
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
    return MediaQuery(
      data: readerMediaQueryWithCutoutInsets(MediaQuery.of(context)),
      child: Builder(builder: _buildReader),
    );
  }

  DateTime _desktopWheelAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _desktopScroll(PointerSignalEvent signal) {
    if (!_paged ||
        signal is! PointerScrollEvent ||
        signal.scrollDelta.dy == 0) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(signal, (_) {
      final now = DateTime.now();
      if (now.difference(_desktopWheelAt).inMilliseconds < 180) return;
      _desktopWheelAt = now;
      unawaited(_turnPage(signal.scrollDelta.dy > 0 ? 1 : -1));
    });
  }

  Widget _buildReader(BuildContext context) {
    if (!isWindowsDesktop) return _buildReaderSurface(context);
    return LayoutBuilder(
      builder: (context, bounds) => ColoredBox(
        color: _effectivePreset.backgroundColor,
        child: Row(
          children: [
            if (bounds.maxWidth >= 1000)
              DesktopChapterSidebar(
                chapters: widget.chapters,
                currentIndex: _index,
                onSelected: (index) => unawaited(_jumpToChapter(index)),
              ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 880),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Focus(
                        autofocus: true,
                        onKeyEvent: (node, event) {
                          if (event is! KeyDownEvent ||
                              FocusManager.instance.primaryFocus?.context
                                      ?.findAncestorWidgetOfExactType<
                                        EditableText
                                      >() !=
                                  null) {
                            return KeyEventResult.ignored;
                          }
                          final key = event.logicalKey;
                          if ([
                            LogicalKeyboardKey.arrowRight,
                            LogicalKeyboardKey.pageDown,
                          ].contains(key)) {
                            unawaited(_turnPage(1));
                            return KeyEventResult.handled;
                          }
                          if ([
                            LogicalKeyboardKey.arrowLeft,
                            LogicalKeyboardKey.pageUp,
                          ].contains(key)) {
                            unawaited(_turnPage(-1));
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: Listener(
                          onPointerSignal: _desktopScroll,
                          child: _buildReaderSurface(context),
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ValueListenableBuilder<double>(
                            valueListenable: DesktopPlatform.readerBrightness,
                            builder: (_, brightness, _) => ColoredBox(
                              color: Colors.black.withValues(
                                alpha: 1 - brightness,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReaderSurface(BuildContext context) {
    final preset = _effectivePreset;
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
                      if (_preferences.readingInfoMode ==
                          ReaderInfoMode.detailed)
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
                        child: ReaderPlayerPillHost(
                          bookId: widget.bookId,
                          preset: preset,
                          animate: !einkModeNotifier.value,
                          controlsVisible: _controlsVisible,
                          highlightOnScreen: () => readerNarrationOnScreen(
                            layout: _chapterLayout,
                            range: _narrationRange,
                            paged: _paged,
                            pageIndex: _pageIndex,
                            scrollController: _scrollController,
                          ),
                          viewportChanges: _scrollController,
                          footerBuilder: _preferences.showReadingInfo
                              ? (player) => ListenableBuilder(
                                  listenable: _scrollController,
                                  builder: (context, _) => ReaderStatusBar(
                                    playerControl: player,
                                    key: const ValueKey('reader-status-bar'),
                                    preset: preset,
                                    compact:
                                        _preferences.readingInfoMode ==
                                        ReaderInfoMode.compact,
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
                                )
                              : null,
                          child: SizedBox.expand(
                            key: _viewportKey,
                            child: _buildContent(preset, windowPadding),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _menuEdge(top: true, child: _buildToolbar(preset)),
                _menuEdge(top: false, child: _buildReaderControls(preset)),
                // 墨水屏软件白闪：盖全屏白帧，迫使 EPD 控制器全量刷新。
                if (_einkFlashVisible)
                  const Positioned.fill(child: ColoredBox(color: Colors.white)),
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
          // 墨水屏：菜单滑入/淡出动画也会留残影，直接跳变。
          duration: einkModeNotifier.value
              ? Duration.zero
              : const Duration(milliseconds: 180),
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
              icon: Icon(LucideIcons.arrow_left, color: preset.textColor),
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
            if (!_loading &&
                _error == null &&
                _ideas.total > 0 &&
                _chapterEndParagraph() != null)
              IconButton(
                key: const ValueKey('reader-toolbar-chapter-comments'),
                tooltip: '本章评论',
                onPressed: () => unawaited(
                  _showIdeas(focusParaIndex: _chapterEndParagraph()),
                ),
                icon: Icon(LucideIcons.message_circle, color: preset.textColor),
              ),
            ValueListenableBuilder<int>(
              valueListenable: ShelfStore.instance.listenable,
              builder: (context, _, _) {
                final inShelfNow = inShelf(_shelfEntry);
                return IconButton(
                  key: const ValueKey('reader-shelf-button'),
                  tooltip: inShelfNow ? '已在书架' : '加入书架',
                  onPressed: () => unawaited(toggleShelf(context, _shelfEntry)),
                  icon: Icon(
                    inShelfNow
                        ? LucideIcons.bookmark_check
                        : LucideIcons.bookmark_plus,
                    color: preset.textColor,
                  ),
                );
              },
            ),
            IconButton(
              tooltip: '收起阅读菜单',
              onPressed: _toggleControls,
              icon: Icon(LucideIcons.chevron_up, color: preset.textColor),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildContent(ReaderThemePreset preset, EdgeInsets windowPadding) {
    final chapterTurn = _chapterTurnRequest;
    if (_loading && chapterTurn != null) {
      // Keep the outgoing page on screen while the neighbouring chapter loads,
      // so the boundary slides instead of flashing the loading spinner.
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggleControls,
        child: ReaderPageContent(
          page: chapterTurn.page,
          spec: chapterTurn.spec,
          imageProviderFactory: widget.imageProviderFactory,
        ),
      );
    }
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
    if (_replacement?.bodyIsEmpty(_chapter.title) == true) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('本章正文已被替换规则清空'),
            TextButton(
              onPressed: _showTextReplacement,
              child: const Text('编辑规则'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  await _replacementStore.save(
                    enabled: false,
                    rules: _replacementStore.snapshot.rules,
                  );
                } catch (_) {
                  if (mounted) _showMessage('替换规则保存失败');
                }
              },
              child: const Text('停用正文替换'),
            ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _prepareLayout(constraints);
        final scope = _marksScopeFor(preset, layout);
        // 桌面端用鼠标中键定位到点中的那一句。Listener 读原始指针事件，
        // 不参与手势竞技场，所以和翻页、长按、选词都不冲突；移动端没有中键，
        // 仍走下面的双击。
        return Listener(
          onPointerDown: (event) {
            if (event.buttons != kMiddleMouseButton) return;
            if (_doubleTapArmed) {
              _seekToTappedSentence(event.position);
            }
          },
          child: GestureDetector(
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
              } else {
                _handleTapZone(details.localPosition, constraints);
              }
            },
            // 听这本书时才挂双击（同章、跨章都行）：双击识别器会把普通单击推迟到
            // 300ms 超时后才响应，没在听书时别拖累翻页点按。
            onDoubleTapDown: _doubleTapArmed
                ? (details) => _seekToTappedSentence(details.globalPosition)
                : null,
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
                          // 墨水屏强制零动画翻页：动画帧在墨水屏上全是残影。
                          // turnStyle == none 时章节边界动画也随之跳过。
                          instantSwipe: einkEffectiveInstantSwipe(
                            eink: einkModeNotifier.value,
                            instantSwipeTurn: _preferences.instantSwipeTurn,
                          ),
                          turnStyle: einkEffectiveTurnStyle(
                            eink: einkModeNotifier.value,
                            instantSwipeTurn: _preferences.instantSwipeTurn,
                            pageTurnStyle: _preferences.pageTurnStyle,
                          ),
                          backgroundColor: preset.backgroundColor,
                          endPage: _index == widget.chapters.length - 1
                              ? _buildChapterEndPage(preset)
                              : null,
                          onBookEnd: _stopAutoTurn,
                          chapterTurn: _chapterTurnRequest,
                          onChapterTurnCompleted: _onChapterTurnCompleted,
                          imageProviderFactory: widget.imageProviderFactory,
                          onParagraphLongPress: (block, position) =>
                              unawaited(_onParagraphLongPress(block, position)),
                          onParagraphLongPressMoveUpdate:
                              _onParagraphLongPressMoveUpdate,
                          onParagraphLongPressEnd: _onParagraphLongPressEnd,
                          selectionScope: scope,
                          selection: _selection,
                          rangeUnderlines: _displayRangeUnderlines,
                          narrationRange: _narrationRange,
                        )
                      : _buildScrollContent(layout, scope),
                ),
                ..._selectionHandles(scope),
                ?_selectionBar(preset, windowPadding),
              ],
            ),
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
        underlineColor: preset.selectionUnderlineColor,
        narrationColor: preset.narrationHighlightColor,
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
    final start = _handleCaretOverlay(isStart: true);
    final end = _handleCaretOverlay(isStart: false);
    if (start == null && end == null) return const [];

    // Ink layout (官方 yd5.j.I()): the 1dp bar runs the selected line's full
    // height; the dot protrudes 6dp beyond the line edge. Start ink hugs the
    // widget top, end ink hugs the bottom — the touch margin sits on the far
    // side of the line.
    Widget handle(bool isStart, ({double x, double top, double bottom}) caret) {
      final lineHeight = caret.bottom - caret.top;
      final widget = ReaderSelectionHandle(
        isStart: isStart,
        color: scope.handleColor,
        lineHeight: lineHeight,
        onDragStart: _onHandleDragStart,
        onDragUpdate: (global) => _onHandleDrag(isStart, global),
        onDragEnd: (global) => _onHandleDragEnd(isStart, global),
      );
      return Positioned(
        key: ValueKey('reader-selection-handle-${isStart ? 'start' : 'end'}'),
        left: caret.x - ReaderSelectionHandle.touchWidth / 2,
        top: isStart
            ? caret.top - ReaderSelectionHandle.dotOverhang
            : caret.top - ReaderSelectionHandle.touchMargin,
        child: widget,
      );
    }

    return [
      if (start != null) handle(true, start),
      if (end != null) handle(false, end),
    ];
  }

  /// Overlay-local caret of one selection bound — the glyph edge x plus the
  /// selected line's vertical extent — or null when the bound's block is not
  /// mounted (an off-screen page).
  ({double x, double top, double bottom})? _handleCaretOverlay({
    required bool isStart,
  }) {
    final selection = _selection;
    final layout = _chapterLayout;
    final scope = _marksScope;
    if (selection == null || layout == null || scope == null) return null;
    final textOffset = isStart ? selection.start : selection.end - 1;
    final block = layout.blockForAnchor(textOffset, isStart: isStart);
    if (block == null) return null;
    final entry = scope.geometry.entryFor(block.index);
    if (entry == null) return null;
    final caret = selectionCaret(
      block: block,
      painter: entry.painter,
      textOffset: _boundOffsetInBlock(textOffset, block, isStart: isStart),
      isStart: isStart,
      columnWidth: layout.spec.width,
    );
    final overlayBox =
        _selectionOverlayKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.attached) return null;
    final origin = overlayBox.globalToLocal(
      entry.box.localToGlobal(Offset(caret.x, caret.top)),
    );
    return (
      x: origin.dx,
      top: origin.dy,
      bottom: origin.dy + caret.bottom - caret.top,
    );
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
    if (next.isValid && next.end < range.$2 && _selectionPaintsNothing(next)) {
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

  /// The final chapter keeps a stable completion page. Other chapters go
  /// directly to the next text page; their comments are in the reader toolbar.
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
          ],
        ),
      ),
    );
  }

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
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth != 0) return false;
        if (notification is ScrollStartNotification) {
          // A new drag resets the bottom-overscroll accumulator, so only
          // one continuous-reading advance fires per drag past the end.
          _scrollOverscroll = 0;
          if (notification.dragDetails != null) {
            // Scrolling away cancels the selection (the official client keeps
            // it and repositions its toolbar after the scroll settles; here one
            // long press reselects instead).
            _closeSelectionBar(clearSelection: true);
            _hideControlsOnDrag();
          }
          return false;
        }
        if (notification is OverscrollNotification &&
            notification.dragDetails != null &&
            _preferences.continuousReading &&
            !_changingChapter &&
            !_loading) {
          // 连续阅读：滚动到底后继续往下拉，把下一章接上；滚到顶后继续
          // 往下拉，把上一章接上（落在上一章末尾）。章末按钮行仍在，
          // 点它一样能进上一章/下一章。Overscroll 带符号：底部为正、
          // 顶部为负；到不了的方向不累计，避免陈旧的累计量在反向时
          // 提前触发。
          final overscroll = notification.overscroll;
          final canAdvance = _index < widget.chapters.length - 1;
          final canRetreat = _index > 0;
          if ((overscroll > 0 && canAdvance) ||
              (overscroll < 0 && canRetreat)) {
            _scrollOverscroll += overscroll;
            if (_scrollOverscroll > 32) {
              _scrollOverscroll = 0;
              unawaited(_next());
            } else if (_scrollOverscroll < -32) {
              _scrollOverscroll = 0;
              unawaited(_prev(startAtEnd: true));
            }
          }
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
                rangeUnderlines: _displayRangeUnderlines,
                narrationRange: _narrationRange,
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
                    icon: const Icon(LucideIcons.chevron_left, size: 18),
                    label: const Text(
                      '上一章',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, height: 1.4),
                    ),
                    onPressed: _index > 0 ? _prev : null,
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
                    icon: const Icon(LucideIcons.message_square, size: 18),
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
                    icon: const Icon(LucideIcons.chevron_right, size: 18),
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
      preferences: _displayPreferences,
      chapterIndex: previewIndex,
      chapterCount: widget.chapters.length,
      chapterTitle: widget.chapters[previewIndex].title,
      seekValue: seekValue,
      deviceAvailable: _deviceAvailable,
      systemBrightness: _deviceStatus.systemBrightness,
      onPrevious: _index > 0 ? _prev : null,
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
      showListening: true,
      showCache: !widget.localOnly,
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
                  _reversed ? LucideIcons.arrow_up : LucideIcons.arrow_down,
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
              prefixIcon: const Icon(LucideIcons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空',
                      onPressed: () {
                        _searchDebounce?.cancel();
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(LucideIcons.x),
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
              ? Center(
                  child: Text(
                    '没有匹配的章节',
                    style: TextStyle(color: scheme.onSurface),
                  ),
                )
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
                                child: Icon(LucideIcons.circle_check, size: 18),
                              ),
                            if (current)
                              Icon(
                                LucideIcons.locate_fixed,
                                color: scheme.primary,
                              ),
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
