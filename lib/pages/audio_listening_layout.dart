part of '../pages/audio_page.dart';

/// Shared mobile layout for intelligent reading and recorded narration.
extension _AudioListeningLayout on _AudioPageState {
  Widget _listeningScaffold({
    required AudioPageTheme theme,
    required bool pageDark,
    required Chapter chapter,
    required bool realAudio,
    required BookDetail? detail,
    required String introSummary,
    required RelatedWork? related,
  }) {
    return Scaffold(
      key: ValueKey('audio_session_${c._bookId}'),
      backgroundColor: theme.canvas,
      body: SafeArea(
        child: Column(
          children: [
            AudioTopBar(
              onCollapse: () => Navigator.maybePop(context),
              onMore: _showMore,
              center: AudioModeSwitch(
                realSelected: realAudio,
                onSelectTts: !c._switchingVersion && c._ttsTones.isNotEmpty
                    ? () => _onToneSelected(c._ttsTones.first)
                    : null,
                onSelectNarrator:
                    !c._switchingVersion && c._narratorTones.isNotEmpty
                    ? () => _onToneSelected(c._narratorTones.first)
                    : null,
              ),
              theme: theme,
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration:
                    MediaQuery.disableAnimationsOf(context) ||
                        einkModeNotifier.value
                    ? Duration.zero
                    : AudioRealExpandedTranscript.transitionDuration,
                switchInCurve: AudioRealExpandedTranscript.transitionCurve,
                switchOutCurve: AudioRealExpandedTranscript.transitionCurve,
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  alignment: Alignment.topCenter,
                  children: [...previous, ?current],
                ),
                child: KeyedSubtree(
                  key: ValueKey(
                    realAudio && _transcriptExpanded
                        ? 'audio_real_expanded_body'
                        : 'audio_listening_body',
                  ),
                  child: realAudio && _transcriptExpanded
                      ? _expandedListeningBody(
                          theme: theme,
                          pageDark: pageDark,
                          chapter: chapter,
                          detail: detail,
                        )
                      : _collapsedListeningBody(
                          theme: theme,
                          chapter: chapter,
                          realAudio: realAudio,
                          detail: detail,
                          introSummary: introSummary,
                          related: related,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _collapsedListeningBody({
    required AudioPageTheme theme,
    required Chapter chapter,
    required bool realAudio,
    required BookDetail? detail,
    required String introSummary,
    required RelatedWork? related,
  }) => SingleChildScrollView(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AudioRealBookRow(
              cover: c._cover,
              chapterTitle: chapter.title,
              bookTitle: detail?.title.isNotEmpty == true
                  ? detail!.title
                  : c._title,
              onSwap: () => _showIntroSheet(
                theme: theme,
                detail: detail,
                introSummary: introSummary,
                related: related,
              ),
            ),
            _listeningTranscript(realAudio: realAudio),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: AudioIconRow(
                actions: _iconActions(real: true),
                real: true,
              ),
            ),
            const SizedBox(height: 12),
            _listeningSeekRow(),
            const SizedBox(height: 6),
            _listeningTransportRow(),
            _listeningReadAlong(realAudio: realAudio),
            const SizedBox(height: 16),
            AudioVoiceRow(
              modeLabel: realAudio ? '真人讲书' : '智能朗读',
              voiceLabel: c._switchingVersion
                  ? '正在切换…'
                  : realAudio
                  ? _narratorLabel
                  : _currentToneLabel,
              onTap: c._switchingVersion ? null : _showVoices,
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
  );

  Widget _listeningTranscript({required bool realAudio}) {
    final hasStatus =
        c._switchingVersion ||
        c._error != null ||
        c._loading ||
        (c._player?.buffering ?? false) ||
        c._completed;
    // Loading, retries and the countdown share the subtitle slot, so none of
    // them can move the seek bar or playback controls.
    return SizedBox(
      key: const Key('audio_listening_transcript'),
      height: AudioRealSubtitle.heightFor(context),
      child: ValueListenableBuilder<_ReadAlongSnapshot>(
        valueListenable: c._readAlong,
        builder: (context, snapshot, _) {
          final replaceSubtitles =
              c._switchingVersion ||
              c._error != null ||
              c._loading ||
              hasStatus && snapshot.track.isEmpty;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (replaceSubtitles)
                Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 24,
                    ),
                    child: _statusLine(HomePalette.of(context)),
                  ),
                )
              else ...[
                AudioRealSubtitle(
                  track: snapshot.track,
                  position: snapshot.position,
                  duration: snapshot.duration,
                  showExpand:
                      realAudio &&
                      snapshot.track.isNotEmpty &&
                      c._timeTrack.isNotEmpty &&
                      _AudioPageState._expandedTextId(snapshot).isNotEmpty,
                  onExpand: () => _expandTranscript(snapshot),
                ),
                if (hasStatus)
                  Positioned(
                    top: 0,
                    left: 20,
                    right: 20,
                    child: ColoredBox(
                      color: AudioPageThemeScope.of(context).canvas,
                      child: _statusLine(HomePalette.of(context)),
                    ),
                  ),
              ],
              Align(
                alignment: Alignment.bottomCenter,
                child: ValueListenableBuilder<int?>(
                  valueListenable: c.advanceCountdown,
                  builder: (context, seconds, _) => seconds == null
                      ? const SizedBox.shrink()
                      : AudioAdvanceBanner(
                          seconds: seconds,
                          onCancel: () => _cancelAdvanceCountdown(c),
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _listeningReadAlong({required bool realAudio}) =>
      ValueListenableBuilder<_ReadAlongSnapshot>(
        valueListenable: c._readAlong,
        builder: (context, snapshot, _) {
          final novel = c._extras.tones.relatedNovel;
          final available = realAudio
              ? novel != null &&
                    novel.id.isNotEmpty &&
                    snapshot.novelItemId.isNotEmpty
              : snapshot.track.isNotEmpty;
          return AudioRealListenAlong(
            chapterTitle: !available
                ? realAudio
                      ? '暂无原著章节映射'
                      : '本章暂无同步字幕'
                : snapshot.novelChapterTitle.isNotEmpty
                ? snapshot.novelChapterTitle
                : snapshot.chapterTitle,
            onTap: c._switchingVersion || (realAudio && !available)
                ? null
                : realAudio
                ? () => _openReadAlongCard(snapshot)
                : _showReadAlong,
          );
        },
      );

  Widget _listeningSeekRow() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: ValueListenableBuilder<Duration>(
      valueListenable: c._position,
      builder: (context, position, _) => ValueListenableBuilder<double?>(
        valueListenable: c._seekPreview,
        builder: (context, seekPreview, _) => AudioTimeSeekRow(
          position: position,
          duration: c._duration,
          preview: seekPreview,
          enabled: c._ready,
          onChanged: c._previewSeek,
          onChangeEnd: (value) =>
              c._seekTo(Duration(milliseconds: value.round())),
          onBack15: c._ready
              ? () => c._seekTo(c._position.value - const Duration(seconds: 15))
              : null,
          onForward15: c._ready
              ? () => c._seekTo(c._position.value + const Duration(seconds: 15))
              : null,
          real: true,
        ),
      ),
    ),
  );

  Widget _listeningTransportRow({bool bare = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: AudioTransportRow(
      onCatalog: _showCatalog,
      onPrevious: c._index > 0 ? () => c._openChapter(c._index - 1) : null,
      onNext: c._index + 1 < c._chapters.length
          ? () => c._openChapter(c._index + 1)
          : null,
      onPlayPause: c._ready ? c._togglePlayback : null,
      onSleepTimer: _showSleepTimer,
      playing: c._wantPlay && !c._completed,
      loading: c._loading || (c._player?.buffering ?? false),
      ready: c._ready,
      sleepLabel: c.sleepAtChapterEnd
          ? '剩余本章'
          : (c._sleepRemaining == null ? null : '剩余播放'),
      real: true,
      bare: bare,
    ),
  );

  /// 展开态：书籍行（无 ⇋）+ 页内全文 + 收起胶囊 + 进度行 + 控制行（bare）。
  ///
  /// 字幕区、操作行、边听边读与换版本行都收起来；进度和控制的版式与颜色
  /// 沿用默认态，只把控制行的「目录」「定时」文字藏掉（样稿 `.trans.bare`）。
  Widget _expandedListeningBody({
    required AudioPageTheme theme,
    required bool pageDark,
    required Chapter chapter,
    required BookDetail? detail,
  }) {
    final fontSize = _readerPreferencesLoaded
        ? _readerPreferences.fontSize
        : AudioRealExpandedTranscript.fallbackFontSize;
    final lineHeight = _readerPreferencesLoaded
        ? _readerPreferences.lineHeight
        : AudioRealExpandedTranscript.fallbackLineHeight;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AudioRealBookRow(
              cover: c._cover,
              chapterTitle: chapter.title,
              bookTitle: detail?.title.isNotEmpty == true
                  ? detail!.title
                  : c._title,
            ),
            Expanded(
              child: ValueListenableBuilder<_ReadAlongSnapshot>(
                valueListenable: c._readAlong,
                builder: (context, snapshot, _) {
                  final itemId = _AudioPageState._expandedTextId(snapshot);
                  final content = _expandedTexts[itemId];
                  if (content == null) {
                    final failed = _expandedTextFailed.contains(itemId);
                    return Center(
                      child: Text(
                        failed ? '正文加载失败' : '正在加载正文…',
                        key: Key(
                          failed
                              ? 'audio_real_expanded_error'
                              : 'audio_real_expanded_loading',
                        ),
                        style: TextStyle(color: theme.muted, fontSize: 14),
                      ),
                    );
                  }
                  return ValueListenableBuilder<Duration>(
                    valueListenable: c._position,
                    builder: (context, position, _) =>
                        ValueListenableBuilder<double?>(
                          valueListenable: c._seekPreview,
                          builder: (context, preview, _) =>
                              AudioRealExpandedTranscript(
                                key: ValueKey('audio_real_expanded_$itemId'),
                                content: content,
                                // 正文开头的章名段与书籍行重复：时间点没带
                                // 标题时退回当前集标题，对不上就原样保留。
                                chapterTitle:
                                    snapshot.novelChapterTitle.isNotEmpty
                                    ? snapshot.novelChapterTitle
                                    : chapter.title,
                                timeTrack: c._timeTrack,
                                position: preview == null
                                    ? position
                                    : Duration(milliseconds: preview.round()),
                                fontSize: fontSize,
                                lineHeight: lineHeight,
                                dark: pageDark,
                              ),
                        ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 6),
              child: Center(child: AudioRealFoldButton(onTap: _foldTranscript)),
            ),
            const SizedBox(height: 12),
            _listeningSeekRow(),
            _listeningTransportRow(bare: true),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// Book details remain available from the compact book row.
  Widget _introCard({
    required BookDetail? detail,
    required String introSummary,
    required RelatedWork? related,
  }) {
    return AudioIntroCard(
      cover: c._cover,
      title: detail?.title.isNotEmpty == true ? detail!.title : c._title,
      author: detail?.author.name ?? '',
      meta: detail?.metaParts ?? const [],
      summary: introSummary,
      related: related,
      onOpenRelated: _openRelated,
    );
  }

  /// 书籍行右侧 ⇋：打开简介卡。
  ///
  /// Both listening modes use the same details sheet.
  Future<void> _showIntroSheet({
    required AudioPageTheme theme,
    required BookDetail? detail,
    required String introSummary,
    required RelatedWork? related,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: theme.card,
      builder: (context) => AudioPageThemeScope(
        theme: theme,
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.6,
            child: _introCard(
              detail: detail,
              introSummary: introSummary,
              related: related,
            ),
          ),
        ),
      ),
    );
  }

  /// 官方 `bif.xml` 图标行。首项文案是**当前倍速**（截图 2.jpg 的 `1.2x`）。
  ///
  /// Mobile uses the compact icons; desktop keeps its existing appearance.
  List<AudioIconAction> _iconActions({bool real = false}) => [
    AudioIconAction(
      key: 'audio-speed',
      icon: real ? LucideIcons.gauge : LucideIcons.timer,
      label: '${_AudioPageState._rateLabel(c._rate)}x',
      semanticLabel: AudioPreferences.instance.rateLocked
          ? '播放速度 ${_AudioPageState._rateLabel(c._rate)} 倍，已锁定'
          : '播放速度 ${_AudioPageState._rateLabel(c._rate)} 倍',
      // 锁定后点击不再弹面板，只提示；长按才是锁定/解锁开关（官方 `a4g`）。
      onTap: c._ready
          ? (AudioPreferences.instance.rateLocked
                ? _showRateLockedHint
                : _showRates)
          : null,
      onLongPress: c._ready ? _toggleRateLock : null,
      badgeIcon: AudioPreferences.instance.rateLocked ? LucideIcons.lock : null,
    ),
    AudioIconAction(
      key: 'audio_shelf',
      icon: real ? LucideIcons.book_plus : LucideIcons.book_open_check,
      label: c._inShelf ? '已在书架' : '加入书架',
      active: c._inShelf,
      onTap: _toggleShelf,
    ),
    AudioIconAction(
      key: 'audio_download',
      icon: real ? LucideIcons.download : LucideIcons.list_end,
      label: '下载',
      onTap: _showDownload,
    ),
    AudioIconAction(
      key: 'audio_chapter_comment',
      icon: LucideIcons.message_circle,
      label: '章评',
      onTap: _showBookReviews,
    ),
    AudioIconAction(
      key: 'audio_more',
      icon: real ? LucideIcons.circle_ellipsis : LucideIcons.ellipsis,
      label: '更多',
      onTap: _showMore,
    ),
  ];

  /// 面板「音色」行显示的当前音色名。
  String get _currentToneLabel {
    final id = c._toneId;
    for (final tone in [...c._ttsTones, ...c._narratorTones]) {
      if (tone.id == id && tone.title.isNotEmpty) return tone.title;
    }
    final localVoice = c._restoredLocalVoice;
    if (localVoice != null && localVoice.id == id) return localVoice.label;
    return '默认音色';
  }

  void _showRateLockedHint() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('倍速已锁定，长按可解锁'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// 长按倍速项：锁定当前倍速 / 解锁并恢复 1x（官方 `a4g` / `a4k`）。
  Future<void> _toggleRateLock() async {
    final prefs = AudioPreferences.instance;
    if (prefs.rateLocked) {
      await prefs.setRateLocked(false);
      await c._setRate(1);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已经恢复 1x 倍速'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    await prefs.setRateLocked(true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已经锁定 ${_AudioPageState._rateLabel(c._rate)}x 倍速'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
