import '../services/desktop_platform.dart';
import '../widgets/desktop_chapter_sidebar.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/audio_extra.dart';
import '../models/audio_time_track.dart';
import '../models/book_comment.dart';
import '../models/book_detail.dart';
import '../models/chapter_media.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/audio_download_store.dart';
import '../services/audio_history.dart';
import '../services/audio_floating_routes.dart';
import '../services/audio_page_theme.dart';
import '../services/audio_play_error.dart';
import '../services/audio_playback_choice.dart';
import '../services/audio_subtitle_synth.dart';
import '../services/audio_preferences.dart';
import '../services/chapter_cache_store.dart';
import '../services/fair_memory.dart';
import '../services/library_store.dart';
import '../services/listening_session.dart';
import '../services/media_history_store.dart';
import '../services/native_player.dart';
import '../services/playback_format.dart';
import '../services/shelf_store.dart';
import '../services/transient_retry.dart';
import '../services/system_tts.dart';
import '../widgets/audio/audio_offline_section.dart';
import '../widgets/audio/audio_floating_player.dart';
import '../widgets/audio/audio_advance_banner.dart';
import '../widgets/audio/audio_control_rows.dart';
import '../widgets/audio/audio_quick_rows.dart';
import '../widgets/audio/audio_skip_points_rows.dart';
import '../widgets/audio/audio_cover_card.dart';
import '../widgets/audio/audio_sections.dart';
import '../widgets/audio/audio_subtitle_scroller.dart';
import '../widgets/audio/voice_settings_sheet.dart';
import '../widgets/audio/system_tts_controls.dart';
import '../widgets/chapter_cache_sheet.dart';
import '../widgets/comment_images.dart';
import '../widgets/home/home_design.dart';
import 'detail_page.dart';
import 'reader_page.dart';

part 'audio_listening_layout.dart';
part '../services/audio_playback_guard.dart';
part '../services/audio_playback_controller.dart';
part '../widgets/audio/audio_playback_scope.dart';
part '../widgets/audio/audio_floating_capsule.dart';

/// Foreground listening using the existing Android Media3 URL player.
class AudioPage extends StatefulWidget {
  final String bookId;
  final String title;
  final String cover;
  final List<Chapter> chapters;
  final int startIndex;

  /// Where playback starts inside [startIndex]. 从本段听 sets this to the pressed
  /// paragraph's place on the chapter's spoken timeline. Null means resume from
  /// history, else the chapter opening.
  final Duration? startPosition;
  final String? initialToneId;
  final double? initialRate;
  final bool autoplay;

  /// Reopening the current work keeps its live session. A chapter/paragraph
  /// request can opt out to seek deliberately instead.
  final bool resumeSession;
  final ReaderStore? historyStore;
  final NativePlayer Function()? playerFactory;
  final Future<AudioSource> Function(String itemId, {String? toneId})?
  sourceLoader;
  final Future<List<AudioVoice>> Function()? voicesLoader;

  /// 智能朗读 voices, companion works and the summary shown around the player.
  final AudioExtrasLoader? extrasLoader;

  /// 边听边读 subtitles for one chapter. Resolved with the selected tone id,
  /// because the backend only answers for a real tone.
  final SubtitleLoader? subtitleLoader;

  /// 听书 → 正文的同步映射（官方 AudioTimePoint）。驱动阅读页的朗读高亮；
  /// 没有映射时不高亮，而不是猜一个位置。
  final TimePointLoader? timePointLoader;

  /// Current-chapter opening excerpt shown under the cover, mirroring the
  /// official listening page. Defaults to `/chapters/summary`.
  final Future<String?> Function(String itemId)? excerptLoader;

  /// Directory of another recording or the associated TTS novel. A version
  /// switch uses that book's own chapter IDs. Defaults to the listening API.
  final Future<List<Chapter>> Function(String bookId)? directoryLoader;

  /// 离线音频记录箱。默认用 [HiveAudioDownloadStore.instance]；测试注入
  /// 内存实现后，离线命中判断不依赖真实 Hive 箱。
  final AudioDownloadStore? downloadStore;

  const AudioPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.chapters,
    this.startIndex = 0,
    this.startPosition,
    this.initialToneId,
    this.initialRate,
    this.autoplay = true,
    this.resumeSession = true,
    this.cover = '',
    this.historyStore,
    this.playerFactory,
    this.sourceLoader,
    this.voicesLoader,
    this.extrasLoader,
    this.subtitleLoader,
    this.timePointLoader,
    this.excerptLoader,
    this.directoryLoader,
    this.downloadStore,
  });

  @override
  State<AudioPage> createState() => _AudioPageState();
}

/// Optional listening-page decorations. A caller that already injects its own
/// source, voice or player stubs is offline by construction, so the page does
/// not reach for the network behind its back.
///
/// Note: 听书页版式复刻、字幕与音色的实测契约 — 见
/// .agents/notes/implemented/feature/2026-09-10-detail-audio-replica.md
class AudioExtras {
  const AudioExtras({
    this.tones = const AudioToneSet(),
    this.related = const [],
    this.detail,
  });

  final AudioToneSet tones;
  final List<RelatedWork> related;
  final BookDetail? detail;
}

typedef AudioExtrasLoader = Future<AudioExtras> Function(String bookId);
typedef SubtitleLoader =
    Future<SubtitleTrack> Function(String itemId, String toneId);

typedef TimePointLoader =
    Future<AudioTimeTrack> Function(String itemId, String toneId);

typedef _ReadAlongSnapshot = ({
  String chapterTitle,
  SubtitleTrack track,
  Duration position,
  Duration duration,
});

typedef _MoreSnapshot = ({
  bool loading,
  bool autoAdvance,
  int? sleepMinutes,
  bool sleepAtChapterEnd,
});

typedef _RoutePlayback = ({
  int index,
  Duration position,
  bool completed,
  bool autoplay,
});

Future<AudioExtras> _defaultAudioExtras(String bookId) async {
  final tones = await ApiClient.instance
      .bookTones(bookId)
      .catchError((Object _) => const AudioToneSet());
  final related = await ApiClient.instance
      .relatedWorks(bookId)
      .catchError((Object _) => const <RelatedWork>[]);
  final detail = await ApiClient.instance
      .bookDetail(bookId)
      .catchError((Object _) => const BookDetail());
  return AudioExtras(tones: tones, related: related, detail: detail);
}

class _AudioPageState extends State<AudioPage> {
  _AudioPlaybackController? _session;
  _AudioPlaybackScopeState? _owner;
  bool _attaching = false;
  bool _attachFailed = false;

  /// 封面取色得到的整页配色。null 表示还没算完或取色失败，此时用官方
  /// 截图里那套暖棕兜底（[AudioPageTheme.fallback]）。
  AudioPageTheme? _theme;
  String _themeSource = '';
  _AudioPlaybackController get c => _session!;

  /// 封面变了才重算，避免每次 rebuild 都读一次缓存文件。
  void _syncCoverTheme() {
    final session = _session;
    if (session == null) return;
    final cover = session._cover;
    if (cover == _themeSource) return;
    _themeSource = cover;
    if (cover.isEmpty) {
      if (_theme != null) setState(() => _theme = null);
      return;
    }
    unawaited(() async {
      final dominant = await fetchCoverDominant(cover);
      if (!mounted || cover != _themeSource) return;
      setState(() {
        _theme = dominant == null
            ? null
            : AudioPageTheme.fromCover(
                dominant,
                dark: Theme.of(context).brightness == Brightness.dark,
              );
      });
    }());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AudioFloatingRouteScope.configure(context, hidden: true);
    if (!_attaching) {
      _attaching = true;
      _owner = context.findAncestorStateOfType<_AudioPlaybackScopeState>();
      unawaited(_attach());
    }
  }

  Future<void> _attach() async {
    await Future<void>.value();
    if (!mounted) return;
    final owner = _owner;
    _AudioPlaybackController? session;
    try {
      session = owner == null
          ? _AudioPlaybackController(widget)
          : await owner.acquire(widget);
    } catch (_) {
      if (mounted) setState(() => _attachFailed = true);
      return;
    }
    if (session == null) return;
    if (!mounted) {
      if (owner == null) await session.close();
      return;
    }
    _session = session;
    session.addListener(_changed);
    if (owner == null) session.start();
    owner?.registerView(this);
    _syncCoverTheme();
    setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    _syncCoverTheme();
    setState(() {});
  }

  @override
  void dispose() {
    final session = _session;
    session?.removeListener(_changed);
    if (session != null && !session._closed) {
      unawaited(session._persistProgress());
    }
    _owner?.unregisterView(this);
    if (_owner == null && session != null) unawaited(session.close());
    super.dispose();
  }

  Future<void> _showRates() async {
    final palette = HomePalette.of(context);
    final minRate = _AudioPlaybackController.minRate;
    final maxRate = _AudioPlaybackController.maxRate;
    // Slider 在 divisions 模式下会算出 0.6000000000000001 这种尾数，直接显示
    // 会变成一串小数，统一按 0.1 取整后再显示与应用。
    double snap(double value) => (value * 10).roundToDouble() / 10;
    var draft = snap(c._rate);

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: StatefulBuilder(
          builder: (context, setSheetState) {
            final muted = TextStyle(fontSize: 12, color: palette.muted);
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Text(
                        '播放速度',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${_rateLabel(draft)}×',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: palette.accentText,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    key: const ValueKey('audio-speed-slider'),
                    value: draft,
                    min: minRate,
                    max: maxRate,
                    divisions: ((maxRate - minRate) * 10).round(),
                    label: '${_rateLabel(draft)}×',
                    onChanged: (value) {
                      final next = snap(value);
                      if (next == draft) return;
                      setSheetState(() => draft = next);
                      unawaited(c._setRate(next));
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${_rateLabel(minRate)}×', style: muted),
                        Text('${_rateLabel(maxRate)}×', style: muted),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: TextButton(
                      onPressed: draft == 1
                          ? null
                          : () {
                              setSheetState(() => draft = 1);
                              unawaited(c._setRate(1));
                            },
                      child: const Text('恢复 1.0×'),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _showVoices() async {
    if (c._switchingVersion) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.72,
        child: VoiceSettingsSheet(
          selectedId: c._extras.tones.hasFixedTone ? c._bookId : c._toneId,
          narrators: _narratorOptions(),
          online: _onlineOptions(),
          onSelect: (option) {
            unawaited(_applyVoiceOption(option, fromSheet: sheetContext));
          },
        ),
      ),
    );
  }

  /// A 真人讲书 row names another book. Keep the sheet up for a cross-book
  /// switch so the recording page never flashes underneath.
  Future<void> _applyVoiceOption(
    VoiceOption option, {
    BuildContext? fromSheet,
  }) async {
    if (!mounted || c._switchingVersion) return;
    for (final narrator in c._narratorTones) {
      if (narrator.id == option.id) {
        if (narrator.id == c._bookId) {
          _popSheet(fromSheet);
          return;
        }
        await _switchBookVersion(
          narrator.id,
          title: narrator.title,
          cover: c._cover,
          toneId: '0',
          replaceContext: fromSheet,
        );
        return;
      }
    }
    await _selectTone(option.id, replaceContext: fromSheet);
  }

  void _popSheet(BuildContext? sheet) {
    if (sheet != null && sheet.mounted) Navigator.pop(sheet);
  }

  List<VoiceOption> _narratorOptions() => [
    for (final tone in c._uniqueTones(c._extras.tones.narratorTones))
      VoiceOption(
        id: tone.id,
        title: tone.title,
        description: tone.description,
        badge: tone.badge,
      ),
  ];

  /// 智能朗读 grid: mirrors the upstream `tts_tones` list as-is — same names,
  /// same order — but only the voices playinfo can actually serve.
  ///
  /// The `tts_tones` list *is* the selectable set: every id it carries answers
  /// a distinct stream (verified against the live playinfo endpoint). Three
  /// other sources must never reach the panel:
  ///
  ///  * the synthetic `0` / 默认音色 row [parseAudioVoices] always adds, which
  ///    a pure-TTS book answers with `NO_THIS_TONE`;
  ///  * offline (`offline_tts_tones`) ids, which playinfo rejects outright —
  ///    they require the offline download path;
  ///  * 真人讲书 (`audio_tones`) ids, which are `abook_id`s and are likewise
  ///    rejected when used as a `tone_id`.
  ///
  /// When `/tones` is unavailable the detail CSV still lists real tone ids, so
  /// it is used as a fallback rather than offering nothing at all.
  List<VoiceOption> _onlineOptions() {
    final ids = <String>{};
    final options = <VoiceOption>[
      for (final tone in c._uniqueTones(c._ttsTones))
        if (c._selectableTone(tone.id) && ids.add(tone.id))
          VoiceOption(
            id: tone.id,
            title: tone.title,
            description: tone.description,
            badge: tone.badge,
            isMultiTone: tone.isMultiTone,
          ),
    ];
    if (options.isNotEmpty) return options;
    for (final voice in c._voices) {
      if (!c._selectableTone(voice.id) || !ids.add(voice.id)) continue;
      options.add(VoiceOption(id: voice.id, title: voice.label));
    }
    return options;
  }

  Future<void> _showCatalog() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _AudioCatalog(
        chapters: c._chapters,
        currentIndex: c._index,
        unit: c._mode == 'narrator' ? '集' : '章',
      ),
    );
    if (!mounted || selected == null || selected == c._index) return;
    await c._openChapter(selected);
  }

  static String _rateLabel(double rate) => formatPlaybackRate(rate);

  @override
  Widget build(BuildContext context) {
    if (_session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('听书')),
        body: Center(
          child: _attachFailed
              ? TextButton(
                  onPressed: () {
                    setState(() => _attachFailed = false);
                    unawaited(_attach());
                  },
                  child: const Text('打开失败，点击重试'),
                )
              : const Text('正在打开听书…'),
        ),
      );
    }
    if (c._closed) {
      return Scaffold(
        appBar: AppBar(title: const Text('听书')),
        body: const Center(child: Text('本次播放已关闭')),
      );
    }
    final palette = HomePalette.of(context);
    if (c._chapters.isEmpty) {
      return Scaffold(
        key: ValueKey('audio_session_${c._bookId}'),
        backgroundColor: palette.canvas,
        appBar: AppBar(
          backgroundColor: palette.canvas,
          surfaceTintColor: Colors.transparent,
          title: const Text('听书'),
        ),
        body: Center(
          child: Text('暂无可播放章节', style: TextStyle(color: palette.muted)),
        ),
      );
    }
    final chapter = c._chapters[c._index];
    final realAudio = c._mode == 'narrator';
    final tones = realAudio ? c._narratorTones : c._ttsTones;
    final detail = c._extras.detail;
    final introSummary = detail?.abstract ?? '';
    final related = c._extras.related.isEmpty ? null : c._extras.related.first;
    final hasIntro =
        introSummary.isNotEmpty ||
        (detail?.author.name.isNotEmpty ?? false) ||
        detail?.title.isNotEmpty == true;
    // Windows 桌面端用独立版式；它只需要 tones，上面这些局部变量先算好并不吃亏。
    if (isWindowsDesktop) return _desktopAudio(palette, chapter, tones);

    // 官方整页底色/字色都取自封面（见 audio_page_theme.dart）。
    final pageDark = palette.dark;
    final theme =
        (_theme ??
                (pageDark
                    ? AudioPageTheme.fallbackDark
                    : AudioPageTheme.fallback))
            .withOled(palette.oled && pageDark);
    return AudioPageThemeScope(
      theme: theme,
      oled: palette.oled && pageDark,
      child: _listeningScaffold(
        theme: theme,
        pageDark: pageDark,
        chapter: chapter,
        realAudio: realAudio,
        tones: tones,
        detail: detail,
        introSummary: introSummary,
        related: related,
        hasIntro: hasIntro,
      ),
    );
  }

  Widget _desktopAudio(
    HomePalette palette,
    Chapter chapter,
    List<AudioTone> tones,
  ) => Scaffold(
    backgroundColor: palette.canvas,
    body: Column(
      children: [
        AudioTopBar(
          onCollapse: () => Navigator.maybePop(context),
          onMore: _showMore,
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 600),
                      child: Column(
                        children: [
                          AudioBookCard(
                            cover: c._cover,
                            bookTitle: c._title,
                            chapterTitle: chapter.title,
                            onSwitch: _showVoices,
                            onOpenBook: _showCatalog,
                          ),
                          const SizedBox(height: 20),
                          _statusLine(palette),
                          if (c._excerpt.isNotEmpty)
                            AudioExcerpt(text: c._excerpt, onTap: _showExcerpt),
                          const SizedBox(height: 12),
                          AudioIconRow(actions: _iconActions),
                          const SizedBox(height: 24),
                          AudioToneSection(
                            title: c._mode == 'narrator' ? '真人讲书' : '智能朗读',
                            tones: tones,
                            selectedId: c._extras.tones.hasFixedTone
                                ? c._bookId
                                : c._toneId,
                            currentChapterTitle: chapter.title,
                            onSelect: _onToneSelected,
                            onReadAlong: _showReadAlong,
                            onShowVoices: c._switchingVersion
                                ? null
                                : _showVoices,
                          ),
                          if (c._extras.related.isNotEmpty)
                            AudioRelatedRow(
                              works: c._extras.related,
                              onTap: _openRelated,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: MediaQuery.sizeOf(context).width >= 1200 ? 360 : 280,
                child: DefaultTabController(
                  length: 2,
                  child: Column(
                    children: [
                      const TabBar(
                        tabs: [
                          Tab(text: '章节目录'),
                          Tab(text: '同步字幕'),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            DesktopChapterSidebar(
                              chapters: c._chapters,
                              currentIndex: c._index,
                              onSelected: (index) =>
                                  unawaited(c._openChapter(index)),
                            ),
                            ValueListenableBuilder<Duration>(
                              valueListenable: c._position,
                              builder: (context, position, _) {
                                final track = c._subtitles;
                                if (track.isEmpty) {
                                  // 官方两种空态都走 `setStatusText`，文案统一。
                                  return const Center(
                                    child: Text(
                                      '本章暂无同步字幕',
                                      key: Key('audio-subtitle-page-empty'),
                                    ),
                                  );
                                }
                                // 高亮与自动滚动都在 `AudioSubtitleList`
                                // 里：跟着朗读进度滚到当前句并标出它。
                                return AudioSubtitleList(
                                  track: track,
                                  active: track.indexAt(position),
                                  onSeek: c._ready
                                      ? (startMs) => c._seekTo(
                                          Duration(milliseconds: startMs),
                                        )
                                      : null,
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Material(
          color: palette.surface,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 8, 32, 12),
            child: Column(
              children: [
                ValueListenableBuilder<Duration>(
                  valueListenable: c._position,
                  builder: (context, position, _) => AudioProgressRow(
                    position: position,
                    duration: c._duration,
                    preview: c._seekPreview.value,
                    enabled: c._ready,
                    onChanged: (value) => c._seekPreview.value = value,
                    onChangeEnd: (value) =>
                        c._seekTo(Duration(milliseconds: value.round())),
                    onBack15: c._ready
                        ? () => c._seekTo(
                            c._position.value - const Duration(seconds: 15),
                          )
                        : null,
                    onForward15: c._ready
                        ? () => c._seekTo(
                            c._position.value + const Duration(seconds: 15),
                          )
                        : null,
                  ),
                ),
                _transport(),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _showExcerpt() async {
    if (c._excerpt.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: SingleChildScrollView(
            child: Text(
              c._excerpt,
              style: TextStyle(
                color: HomePalette.of(context).ink,
                fontSize: 15,
                height: 1.7,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// TTS shares stable chapter IDs with the novel. Fixed recordings retain
  /// their subtitle view; their chapter numbers cannot map a different book.
  Future<void> _showReadAlong() async {
    if (c._closed || c._chapters.isEmpty) return;
    if (c._mode == 'tts' && c._ttsBookId == c._bookId && !c._offline) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage(
            bookId: c._bookId,
            title: c._title,
            cover: c._cover,
            chapters: c._chapters,
            startIndex: c._index,
          ),
        ),
      );
      return;
    }
    final palette = HomePalette.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => ValueListenableBuilder<_ReadAlongSnapshot>(
        valueListenable: c._readAlong,
        builder: (context, snapshot, _) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.6,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    snapshot.chapterTitle,
                    key: const ValueKey('audio-read-along-chapter'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: palette.ink, fontSize: 16),
                  ),
                  // 官方只显示服务端文稿；这份是本地估算的，必须告诉用户，
                  // 否则会被当成官方时间轴相信。
                  if (c.subtitlesEstimated) ...[
                    const SizedBox(height: 4),
                    Text(
                      '字幕为本地估算，可能与声音有偏差',
                      key: const ValueKey('audio-subtitle-estimated'),
                      style: TextStyle(color: palette.muted, fontSize: 11.5),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Expanded(
                    child: snapshot.track.isEmpty
                        ? Center(
                            child: Text(
                              '本章暂无同步字幕',
                              key: const ValueKey('audio-read-along-empty'),
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 13,
                              ),
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, box) => AudioSubtitleScroller(
                              track: snapshot.track,
                              position: snapshot.position,
                              viewportHeight: box.maxHeight,
                              // 官方 `subtitle/x0` 对文稿页同样传
                              // `setScrollingSeekEnable(false)`，drag/fling
                              // 在本版本不可达，所以这里也不启用。
                              fontSize: 16,
                              // 官方字段 `o` 的默认值就是 3（`getInt` 的返回值
                              // 被丢弃后硬置 3），只有内联槽会 `setStartLine(1)`。
                              startLine: 3,
                              currentLineKey: const Key(
                                'audio_subtitle_current',
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 当前主播的上游标签（形如 `主播：老恒`），供真人讲书页头那一行使用。
  /// 正在播放的书不在返回列表里时退回第一个版本，与音色面板的默认一致。
  String get _narratorLabel {
    for (final tone in c._narratorTones) {
      if (tone.id == c._bookId) return tone.title;
    }
    return c._narratorTones.isEmpty ? '' : c._narratorTones.first.title;
  }

  /// `layout/bin.xml`: 目录 / 上一章 / 播放暂停 / 下一章 / 定时。
  ///
  /// 官方只给「目录」「定时」配 12sp 文字标签，上一章/下一章是纯 24dp 图标，
  /// 播放键 60dp；加载或缓冲时它换成转圈指示。
  Widget _transport() {
    final palette = HomePalette.of(context);
    final playing = c._wantPlay && !c._completed;
    final loading = c._loading || (c._player?.buffering ?? false);
    // 官方用 40dip 的固定间距托住播放键；窄屏（≤320dp）或大字号下按可用宽度
    // 收缩，避免 RenderFlex 溢出，同时保持播放键居中。
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = ((constraints.maxWidth - 252) / 3).clamp(8.0, 40.0);
        return Row(
          children: [
            _TransportButton(
              icon: LucideIcons.list,
              tooltip: '目录',
              label: '目录',
              onTap: _showCatalog,
            ),
            const Spacer(),
            _TransportButton(
              icon: LucideIcons.skip_back,
              tooltip: '上一章',
              onTap: c._index > 0 ? () => c._openChapter(c._index - 1) : null,
            ),
            SizedBox(width: gap),
            Semantics(
              button: true,
              child: SizedBox(
                key: const Key('audio_play'),
                width: 60,
                height: 60,
                child: IconButton(
                  tooltip: playing ? '暂停' : '播放',
                  onPressed: c._ready ? c._togglePlayback : null,
                  padding: EdgeInsets.zero,
                  iconSize: 40,
                  style: IconButton.styleFrom(
                    foregroundColor: palette.ink,
                    disabledForegroundColor: palette.muted.withValues(
                      alpha: 0.5,
                    ),
                  ),
                  icon: loading && !playing
                      ? SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: palette.accentText,
                          ),
                        )
                      : Icon(playing ? LucideIcons.pause : LucideIcons.play),
                ),
              ),
            ),
            SizedBox(width: gap),
            _TransportButton(
              icon: LucideIcons.skip_forward,
              tooltip: '下一章',
              onTap: c._index + 1 < c._chapters.length
                  ? () => c._openChapter(c._index + 1)
                  : null,
            ),
            const Spacer(),
            _TransportButton(
              icon: LucideIcons.alarm_clock,
              tooltip: '定时',
              label: '定时',
              active: c._sleepRemaining != null,
              onTap: _showSleepTimer,
            ),
          ],
        );
      },
    );
  }

  Widget _statusLine(HomePalette palette) {
    if (c._error case final message?) {
      return Column(
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          FilledButton.icon(
            key: const ValueKey('audio-retry'),
            onPressed: () => c._openChapter(c._index, restoreHistory: true),
            style: FilledButton.styleFrom(backgroundColor: HomePalette.accent),
            icon: const Icon(LucideIcons.refresh_cw, size: 16),
            label: const Text('重试'),
          ),
        ],
      );
    }
    if (c._loading || (c._player?.buffering ?? false)) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox.square(
            dimension: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: HomePalette.accent,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            c._loading ? '正在加载音频…' : '缓冲中…',
            style: TextStyle(color: palette.muted, fontSize: 12.5),
          ),
        ],
      );
    }
    // 走到这里只可能是「本章播完」：本卡片的渲染条件已限定
    // error / loading / buffering / completed 四种，前三种上面都提前返回了。
    // 原先这里还有个「正在播放 / 已暂停」的分支，永远不可达，已删除。
    // 官方 `v7`「已播完最新章节，去听听其它内容吧」只在**末章**播完时出现。
    return Text(
      c.atLastChapter ? '已播完最新章节，去听听其它内容吧' : '本章已播完',
      textAlign: TextAlign.center,
      style: TextStyle(color: palette.muted, fontSize: 12.5),
    );
  }

  Future<void> _selectTone(
    String toneId, {
    BuildContext? replaceContext,
  }) async {
    if (c._switchingVersion || !c._selectableTone(toneId)) return;
    final novel = c._extras.tones.relatedNovel;
    if (c._ttsBookId != c._bookId && novel != null) {
      await _switchBookVersion(
        novel.id,
        title: novel.title.isEmpty ? c._title : novel.title,
        cover: novel.cover.isEmpty ? c._cover : novel.cover,
        toneId: toneId,
        replaceContext: replaceContext,
      );
      return;
    }
    _popSheet(replaceContext);
    if (toneId == c._toneId) return;
    await c._openChapter(
      c._index,
      position: c._player?.position ?? c._position.value,
      toneId: toneId,
      autoplay: c._wantPlay,
      completed: c._completed,
    );
  }

  Future<void> _toggleShelf() async {
    if (c._closed) return;
    final store = ShelfStore.instance;
    final next = store.isReady ? await store.toggle(c._shelfItem) : !c._inShelf;
    if (!mounted || c._closed) return;
    c._update(() => c._inShelf = next);
    // The shelf flag is independent of playback, so it is written even when
    // nothing has been played yet in this session. The history copy stays as
    // the legacy mirror of the flag.
    try {
      final existing =
          await c._history.load(c._bookId) ?? const <String, dynamic>{};
      await c._history.save({
        ...existing,
        'id': c._bookId,
        'bookId': c._bookId,
        'kind': 'audio',
        'title': c._title,
        'cover': c._cover,
        'inShelf': next,
      });
    } on Exception {
      // A storage failure must not desync the visible toggle.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(next ? '已加入书架' : '已移出书架'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Caches the book's chapters for offline listening/reading.
  Future<void> _showDownload() async {
    final cache = ChapterCacheStore.instance;
    final book = CachedBook(
      id: c._bookId,
      title: c._title,
      cover: c._cover,
      chapters: c._chapters,
    );
    try {
      await cache.saveBook(book);
    } on Exception {
      // A cache index failure must not block the sheet.
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => ChapterCacheSheet(
        book: book,
        currentIndex: c._index,
        cache: cache,
        loader: (chapter) => ApiClient.instance.contentText(chapter.itemId),
        extraSection: AudioOfflineSection(
          bookId: c._bookId,
          title: c._title,
          cover: c._cover,
          toneId: c._toneId,
          chapters: c._chapters,
        ),
      ),
    );
  }

  /// Book reviews for the work being listened to.
  ///
  /// Named for what it shows rather than the official page's 章评 label: the
  /// backend has no chapter-comment endpoint (see the 书评 action above).
  Future<void> _showBookReviews() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _AudioCommentsSheet(
        bookId: c._bookId,
        loader: widget.sourceLoader != null || widget.playerFactory != null
            ? null
            : ApiClient.instance.bookComments,
      ),
    );
  }

  /// 睡眠定时：三档（关闭 / 听完本章 / N 分钟后），官方 `cip`「听完本章」。
  Future<void> _showSleepTimer() async {
    // 当前档位：听完本章优先，其次按剩余分钟落到最接近的档，否则关闭。
    final SleepTimerChoice current;
    if (c.sleepAtChapterEnd) {
      current = const SleepTimerChoice.endOfChapter();
    } else if (c._sleepRemaining case final remaining?) {
      final minutes = (remaining.inSeconds / 60).ceil();
      current = SleepTimerChoice.minutes(
        minutes >= 60 ? 60 : (minutes >= 30 ? 30 : 15),
      );
    } else {
      current = const SleepTimerChoice.off();
    }
    const minuteOptions = <int>[15, 30, 60];
    final picked = await showModalBottomSheet<SleepTimerChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        Widget tile(String label, SleepTimerChoice choice, bool selected) {
          return ListTile(
            title: Text(label),
            trailing: selected
                ? const Icon(LucideIcons.check, color: HomePalette.accent)
                : null,
            onTap: () => Navigator.pop(context, choice),
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('定时关闭')),
              tile(
                '听完本章',
                const SleepTimerChoice.endOfChapter(),
                current.endOfChapter,
              ),
              for (final minutes in minuteOptions)
                tile(
                  '$minutes 分钟后',
                  SleepTimerChoice.minutes(minutes),
                  !current.endOfChapter && current.minutes == minutes,
                ),
              tile('关闭定时', const SleepTimerChoice.off(), current.isOff),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (!mounted || picked == null) return;
    _applySleepTimerChoice(c, picked);
    final message = picked.isOff
        ? '已关闭定时'
        : picked.endOfChapter
        ? '本章播完后停止播放'
        : '将在 ${picked.minutes} 分钟后停止播放';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _showMore() async {
    c._publishMoreState();
    final palette = HomePalette.of(context);
    await showModalBottomSheet<void>(
      context: context,
      // 深色 / OLED 下弹层取 surface：barrier 在纯黑画布上叠不出变暗，
      // 用 canvas 会和听书页连成一片，看不出弹层上缘。
      backgroundColor: homeSheetColor(palette),
      shape: homeSheetShape(palette, top: 24),
      showDragHandle: false,
      builder: (context) {
        final palette = HomePalette.of(context);
        return SafeArea(
          // 加了「跳过片头/片尾」两行后，面板在小屏上会超过 sheet 的最大高度，
          // 必须可滚动，否则 RenderFlex 直接溢出。
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: palette.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text(
                      '播放设置',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: palette.ink,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '关闭',
                      icon: Icon(LucideIcons.x, size: 20, color: palette.muted),
                      onPressed: () => Navigator.pop(context),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Material(
                  color: homeSheetCardColor(palette),
                  borderRadius: BorderRadius.circular(18),
                  clipBehavior: Clip.antiAlias,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: palette.line.withValues(alpha: 0.6),
                        width: 0.8,
                      ),
                    ),
                    child: ValueListenableBuilder<_MoreSnapshot>(
                      valueListenable: c._moreState,
                      builder: (context, snapshot, _) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 官方 bik.xml 的面板只有三行快捷入口：
                          // 语速(dh) / 定时(di) / 音色(aag)。
                          AudioQuickRows(
                            rateLabel:
                                '${_AudioPageState._rateLabel(c._rate)}x',
                            timerLabel: sleepTimerLabel(
                              atChapterEnd: snapshot.sleepAtChapterEnd,
                              remaining: c._sleepRemaining,
                            ),
                            toneLabel: _currentToneLabel,
                            // 与原来的「定时关闭」行一致：先关掉这个面板再开
                            // 子面板，避免两个 sheet 叠在一起（叠层后遮罩会
                            // 吃掉后续点击）。
                            onRate: () {
                              Navigator.pop(context);
                              unawaited(_showRates());
                            },
                            onTimer: () {
                              Navigator.pop(context);
                              unawaited(_showSleepTimer());
                            },
                            onTone: () {
                              Navigator.pop(context);
                              unawaited(_showVoices());
                            },
                          ),
                          Divider(
                            height: 1,
                            indent: 16,
                            color: palette.line.withValues(alpha: 0.5),
                          ),
                          // 官方 du/dq：跳过片头/片尾按书保存，默认关闭。
                          AudioSkipPointsRows(
                            points: c.skipPoints,
                            onChanged: (points) =>
                                unawaited(c.setSkipPoints(points)),
                          ),
                          Divider(
                            height: 1,
                            indent: 68,
                            color: palette.line.withValues(alpha: 0.5),
                          ),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 2,
                            ),
                            leading: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF10B981,
                                ).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                LucideIcons.list,
                                size: 20,
                                color: Color(0xFF10B981),
                              ),
                            ),
                            title: Text(
                              '书籍目录',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: palette.ink,
                              ),
                            ),
                            subtitle: Text(
                              '共 ${c._chapters.length} ${c._mode == 'narrator' ? '集' : '章'}',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: palette.muted,
                              ),
                            ),
                            trailing: Icon(
                              LucideIcons.chevron_right,
                              size: 18,
                              color: palette.muted,
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              unawaited(_showCatalog());
                            },
                          ),
                          Divider(
                            height: 1,
                            indent: 68,
                            color: palette.line.withValues(alpha: 0.5),
                          ),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 2,
                            ),
                            leading: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFFF59E0B,
                                ).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                LucideIcons.skip_forward,
                                size: 20,
                                color: Color(0xFFF59E0B),
                              ),
                            ),
                            title: Text(
                              '自动下一章',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: palette.ink,
                              ),
                            ),
                            subtitle: Text(
                              '当前章节播完后自动连播',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: palette.muted,
                              ),
                            ),
                            trailing: Switch(
                              key: const ValueKey('audio-auto-next'),
                              value: snapshot.autoAdvance,
                              onChanged: snapshot.loading
                                  ? null
                                  : (enabled) {
                                      if (!mounted || c._loading) return;
                                      c._update(() => c._autoAdvance = enabled);
                                      c._publishMoreState();
                                      unawaited(c._persistProgress());
                                    },
                            ),
                            onTap: snapshot.loading
                                ? null
                                : () {
                                    if (!mounted || c._loading) return;
                                    c._update(
                                      () => c._autoAdvance =
                                          !snapshot.autoAdvance,
                                    );
                                    c._publishMoreState();
                                    unawaited(c._persistProgress());
                                  },
                          ),
                          Divider(
                            height: 1,
                            indent: 68,
                            color: palette.line.withValues(alpha: 0.5),
                          ),
                          ValueListenableBuilder<bool>(
                            valueListenable:
                                AudioPreferences.instance.backgroundPlayback,
                            builder: (context, bgEnabled, _) => ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 2,
                              ),
                              leading: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFF8B5CF6,
                                  ).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  LucideIcons.headphones,
                                  size: 20,
                                  color: Color(0xFF8B5CF6),
                                ),
                              ),
                              title: Text(
                                '后台听书与保活',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                  color: palette.ink,
                                ),
                              ),
                              subtitle: Text(
                                '切到后台或锁屏时继续播放并常驻控制卡片',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: palette.muted,
                                ),
                              ),
                              trailing: Switch(
                                key: const ValueKey(
                                  'audio-background-playback',
                                ),
                                value: bgEnabled,
                                onChanged: (enabled) {
                                  unawaited(
                                    AudioPreferences.instance
                                        .setBackgroundPlayback(enabled),
                                  );
                                },
                              ),
                              onTap: () {
                                final next = !bgEnabled;
                                unawaited(
                                  AudioPreferences.instance
                                      .setBackgroundPlayback(next),
                                );
                              },
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
      },
    );
  }

  /// Opens the audio book a 真人讲书 row names.
  ///
  /// Such a row carries an `abook_id`, i.e. a *different book* — one per
  /// narrator version — not a voice. playinfo ignores an abook_id sent as a
  /// `tone_id` (NO_THIS_TONE even with the exact int64), while
  /// `book_id = abook_id` with that book's own chapter plays it.
  Future<void> _switchNarrator(AudioTone tone) => _switchBookVersion(
    tone.id,
    title: tone.title,
    cover: c._cover,
    toneId: '0',
  );

  /// Note: Cross-book TTS choices and exact IDs — see
  /// .agents/notes/implemented/bug-fix/2026-09-16-linked-audio-voices.md.
  /// Note: 真人讲书切智能朗读在同一听书页完成 — 见
  /// .agents/notes/implemented/bug-fix/2026-09-18-audio-voice-switch-flash.md
  Future<void> _switchBookVersion(
    String targetId, {
    required String title,
    required String cover,
    required String toneId,
    BuildContext? replaceContext,
  }) async {
    _popSheet(replaceContext);
    try {
      await c._switchBookVersion(
        targetId,
        title: title,
        cover: cover,
        toneId: toneId,
      );
    } catch (_) {
      if (!mounted || c._closed) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂时无法切换声音，请稍后重试')));
    }
  }

  /// A voice row either switches the playing voice or opens another audio
  /// book, depending on the family it belongs to.
  void _onToneSelected(AudioTone tone) {
    if (c._narratorTones.any((narrator) => narrator.id == tone.id)) {
      unawaited(_switchNarrator(tone));
      return;
    }
    unawaited(_selectTone(tone.id));
  }

  Future<void> _openRelated(RelatedWork work) async {
    if (c._closed || work.id.isEmpty || c._switchingVersion) return;
    final generation = c._generation;
    _RoutePlayback? suspended;
    c._update(() => c._switchingVersion = true);
    try {
      // The app owns playback across routes; a standalone page keeps its old
      // release/restore contract when no application session owner exists.
      if (_owner == null) {
        suspended = await c._suspendForRoute(generation);
        if (suspended == null) return;
      }
      if (!mounted || c._closed) return;
      await openBookDetail(
        context,
        MediaItem(
          id: work.id,
          title: work.title,
          cover: work.cover,
          author: '',
          badge: work.label,
          ep: '',
          kind: work.kind == 'video' ? 'video' : 'book',
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂时无法打开作品，请稍后重试')));
    } finally {
      await c._restoreAfterRoute(suspended);
      c._update(() => c._switchingVersion = false);
    }
  }
}

/// Reviews sheet opened from the 书评 action.
class _AudioCommentsSheet extends StatefulWidget {
  final String bookId;
  final Future<BookCommentPage> Function(String bookId, {int offset})? loader;

  const _AudioCommentsSheet({required this.bookId, this.loader});

  @override
  State<_AudioCommentsSheet> createState() => _AudioCommentsSheetState();
}

class _AudioCommentsSheetState extends State<_AudioCommentsSheet> {
  BookCommentPage? _page;
  List<BookComment> _comments = const [];
  bool _failed = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _nextOffset = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final loader = widget.loader;
    if (loader == null) {
      setState(() => _failed = true);
      return;
    }
    try {
      final page = await loader(widget.bookId);
      if (mounted) {
        setState(() {
          _page = page;
          _comments = page.comments;
          _hasMore = page.hasMore;
          _nextOffset = page.nextOffset;
        });
      }
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _loadMore() async {
    final loader = widget.loader;
    if (loader == null || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await loader(widget.bookId, offset: _nextOffset);
      if (!mounted) return;
      setState(() {
        _comments = [..._comments, ...page.comments];
        _hasMore = page.hasMore;
        _nextOffset = page.nextOffset;
        _loadingMore = false;
      });
    } on Exception {
      // The appended list stays; the footer flips back so it can be retried.
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final page = _page;
    final hasMore = _hasMore && widget.loader != null;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Row(
              children: [
                Text(
                  page?.headerLabel ?? '书评',
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (page != null && page.scoreLabel.isNotEmpty)
                  Text(
                    page.scoreLabel,
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _failed
                ? Center(
                    child: Text(
                      '暂时无法加载书评',
                      style: TextStyle(color: palette.muted),
                    ),
                  )
                : page == null
                ? const Center(
                    child: CircularProgressIndicator(color: HomePalette.accent),
                  )
                : _comments.isEmpty
                ? Center(
                    child: Text(
                      '还没有书评',
                      style: TextStyle(color: palette.muted),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: _comments.length + (hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _comments.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: _loadingMore
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: HomePalette.accent,
                                    ),
                                  )
                                : TextButton(
                                    key: const Key('audio_comments_more'),
                                    onPressed: _loadMore,
                                    child: Text(
                                      '加载更多书评',
                                      style: TextStyle(
                                        color: palette.accentText,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                          ),
                        );
                      }
                      final comment = _comments[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    comment.userName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: palette.ink,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  comment.relativeTime(),
                                  style: TextStyle(
                                    color: palette.muted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            if (comment.text.isNotEmpty)
                              Text(
                                comment.text,
                                style: TextStyle(
                                  color: palette.ink,
                                  fontSize: 13,
                                  height: 1.65,
                                ),
                              ),
                            if (comment.imageUrls.isNotEmpty) ...[
                              if (comment.text.isNotEmpty)
                                const SizedBox(height: 8),
                              CommentImages(imageUrls: comment.imageUrls),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Compact transport control.
///
/// With [label] it is the official icon-over-caption button used by 目录 / 定时
/// (`bin.xml`: 24dp icon + 12sp text); without it, a bare 24dp icon button
/// (上一章 / 下一章).
class _TransportButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  final String? label;

  const _TransportButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final color = onTap == null
        ? palette.line
        : (active ? palette.accentText : palette.ink);
    final caption = label;
    if (caption == null) {
      return IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        iconSize: 24,
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          foregroundColor: color,
          disabledForegroundColor: palette.line,
          minimumSize: const Size(48, 48),
        ),
        icon: Icon(icon),
      );
    }
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 24, color: color),
                const SizedBox(height: 4),
                Text(caption, style: TextStyle(color: color, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AudioCatalog extends StatefulWidget {
  final List<Chapter> chapters;
  final int currentIndex;

  /// 章节单位：真人讲书按「集」计，其它情况仍是「章」。
  final String unit;

  const _AudioCatalog({
    required this.chapters,
    required this.currentIndex,
    this.unit = '章',
  });

  @override
  State<_AudioCatalog> createState() => _AudioCatalogState();
}

class _AudioCatalogState extends State<_AudioCatalog> {
  late final _controller = ScrollController(
    initialScrollOffset: widget.currentIndex * 72.0,
  );
  String _query = '';

  String get _hintLabel => widget.unit == '集' ? '搜索集名或序号' : '搜索章节名称或序号';

  String get _emptyLabel => widget.unit == '集' ? '没有匹配的集' : '没有匹配的章节';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final indexes = [
      for (var index = 0; index < widget.chapters.length; index++)
        if (_query.isEmpty ||
            widget.chapters[index].title.toLowerCase().contains(_query) ||
            '${index + 1}' == _query)
          index,
    ];
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: SizedBox(
          height: (MediaQuery.sizeOf(context).height - keyboard) * 0.72,
          child: Column(
            children: [
              Text(
                '目录 · ${widget.chapters.length} ${widget.unit}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: _hintLabel,
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (value) {
                    setState(() => _query = value.trim().toLowerCase());
                    if (_controller.hasClients) _controller.jumpTo(0);
                  },
                ),
              ),
              Expanded(
                child: indexes.isEmpty
                    ? Center(child: Text(_emptyLabel))
                    : ListView.builder(
                        controller: _controller,
                        itemCount: indexes.length,
                        itemExtent: 72,
                        itemBuilder: (context, offset) {
                          final index = indexes[offset];
                          final chapter = widget.chapters[index];
                          return ListTile(
                            key: ValueKey('audio-chapter-$index'),
                            selected: index == widget.currentIndex,
                            leading: Text('${index + 1}'),
                            title: Text(
                              chapter.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: chapter.volumeName.isEmpty
                                ? null
                                : Text(
                                    chapter.volumeName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            trailing: index == widget.currentIndex
                                ? const Icon(Icons.graphic_eq)
                                : null,
                            onTap: () => Navigator.pop(context, index),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
