part of '../pages/audio_page.dart';

/// 手机版听书页的版式部分。
///
/// 官方布局链：`alo.xml` → `bhz.xml`（详情头）→ `bio.xml`（封面页头）→
/// `bif.xml`（图标行）→ `bjg.xml`（进度）→ `bin.xml`（播放控制）→
/// `bj1.xml`（音色区）。三个成员原来都写在 `audio_page.dart` 里，把那个
/// 文件推过了行数预算，按职责挪到这里。
extension _AudioListeningLayout on _AudioPageState {
  /// 手机版听书页：官方 `alo.xml` → `bhz` → `bio`（页头）→ `bif`（图标行）
  /// → `bjg`（进度）→ `bin`（播放控制）→ `bj1`（音色）。
  Widget _listeningScaffold({
    required AudioPageTheme theme,
    required bool pageDark,
    required Chapter chapter,
    required bool realAudio,
    required List<AudioTone> tones,
    required BookDetail? detail,
    required String introSummary,
    required RelatedWork? related,
    required bool hasIntro,
  }) {
    // 官方把「智能朗读 │ 真人讲书」放在页头中央（layout/hy.xml，`a4y` 就在
    // jz4 header 之下），不是标题位置，也不是栏下独立一行。
    final modeSwitch =
        c._extras.tones.narratorTones.isNotEmpty &&
            c._extras.tones.ttsTones.isNotEmpty
        ? true
        : false;
    // _statusLine 同时被桌面版式（HomePalette）复用，所以这里不改它的签名；
    // 它只承担一行状态说明，强调色用品牌橙在暖底上也不违和。
    final paletteForStatus = HomePalette.of(context);
    return Scaffold(
      key: ValueKey('audio_session_${c._bookId}'),
      backgroundColor: theme.canvas,
      body: SafeArea(
        child: Column(
          children: [
            AudioTopBar(
              onCollapse: () => Navigator.maybePop(context),
              onMore: _showMore,
              center: modeSwitch
                  ? AudioModeSwitch(
                      realSelected: realAudio,
                      onSelectTts: () =>
                          _onToneSelected(c._extras.tones.ttsTones.first),
                      onSelectNarrator: () =>
                          _onToneSelected(c._extras.tones.narratorTones.first),
                    )
                  : null,
              theme: theme,
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _coverCard(
                          chapter: chapter,
                          detail: detail,
                          introSummary: introSummary,
                          related: related,
                        ),
                        // 官方 `fs5`/`fs6`：封面正下方是一条多行滚动字幕
                        // （`AudioPlaySubtitleView`，高度按字号取档再减 2dp，
                        // 默认 50dp、左右 20dp、底部 24dp）。
                        // 按显示行分配时间，上下各 3dp；槽位常驻，
                        // 没有字幕时显示状态文案，只有 NOT_SUPPORT 才收起。
                        //
                        // 两种模式共用同一个槽：有字幕轨就显示正在朗读的那句
                        // 及其上下文，没有轨则显示状态文案。
                        ValueListenableBuilder<_ReadAlongSnapshot>(
                          valueListenable: c._readAlong,
                          builder: (context, snapshot, _) =>
                              AudioInlineSubtitle(
                                track: snapshot.track,
                                position: snapshot.position,
                                duration: snapshot.duration,
                                onTap: _showReadAlong,
                              ),
                        ),
                        if (c._error != null ||
                            c._loading ||
                            (c._player?.buffering ?? false) ||
                            c._completed) ...[
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: _statusLine(paletteForStatus),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: AudioIconRow(actions: _iconActions),
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
                                      AudioTimeSeekRow(
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
                        // 官方 `te`「%s后播放下一集」：章末给一段可取消的窗口。
                        ValueListenableBuilder<int?>(
                          valueListenable: c.advanceCountdown,
                          builder: (context, seconds, _) => seconds == null
                              ? const SizedBox.shrink()
                              : AudioAdvanceBanner(
                                  seconds: seconds,
                                  onCancel: () => _cancelAdvanceCountdown(c),
                                ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: AudioTransportRow(
                            onCatalog: _showCatalog,
                            onPrevious: c._index > 0
                                ? () => c._openChapter(c._index - 1)
                                : null,
                            onNext: c._index + 1 < c._chapters.length
                                ? () => c._openChapter(c._index + 1)
                                : null,
                            onPlayPause: c._ready ? c._togglePlayback : null,
                            onSleepTimer: _showSleepTimer,
                            playing: c._wantPlay && !c._completed,
                            loading:
                                c._loading || (c._player?.buffering ?? false),
                            ready: c._ready,
                            // 官方 doc「剩余本章」/ dod「剩余播放」：定时开着时
                            // 这个位置换成状态文字，没开就是「定时」。
                            sleepLabel: c.sleepAtChapterEnd
                                ? '剩余本章'
                                : (c._sleepRemaining == null ? null : '剩余播放'),
                          ),
                        ),
                        const SizedBox(height: 16),
                        // 官方在真人讲书页把音色卡默认收起（bj1.xml a5h 为
                        // gone），主播版本改由一行入口 + 声音设置面板承担。
                        if (realAudio)
                          AudioRealVersionRow(
                            narrator: _narratorLabel,
                            onTap: c._switchingVersion ? null : _showVoices,
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: AudioToneSection(
                              title: '智能朗读',
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

  /// 官方封面卡：`bio.xml`。
  ///
  /// 尺寸由 [audioCoverEdge] 按 `d2.smali` 的公式算（0.72 × 屏宽，大屏再夹
  /// 一次高 40%），是一个**正方形**；页脚只有两行（集标题 + 副行），书名
  /// `b1g` 在官方是 `visibility="gone"`。
  ///
  /// 点击副行翻到简介面（`bhi.xml`），再点背面的收起按钮翻回来。
  Widget _coverCard({
    required Chapter chapter,
    required BookDetail? detail,
    required String introSummary,
    required RelatedWork? related,
  }) {
    final edge = audioCoverEdge(context);
    final intro = AudioIntroCard(
      cover: c._cover,
      title: detail?.title.isNotEmpty == true ? detail!.title : c._title,
      author: detail?.author.name ?? '',
      meta: detail?.metaParts ?? const [],
      summary: introSummary,
      related: related,
      onOpenRelated: _openRelated,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
      child: Center(
        child: SizedBox(
          width: edge,
          height: edge,
          child: AudioFlipCover(
            cover: c._cover,
            chapterTitle: chapter.title,
            subtitle: c._excerpt,
            back: intro,
            onSwitch: _showVoices,
            onOpenBook: _showCatalog,
          ),
        ),
      ),
    );
  }

  /// 官方 `bif.xml` 图标行。首项文案是**当前倍速**（截图 2.jpg 的 `1.2x`）。
  List<AudioIconAction> get _iconActions => [
    AudioIconAction(
      key: 'audio-speed',
      icon: LucideIcons.timer,
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
      icon: LucideIcons.book_open_check,
      label: c._inShelf ? '已在书架' : '加入书架',
      active: c._inShelf,
      onTap: _toggleShelf,
    ),
    AudioIconAction(
      key: 'audio_download',
      icon: LucideIcons.list_end,
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
      icon: LucideIcons.ellipsis,
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
