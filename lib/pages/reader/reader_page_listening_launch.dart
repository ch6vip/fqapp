part of '../reader_page.dart';

/// Opening the listening player and mapping the page to a playback position.
extension _ReaderPageListeningLaunch on _ReaderPageState {
  /// Local books use system TTS; the settings/selection paths offer both sources.
  ///
  /// [fromPage] skips the source sheet and starts from this page directly —
  /// shared by the round entry and the sync pill's 「从本页听」.
  Future<void> _openListening({
    int? fromMs,
    int? textId,
    bool fromPage = false,
  }) async {
    if (_openingListening || _loading || _error != null) return;
    if (fromPage) {
      final anchor = _currentPageAnchor();
      fromMs ??= anchor.startMs;
      textId ??= anchor.textId;
    }
    final chapterId = _chapter.itemId;
    var system = widget.localOnly;
    if (!system) {
      if (fromPage) {
        await _openUpstreamListening(
          fromMs: fromMs,
          textId: textId,
          openPage: false,
        );
        return;
      }
      final int? choice;
      _setState(() => _openingListening = true);
      try {
        // 0 = 从头/续播，1 = 从本页播放，2 = 系统朗读。
        choice = await _showListeningSourceSheet();
      } finally {
        if (mounted) _setState(() => _openingListening = false);
      }
      if (!mounted || choice == null || chapterId != _chapter.itemId) return;
      // The launch helper owns the same lock; release the source sheet first.
      if (choice == 1) {
        final anchor = _currentPageAnchor();
        await _openUpstreamListening(
          fromMs: anchor.startMs ?? fromMs,
          textId: anchor.textId ?? textId,
          openPage: false,
          keepControls: true,
        );
        return;
      }
      system = choice == 2;
    }
    if (!system) {
      await _openUpstreamListening(fromMs: fromMs, textId: textId);
      return;
    }
    _setState(() => _openingListening = true);
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
      // Preserve the menu state so its borrowed capsule remains accessible
      // when system TTS starts; do not reopen a menu the user has dismissed.
      await AudioPlaybackScope.startSystemTts(context, book);
    } catch (e) {
      if (mounted) _showMessage(SystemTts.errorMessage(e));
    } finally {
      if (mounted) _setState(() => _openingListening = false);
    }
  }

  /// 听书方式选择：0 = 从头/续播，1 = 从本页播放，2 = 系统朗读。
  ///
  /// 面板骨架走 ReaderSettingsSheetFrame；路由透明，底色 / 圆角由 frame
  /// 按阅读 preset 画出。
  Future<int?> _showListeningSourceSheet() {
    final preset = _effectivePreset;
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      // 与 ReaderSettingsSheetFrame 的顶部圆角一致，只用于裁掉越界内容。
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _ListeningSourceSheet(preset: preset),
    );
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
  Future<void> _openUpstreamListening({
    int? fromMs,
    int? textId,
    bool openPage = true,
    bool keepControls = false,
  }) async {
    final paragraphAnchored = textId != null;
    if (_openingListening) return;
    if (_readerAudioUnavailable) {
      _showMessage('本书暂无可用听书资源，可在设置 → 更多设置 → 听书方式中选择系统朗读');
      return;
    }
    _setState(() => _openingListening = true);
    _showMessage('正在开始播放…');
    final chapter = _chapter;
    final chapterIndex = _index;
    try {
      _stopAutoTurn();
      await _persistProgress();
      if (!mounted || _chapter.itemId != chapter.itemId) return;
      var startMs = fromMs;
      // The paragraph keys for the player's /timepoints lookup, used when the
      // chapter body carries no `<span start_time>` (plain-text 智能朗读
      // chapters): the reader cannot compute milliseconds, so it hands the
      // player the paragraph instead of giving up to the chapter opening.
      ({int? paraIndex, int ordinal})? paragraph;
      if (startMs == null && paragraphAnchored) {
        if (!_chapterContent.timelineChecked) {
          _showMessage('正在获取本段音频…');
          await _refreshCachedChapter(
            chapter,
          ).timeout(const Duration(seconds: 12), onTimeout: () {});
          // The user may have turned the page while the timeline was in flight.
          // Serving another chapter's paragraph position would start playback at
          // a place nobody asked for.
          if (!mounted || _chapter.itemId != chapter.itemId) return;
        }
        final anchor = _paragraphAnchor(textId);
        startMs = anchor.startMs;
        if (startMs == null) {
          paragraph = (paraIndex: anchor.paraIndex, ordinal: anchor.ordinal);
        }
      }
      if (!mounted) return;
      // 真人讲书「边听边读」：阅读页按原著 id 打开，会话按音频专辑 id 记账、
      // 别名到原著。此时绝不能拿原著 id 去 acquire —— 播放器会关掉正在播的
      // 音频会话，再按原著 id 新建一个不存在的会话。改成让现有会话跳到本页
      // 锚点（章节由播放器映射回音频集），映射不到就保持原播放并提示。
      final listening = ListeningSession.instance;
      final aliased =
          listening.bookId != null &&
          listening.bookId != widget.bookId &&
          listening.matchesBook(widget.bookId);
      var reuseLive = false;
      if (aliased) {
        var jumped = true;
        if (startMs != null) {
          jumped = AudioPlaybackScope.jumpToChapter(
            context,
            chapter.itemId,
            Duration(milliseconds: startMs),
          );
        } else if (paragraph != null) {
          jumped = AudioPlaybackScope.jumpToParagraph(
            context,
            chapter.itemId,
            paraIndex: paragraph.paraIndex,
            ordinal: paragraph.ordinal,
          );
        }
        if (!mounted) return;
        if (!jumped) {
          _showMessage('当前音频没有这一章，继续播放原进度');
        }
        if (!openPage) {
          return;
        }
        // 打开听书页只是给现有会话挂一个视图。
        reuseLive = true;
      }
      if (!keepControls) _setControlsVisible(false);
      final request = AudioPage(
        // 复用别名会话时用音频书 id：页面只是会话的视图，按会话自己的 id
        // 记账，评论/封面等读取才落对书。
        bookId: reuseLive ? listening.bookId! : widget.bookId,
        title: widget.title,
        cover: widget.cover,
        chapters: widget.chapters,
        startIndex: chapterIndex,
        resumeSession: reuseLive,
        // 沿用正在听的那个音色：不传的话播放页只能挑默认音色，
        // 「从本页播放」就会把真人讲书换成内置 TTS。
        initialToneId: _listeningToneId(),
        // A paragraph-anchored request always carries an explicit start:
        // Duration.zero means "this paragraph has no audio, begin at the
        // chapter opening" and must not fall back to saved history.
        // startParagraph hands the paragraph to the player when the body
        // has no spans of its own; the player resolves it from
        // /timepoints and only falls back to that Duration.zero.
        startPosition: reuseLive
            ? null
            : paragraphAnchored
            ? Duration(milliseconds: startMs ?? 0)
            : null,
        startParagraph: reuseLive ? null : paragraph,
        // 没有精确毫秒、也没有 `/timepoints` 可查时的兜底：告诉播放页这
        // 一段在正文里的位置比例，让它按时长折算。折算不精确，但它保证
        // 锚定请求不会落到章首——那正是用户看到「还是从章首播」的样子。
        startFraction: !reuseLive && paragraphAnchored && startMs == null
            ? _readFraction(textId)
            : null,
        historyStore: widget.readerStore,
      );
      if (openPage) {
        // 「听书」：跳转听书详情页。会话由 scope 持有，页面只是视图。
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => request));
        return;
      }
      // 「从本页播放」：后台起播，阅读页留在原处跟随。
      final accepted = await AudioPlaybackScope.startListeningInBackground(
        context,
        request,
      );
      if (!accepted && mounted) {
        _showMessage('无法开始播放，请检查网络');
      } else if (accepted && mounted) {
        _showMessage('已提交播放请求，可从底部胶囊查看状态');
      }
    } catch (_) {
      if (mounted) _showMessage('无法开始播放，请检查网络后重试');
    } finally {
      if (mounted) _setState(() => _openingListening = false);
    }
  }

  /// 本会话正在用的音色；不在听这本书时为 null（交给播放页按历史/默认决定）。
  String? _listeningToneId() {
    final session = ListeningSession.instance;
    // 别名书（真人讲书的原著）也要沿用会话里的真实音色。
    if (!session.matchesBook(widget.bookId)) return null;
    final tone = session.toneId;
    return (tone == null || tone.isEmpty) ? null : tone;
  }

  /// 「从本页播放」的锚点：当前页第一个**从本页开始**的正文段落的段落 ID 与
  /// 它的起播时间。
  ///
  /// 页首常常是上一页跨过来的段落尾巴（`fragment.firstLine > 0`）：拿它当锚点，
  /// 播放会退到上一页那段正文的开头，用户听到的就不是眼前这段了。优先取
  /// `firstLine == 0` 的段落；整页都是同一段的续行（超长段落跨多页）时才退回
  /// 页首那段。
  ///
  /// 时间取 [ReaderContentBlock.startMs]（章节自带的 `<span start_time>`），
  /// 与「从本段听」同源。没有时间轴的章返回 startMs 为 null，调用方退回续播。
  ({int? startMs, int? textId}) _currentPageAnchor() {
    final layout = _chapterLayout;
    if (layout == null || layout.pages.isEmpty) {
      return (startMs: null, textId: null);
    }
    final page = layout.pages[_pageIndex.clamp(0, layout.pages.length - 1)];
    ({int? startMs, int? textId})? carried;
    for (final fragment in page.fragments) {
      final block = fragment.block;
      if (block.isTitle || block.isImage || block.text.isEmpty) continue;
      final anchor = (startMs: block.startMs, textId: block.textId);
      if (fragment.firstLine == 0) return anchor;
      carried ??= anchor;
    }
    return carried ?? (startMs: null, textId: null);
  }

  /// The spoken start of the paragraph identified by [textId], plus the keys
  /// the player needs to resolve it from `/timepoints` when the chapter body
  /// carries no `<span start_time>` of its own.
  ///
  /// [textId] is [ReaderContentBlock.textId]: the upstream `idx` when present,
  /// otherwise the paragraph's ordinal. The ordinal fallback is resolved
  /// against the exact block order the reader laid out — the leading title
  /// stripped, the synthetic title block occupying index 0, image blocks
  /// counted — so a chapter without ids still maps. Walking the raw block
  /// list instead desynced from the layout by one (title) plus however many
  /// images precede a paragraph, and 从本段听 landed on the previous paragraph.
  ///
  /// [startMs] comes from the chapter's own timeline (`<span start_time>`).
  /// [paraIndex] (the upstream `<p idx>` id) and [ordinal] (position among the
  /// body paragraphs, title stripped, zero-based) feed the player's
  /// `/timepoints` lookup — plain-text chapters carry no `idx` at all, and the
  /// ordinal covers the two title-numbering conventions in one try each.
  ({int? startMs, int? paraIndex, int ordinal}) _paragraphAnchor(int textId) {
    final body = _chapterContent.withoutLeadingTitle(_chapter.title);
    // Block 0 is the layout's synthetic title, so the first body element sits
    // at layout index 1 and its fallback id is -(1 + 0) — the same maths
    // ReaderChapterLayout uses for textId.
    var layoutIndex = 1;
    var ordinal = 0;
    for (final element in body.blocks) {
      if (element is ChapterParagraph) {
        if (paragraphUnderlineId(
              paraIndex: element.paraIndex,
              blockIndex: layoutIndex - 1,
            ) ==
            textId) {
          return (
            startMs: element.startMs,
            paraIndex: element.paraIndex,
            ordinal: ordinal,
          );
        }
        ordinal++;
      }
      layoutIndex++;
    }
    return (startMs: null, paraIndex: null, ordinal: -1);
  }

  /// 本章正文里 [textId] 那一段的读进度（0..1）。
  ///
  /// 播放页拿它当起播位置的最后一道估计：`/timepoints` 查不到时按字符位置
  /// 折算毫秒。坐标取排版后的显示文本（与 [ReaderChapterLayout] 的
  /// `block.start` 同一套），全章字数按最后一块的末尾算——标题也算在内，
  /// 因为音频是从标题开始念的。
  double? _readFraction(int? textId) {
    final layout = _chapterLayout;
    // 标题块的 textId 也是 null：没有锚点段落时不能拿它当「第一段」。
    if (textId == null || layout == null || layout.blocks.isEmpty) return null;
    int? offset;
    for (final block in layout.blocks) {
      if (block.textId == textId) {
        offset = block.start;
        break;
      }
    }
    final last = layout.blocks.last;
    final total = last.start + last.text.length;
    if (offset == null || total <= 0) return null;
    final fraction = offset / total;
    return fraction <= 0 ? 0.0 : (fraction >= 1 ? 1.0 : fraction);
  }
}

/// 听书方式选择面板：ReaderSettingsSheetFrame + Lucide，配色跟随阅读 preset。
class _ListeningSourceSheet extends StatelessWidget {
  const _ListeningSourceSheet({required this.preset});

  final ReaderThemePreset preset;

  @override
  Widget build(BuildContext context) => ReaderSettingsSheetFrame(
    preset: preset,
    title: '听书方式',
    closeTooltip: '关闭',
    scrollKey: const ValueKey('reader-listening-source-scroll'),
    children: [
      _row(
        context,
        icon: LucideIcons.headphones,
        title: '听书',
        subtitle: '使用作品自带音频与音色',
        value: 0,
      ),
      _row(
        context,
        icon: LucideIcons.locate_fixed,
        title: '从本页播放',
        subtitle: '从当前页第一段开始听',
        value: 1,
      ),
      _row(
        context,
        icon: LucideIcons.mic,
        title: '系统朗读',
        subtitle: '使用手机已安装的 TTS 引擎',
        value: 2,
      ),
    ],
  );

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required int value,
  }) => ListTile(
    leading: Icon(icon, color: preset.mutedTextColor),
    title: Text(title, style: TextStyle(color: preset.textColor)),
    subtitle: Text(subtitle, style: TextStyle(color: preset.mutedTextColor)),
    onTap: () => Navigator.pop(context, value),
  );
}
