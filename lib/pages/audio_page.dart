import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/audio_extra.dart';
import '../models/book_comment.dart';
import '../models/book_detail.dart';
import '../models/chapter_media.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/audio_download_store.dart';
import '../services/audio_history.dart';
import '../services/audio_preferences.dart';
import '../services/chapter_cache_store.dart';
import '../services/fair_memory.dart';
import '../services/library_store.dart';
import '../services/listening_session.dart';
import '../services/native_player.dart';
import '../services/playback_format.dart';
import '../services/shelf_store.dart';
import '../services/transient_retry.dart';
import '../services/system_tts.dart';
import '../widgets/audio/audio_offline_section.dart';
import '../widgets/audio/audio_sections.dart';
import '../widgets/audio/voice_settings_sheet.dart';
import '../widgets/audio/system_tts_controls.dart';
import '../widgets/chapter_cache_sheet.dart';
import '../widgets/comment_images.dart';
import '../widgets/home/home_design.dart';
import 'detail_page.dart';
import 'reader_page.dart';

part '../services/audio_playback_controller.dart';
part '../widgets/audio/audio_playback_scope.dart';

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

typedef _ReadAlongSnapshot = ({
  String chapterTitle,
  SubtitleTrack track,
  Duration position,
});

typedef _MoreSnapshot = ({bool loading, bool autoAdvance, int? sleepMinutes});

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
  bool _routeCurrent = true;
  _AudioPlaybackController get c => _session!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    if (!_attaching) {
      _attaching = true;
      _owner = context.findAncestorStateOfType<_AudioPlaybackScopeState>();
      unawaited(_attach());
    }
    _owner?.viewChanged(this);
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
    owner?.viewChanged(this);
    setState(() {});
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    final session = _session;
    session?.removeListener(_changed);
    if (session != null && !session._closed) {
      unawaited(session._persistProgress());
    }
    _owner?.removeView(this);
    if (_owner == null && session != null) unawaited(session.close());
    super.dispose();
  }

  Future<void> _showRates() async {
    final rate = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('播放速度')),
            for (final rate in _AudioPlaybackController._rates)
              ListTile(
                title: Text('${_rateLabel(rate)}×'),
                trailing: rate == c._rate ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, rate),
              ),
          ],
        ),
      ),
    );
    if (mounted && rate != null) await c._setRate(rate);
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
      builder: (context) =>
          _AudioCatalog(chapters: c._chapters, currentIndex: c._index),
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
    final tones = c._mode == 'narrator' ? c._narratorTones : c._ttsTones;
    return Scaffold(
      key: ValueKey('audio_session_${c._bookId}'),
      backgroundColor: palette.canvas,
      body: SafeArea(
        child: Column(
          children: [
            AudioTopBar(
              onCollapse: () => Navigator.maybePop(context),
              onMore: _showMore,
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 10),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: AudioBookCard(
                            cover: c._cover,
                            bookTitle: c._title,
                            chapterTitle: chapter.title,
                            onSwitch: _showVoices,
                            onOpenBook: _showCatalog,
                          ),
                        ),
                        if (c._excerpt.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          AudioExcerpt(text: c._excerpt, onTap: _showExcerpt),
                        ],
                        if (c._error != null ||
                            c._loading ||
                            (c._player?.buffering ?? false) ||
                            c._completed) ...[
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: _statusLine(palette),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: AudioActionRow(actions: _actions),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: ValueListenableBuilder<Duration>(
                            valueListenable: c._position,
                            builder: (context, position, _) =>
                                ValueListenableBuilder<double?>(
                                  valueListenable: c._seekPreview,
                                  builder: (context, seekPreview, _) =>
                                      AudioProgressRow(
                                        position: position,
                                        duration: c._duration,
                                        preview: seekPreview,
                                        enabled: c._ready,
                                        onChanged: (value) =>
                                            c._seekPreview.value = value,
                                        onChangeEnd: (value) => c._seekTo(
                                          Duration(milliseconds: value.round()),
                                        ),
                                        onBack15: c._ready
                                            ? () => c._seekTo(
                                                c._position.value -
                                                    const Duration(seconds: 15),
                                              )
                                            : null,
                                        onForward15: c._ready
                                            ? () => c._seekTo(
                                                c._position.value +
                                                    const Duration(seconds: 15),
                                              )
                                            : null,
                                      ),
                                ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        _transport(),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: AudioToneSection(
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
                        ),
                        if (c._extras.related.isNotEmpty) ...[
                          const SizedBox(height: 18),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: AudioRelatedRow(
                              works: c._extras.related,
                              onTap: _openRelated,
                            ),
                          ),
                        ],
                        const SizedBox(height: 28),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

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
                  const SizedBox(height: 16),
                  Expanded(
                    child: snapshot.track.isEmpty
                        ? Center(
                            child: Text(
                              '本章暂无同步字幕',
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 13,
                              ),
                            ),
                          )
                        : SingleChildScrollView(
                            child: AudioSubtitleView(
                              track: snapshot.track,
                              position: snapshot.position,
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

  /// Icon row: 语速 / 加入书架 / 下载 / 章评 / 更多.
  List<AudioAction> get _actions => [
    AudioAction(
      key: 'audio-speed',
      icon: LucideIcons.gauge,
      label: '语速',
      onTap: c._ready ? _showRates : null,
    ),
    AudioAction(
      key: 'audio_shelf',
      icon: LucideIcons.book_plus,
      label: c._inShelf ? '已在书架' : '加入书架',
      active: c._inShelf,
      onTap: _toggleShelf,
    ),
    AudioAction(
      key: 'audio_download',
      icon: LucideIcons.download,
      label: '下载',
      onTap: _showDownload,
    ),
    AudioAction(
      key: 'audio_chapter_comment',
      icon: LucideIcons.message_circle,
      // The official listening page labels this 章评 (chapter-end discussion).
      // The closest sheet we have today shows the work's book reviews; the
      // reader keeps the real chapter/paragraph ideas.
      label: '章评',
      onTap: _showBookReviews,
    ),
    AudioAction(
      key: 'audio_more',
      icon: LucideIcons.ellipsis,
      label: '更多',
      onTap: _showMore,
    ),
  ];

  /// 目录 / 上一章 / 播放暂停 / 下一章 / 定时.
  Widget _transport() {
    final palette = HomePalette.of(context);
    final playing = c._wantPlay && !c._completed;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _TransportButton(
          icon: LucideIcons.list,
          tooltip: '目录',
          onTap: _showCatalog,
        ),
        _TransportButton(
          icon: LucideIcons.skip_back,
          tooltip: '上一章',
          onTap: c._index > 0 ? () => c._openChapter(c._index - 1) : null,
        ),
        Semantics(
          button: true,
          child: IconButton(
            tooltip: playing ? '暂停' : '播放',
            onPressed: c._ready ? c._togglePlayback : null,
            padding: const EdgeInsets.all(11),
            iconSize: 38,
            style: IconButton.styleFrom(
              foregroundColor: palette.ink,
              disabledForegroundColor: palette.muted.withValues(alpha: 0.5),
            ),
            icon: Icon(playing ? LucideIcons.pause : LucideIcons.play),
          ),
        ),
        _TransportButton(
          icon: LucideIcons.skip_forward,
          tooltip: '下一章',
          onTap: c._index + 1 < c._chapters.length
              ? () => c._openChapter(c._index + 1)
              : null,
        ),
        _TransportButton(
          icon: LucideIcons.alarm_clock,
          tooltip: '定时',
          active: c._sleepRemaining != null,
          onTap: _showSleepTimer,
        ),
      ],
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
    return Text(
      c._completed ? '本章已播完' : (c._wantPlay ? '正在播放' : '已暂停'),
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

  /// Sleep timer: pauses playback when the countdown elapses.
  Future<void> _showSleepTimer() async {
    final palette = HomePalette.of(context);
    // -1 is the explicit 关闭定时 choice; a null result means the sheet was
    // dismissed and must leave any active timer untouched.
    const options = <int>[-1, 15, 30, 60];
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('定时关闭')),
            for (final minutes in options)
              ListTile(
                title: Text(minutes == -1 ? '关闭定时' : '$minutes 分钟后'),
                trailing: (c._sleepMinutes ?? -1) == minutes
                    ? const Icon(LucideIcons.check, color: HomePalette.accent)
                    : null,
                onTap: () => Navigator.pop(context, minutes),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || selected == null) return;
    c._applySleepTimer(selected == -1 ? null : selected);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(selected == -1 ? '已关闭定时' : '将在 $selected 分钟后停止播放'),
        duration: const Duration(seconds: 2),
      ),
    );
    if (!mounted) return;
    // Keep the palette referenced so the sheet inherits the theme colours.
    assert(palette.canvas != palette.surface);
  }

  Future<void> _showMore() async {
    c._publishMoreState();
    final palette = HomePalette.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: palette.canvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      showDragHandle: false,
      builder: (context) {
        final palette = HomePalette.of(context);
        return SafeArea(
          child: Padding(
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
                  color: palette.surface,
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
                                  0xFF3B82F6,
                                ).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                LucideIcons.alarm_clock,
                                size: 20,
                                color: Color(0xFF3B82F6),
                              ),
                            ),
                            title: Text(
                              '定时关闭',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: palette.ink,
                              ),
                            ),
                            subtitle: Text(
                              snapshot.sleepMinutes == null
                                  ? '未开启'
                                  : '剩余 ${snapshot.sleepMinutes} 分钟',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: snapshot.sleepMinutes == null
                                    ? palette.muted
                                    : const Color(0xFF3B82F6),
                              ),
                            ),
                            trailing: Icon(
                              LucideIcons.chevron_right,
                              size: 18,
                              color: palette.muted,
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              unawaited(_showSleepTimer());
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
                              '共 ${c._chapters.length} 章',
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

/// Compact icon + tooltip button used in the transport row.
class _TransportButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  const _TransportButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      style: IconButton.styleFrom(
        foregroundColor: active ? palette.accentText : palette.ink,
        disabledForegroundColor: palette.line,
        minimumSize: const Size(48, 48),
      ),
      icon: Icon(icon, size: 22),
    );
  }
}

class _AudioCatalog extends StatefulWidget {
  final List<Chapter> chapters;
  final int currentIndex;

  const _AudioCatalog({required this.chapters, required this.currentIndex});

  @override
  State<_AudioCatalog> createState() => _AudioCatalogState();
}

class _AudioCatalogState extends State<_AudioCatalog> {
  late final _controller = ScrollController(
    initialScrollOffset: widget.currentIndex * 72.0,
  );
  String _query = '';

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
                '目录 · ${widget.chapters.length} 章',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: '搜索章节名称或序号',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) {
                    setState(() => _query = value.trim().toLowerCase());
                    if (_controller.hasClients) _controller.jumpTo(0);
                  },
                ),
              ),
              Expanded(
                child: indexes.isEmpty
                    ? const Center(child: Text('没有匹配的章节'))
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
