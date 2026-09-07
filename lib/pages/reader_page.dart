import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/chapter_cache_store.dart';
import '../services/chapter_text_formatter.dart';
import '../services/library_store.dart';
import '../services/reader_preferences.dart';
import '../widgets/chapter_cache_sheet.dart';

typedef ChapterTextLoader = Future<String> Function(Chapter chapter);

class ReaderPage extends StatefulWidget {
  final String bookId;
  final String title;
  final String cover;
  final List<Chapter> chapters;
  final int startIndex;
  final ChapterTextLoader? chapterLoader;
  final ReaderStore? readerStore;
  final ChapterCache? chapterCache;

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
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  late int _index;
  final ScrollController _scrollController = ScrollController();
  Timer? _saveTimer;
  String _content = '';
  List<String> _paragraphs = const [];
  bool _loading = true;
  String? _error;
  ReaderPreferences _preferences = const ReaderPreferences();
  ReaderThemePreset _dayTheme = ReaderThemePreset.light;
  bool _controlsVisible = true;
  double? _chapterSeekValue;
  int _loadGeneration = 0;
  // Legado-style reading time: deltas are settled at scroll stops, chapter
  // switches and dispose, so no background timer is needed.
  DateTime _readStart = DateTime.now();
  bool _sessionActive = false;
  bool _appActive = true;
  bool _changingChapter = false;
  final LinkedHashMap<String, String> _chapterCache = LinkedHashMap();
  final Map<String, Future<String>> _chapterRequests = {};
  Future<void>? _catalogFuture;

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
    WidgetsBinding.instance.addObserver(this);
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _index = widget.chapters.isEmpty
        ? 0
        : widget.startIndex.clamp(0, widget.chapters.length - 1);
    _scrollController.addListener(_onScroll);
    _loadPreferences();
    if (widget.chapters.isEmpty) {
      _loading = false;
      _error = '暂无可阅读章节';
    } else {
      unawaited(_ensureCatalog().catchError((_) {}));
      _load();
    }
  }

  Future<void> _loadPreferences() async {
    final preferences = await ReaderPreferences.load();
    if (!mounted) return;
    setState(() {
      _preferences = preferences;
      if (preferences.themePreset != ReaderThemePreset.dark) {
        _dayTheme = preferences.themePreset;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      _settleReadTime();
      _sessionActive = false;
      _appActive = false;
      unawaited(_persistProgress());
    } else if (resumed && !_appActive) {
      _appActive = true;
      if (!_loading && _content.isNotEmpty) {
        _readStart = DateTime.now();
        _sessionActive = true;
      }
    }
  }

  Future<void> _load({bool startAtEnd = false}) async {
    if (widget.chapters.isEmpty) return;
    final generation = ++_loadGeneration;
    final chapter = _chapter;
    setState(() {
      _loading = true;
      _error = null;
      _content = '';
      _paragraphs = const [];
      _sessionActive = false;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);

    try {
      final text = await _chapterText(chapter);
      final paragraphs = splitChapterParagraphs(
        text,
        chapterTitle: chapter.title,
      );
      if (paragraphs.isEmpty) throw ApiException('正文为空');
      if (!mounted || generation != _loadGeneration) return;
      final saved = await _readerStore.historyEntry(widget.bookId);
      if (!mounted || generation != _loadGeneration) return;
      final sameChapter = saved?['chapterId']?.toString() == chapter.itemId;
      final savedPosition = sameChapter && saved?['position'] is num
          ? (saved!['position'] as num).toDouble()
          : 0.0;
      setState(() {
        _content = text;
        _paragraphs = paragraphs;
        _loading = false;
      });
      if (_appActive) {
        _sessionActive = true;
        _readStart = DateTime.now();
      }

      await _readerStore.addHistory({
        'id': widget.bookId,
        'kind': 'book',
        'title': widget.title,
        'bookId': widget.bookId,
        'chapterId': chapter.itemId,
        'episode': _index,
        'position': savedPosition,
        'maxScroll': sameChapter && saved?['maxScroll'] is num
            ? (saved!['maxScroll'] as num).toDouble()
            : 0.0,
        'progress': _chapterProgress(),
        'cover': widget.cover,
        'time': DateTime.now().millisecondsSinceEpoch,
      });
      if (startAtEnd) {
        _scrollToChapterEnd(generation);
      } else {
        await _restorePosition(chapter.itemId, saved);
      }
      unawaited(_prefetchAround(_index));
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<String> _chapterText(Chapter chapter) async {
    final id = chapter.itemId;
    final cached = _chapterCache.remove(id);
    if (cached != null) {
      _chapterCache[id] = cached;
      return cached;
    }
    final pending = _chapterRequests[id];
    if (pending != null) return pending;

    final request = _loadChapterText(chapter);
    _chapterRequests[id] = request;
    try {
      final text = await request;
      _chapterCache[id] = text;
      while (_chapterCache.length > 5) {
        _chapterCache.remove(_chapterCache.keys.first);
      }
      return text;
    } finally {
      if (identical(_chapterRequests[id], request)) {
        _chapterRequests.remove(id);
      }
    }
  }

  Future<String> _fetchChapter(Chapter chapter) =>
      widget.chapterLoader?.call(chapter) ??
      ApiClient.instance.contentText(chapter.itemId, tab: '小说');

  Future<void> _ensureCatalog() => _catalogFuture ??= _diskCache
      .saveBook(_cachedBook)
      .catchError((Object error) {
        _catalogFuture = null;
        throw error;
      });

  Future<String> _loadChapterText(Chapter chapter) async {
    try {
      final cached = await _diskCache.read(
        bookId: widget.bookId,
        chapterId: chapter.itemId,
      );
      if (cached != null && cached.trim().isNotEmpty) return cached;
    } catch (_) {
      // A storage failure must not prevent online reading.
    }
    final text = await _fetchChapter(chapter);
    if (text.trim().isEmpty) throw ApiException('正文为空');
    try {
      await _ensureCatalog();
      await _diskCache.write(
        bookId: widget.bookId,
        chapterId: chapter.itemId,
        title: chapter.title,
        text: text,
      );
    } catch (_) {
      // Cache management reports storage errors; keep the fetched text usable.
    }
    return text;
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

  Future<void> _restorePosition(
    String chapterId,
    Map<String, dynamic>? saved,
  ) async {
    if (!mounted ||
        saved == null ||
        saved['chapterId']?.toString() != chapterId) {
      return;
    }
    final rawPosition = saved['position'];
    final position = rawPosition is num ? rawPosition.toDouble() : 0.0;
    if (position <= 0) return;
    final rawMaxScroll = saved['maxScroll'];
    final savedMaxScroll = rawMaxScroll is num ? rawMaxScroll.toDouble() : 0.0;
    final savedFraction = savedMaxScroll > 0
        ? (position / savedMaxScroll).clamp(0.0, 1.0)
        : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scrollController.hasClients ||
          _chapter.itemId != chapterId) {
        return;
      }
      final currentMaxScroll = _scrollController.position.maxScrollExtent;
      final restoredPosition = savedFraction == null
          ? position
          : currentMaxScroll * savedFraction;
      final target = restoredPosition.clamp(0.0, currentMaxScroll);
      _scrollController.jumpTo(target);
    });
  }

  void _scrollToChapterEnd(int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _loadGeneration ||
          !_scrollController.hasClients) {
        return;
      }
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      unawaited(_persistProgress());
    });
  }

  void _onScroll() {
    _saveTimer?.cancel();
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
      unawaited(_readerStore.accumulateReadTime(widget.bookId, 'book', delta));
    }
    _readStart = now;
  }

  Future<void> _persistProgress() async {
    if (widget.chapters.isEmpty) return;
    final index = _index;
    final chapterId = _chapter.itemId;
    final position = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final max = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    await _readerStore.updateProgress(
      widget.bookId,
      index,
      _chapterProgress(position: position, maxScroll: max, index: index),
      chapterId: chapterId,
      position: position,
      maxScroll: max,
    );
  }

  double _chapterProgress({double? position, double? maxScroll, int? index}) {
    if (widget.chapters.isEmpty) return 0;
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已是最后一章')));
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
    if (_loading || _changingChapter || !_scrollController.hasClients) return;
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
    setState(() => _controlsVisible = !_controlsVisible);
  }

  void _previewPreferences(ReaderPreferences preferences) {
    setState(() {
      _preferences = preferences.normalized();
      if (_preferences.themePreset != ReaderThemePreset.dark) {
        _dayTheme = _preferences.themePreset;
      }
    });
  }

  Future<void> _showAppearanceSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: _preferences.themePreset.sheetColor,
      builder: (context) => _ReaderAppearanceSheet(
        initialValue: _preferences,
        onChanged: _previewPreferences,
      ),
    );
    await _preferences.save();
  }

  void _toggleNightTheme() {
    final nextPreset = _preferences.themePreset == ReaderThemePreset.dark
        ? _dayTheme
        : ReaderThemePreset.dark;
    _previewPreferences(_preferences.copyWith(themePreset: nextPreset));
    unawaited(_preferences.save());
  }

  Future<void> _showDirectory() async {
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
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.78,
        child: _ChapterDirectorySheet(
          chapters: widget.chapters,
          currentIndex: _index,
          cachedIds: cachedIds,
        ),
      ),
    );
    if (selected != null && mounted) await _jumpToChapter(selected);
  }

  Future<void> _showCache() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => ChapterCacheSheet(
      book: _cachedBook,
      currentIndex: _index,
      cache: _diskCache,
      loader: _fetchChapter,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: _errorView(),
      );
    }
    final chapter = _chapter;
    final preset = _preferences.themePreset;
    final overlayStyle = preset.isDark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle.copyWith(
        statusBarColor: preset.backgroundColor,
        systemNavigationBarColor: preset.backgroundColor,
      ),
      child: Scaffold(
        backgroundColor: preset.backgroundColor,
        appBar: _controlsVisible
            ? AppBar(
                backgroundColor: preset.backgroundColor,
                foregroundColor: preset.textColor,
                surfaceTintColor: Colors.transparent,
                title: Text(
                  chapter.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            : null,
        bottomNavigationBar: _controlsVisible
            ? _buildReaderControls(preset)
            : null,
        body: SafeArea(
          child: _loading
              ? Center(
                  child: CircularProgressIndicator(color: preset.accentColor),
                )
              : _error != null
              ? _errorView(textColor: preset.textColor)
              : LayoutBuilder(
                  builder: (context, constraints) => GestureDetector(
                    key: const ValueKey('reader-page-surface'),
                    behavior: HitTestBehavior.translucent,
                    onTapUp: (details) {
                      final width = constraints.maxWidth;
                      if (details.localPosition.dx < width / 3) {
                        _turnPage(-1);
                      } else if (details.localPosition.dx > width * 2 / 3) {
                        _turnPage(1);
                      } else {
                        _toggleControls();
                      }
                    },
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                        _preferences.horizontalPadding,
                        16,
                        _preferences.horizontalPadding,
                        48,
                      ),
                      itemCount: _paragraphs.length + 2,
                      itemBuilder: (context, itemIndex) {
                        if (itemIndex == 0) {
                          return Padding(
                            padding: EdgeInsets.only(
                              bottom: _preferences.paragraphSpacing,
                            ),
                            child: Text(
                              chapter.title,
                              key: const ValueKey('reader-chapter-title'),
                              style: TextStyle(
                                color: preset.textColor,
                                fontSize: _preferences.fontSize + 2,
                                fontWeight: FontWeight.w600,
                                height: 1.55,
                              ),
                            ),
                          );
                        }
                        if (itemIndex <= _paragraphs.length) {
                          return Padding(
                            padding: EdgeInsets.only(
                              bottom: _preferences.paragraphSpacing,
                            ),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  WidgetSpan(
                                    // Justification can discard leading spaces.
                                    // WidgetSpan reserves real first-line width
                                    // and Flutter scales it with the text once.
                                    child: SizedBox(
                                      width: _preferences.fontSize * 2,
                                      height: 0,
                                    ),
                                  ),
                                  TextSpan(text: _paragraphs[itemIndex - 1]),
                                ],
                              ),
                              key: ValueKey(
                                'reader-paragraph-${itemIndex - 1}',
                              ),
                              textAlign: TextAlign.justify,
                              semanticsLabel: _paragraphs[itemIndex - 1],
                              locale: const Locale('zh', 'CN'),
                              style: TextStyle(
                                color: preset.textColor,
                                fontSize: _preferences.fontSize,
                                fontWeight: _fontWeight(
                                  _preferences.fontWeight,
                                ),
                                height: _preferences.lineHeight,
                                letterSpacing: 0,
                              ),
                            ),
                          );
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 16,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: preset.textColor,
                                ),
                                icon: const Icon(Icons.chevron_left, size: 18),
                                label: const Text('上一章'),
                                onPressed: _index > 0
                                    ? () => _prev(startAtEnd: true)
                                    : null,
                              ),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: preset.textColor,
                                ),
                                icon: const Icon(Icons.chevron_right, size: 18),
                                label: const Text('下一章'),
                                onPressed: _index < widget.chapters.length - 1
                                    ? _next
                                    : null,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildReaderControls(ReaderThemePreset preset) {
    final chapterCount = widget.chapters.length;
    final rawIndex = _chapterSeekValue ?? _index.toDouble();
    final previewIndex = rawIndex.round().clamp(0, chapterCount - 1);
    return Material(
      color: preset.panelColor,
      elevation: 10,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${previewIndex + 1}/$chapterCount  ${widget.chapters[previewIndex].title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: preset.mutedTextColor),
              ),
              Row(
                children: [
                  IconButton(
                    tooltip: '上一章',
                    color: preset.textColor,
                    onPressed: _index > 0
                        ? () => _prev(startAtEnd: true)
                        : null,
                    icon: const Icon(Icons.skip_previous),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: preset.accentColor,
                        thumbColor: preset.accentColor,
                        overlayColor: preset.accentColor.withValues(
                          alpha: 0.16,
                        ),
                        inactiveTrackColor: preset.textColor.withValues(
                          alpha: 0.18,
                        ),
                      ),
                      child: Slider(
                        min: 0,
                        max: (chapterCount - 1).toDouble(),
                        divisions: chapterCount > 1 && chapterCount <= 300
                            ? chapterCount - 1
                            : null,
                        value: rawIndex.clamp(0, (chapterCount - 1).toDouble()),
                        onChanged: chapterCount > 1
                            ? (value) {
                                setState(() => _chapterSeekValue = value);
                              }
                            : null,
                        onChangeEnd: chapterCount > 1
                            ? (value) {
                                final target = value.round();
                                setState(() => _chapterSeekValue = null);
                                _jumpToChapter(target);
                              }
                            : null,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '下一章',
                    color: preset.textColor,
                    onPressed: _index < chapterCount - 1 ? _next : null,
                    icon: const Icon(Icons.skip_next),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: _ReaderControlAction(
                      icon: Icons.format_list_numbered,
                      label: '目录',
                      color: preset.textColor,
                      onTap: _showDirectory,
                    ),
                  ),
                  Expanded(
                    child: _ReaderControlAction(
                      icon: preset.isDark
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                      label: preset.isDark ? '日间' : '夜间',
                      color: preset.textColor,
                      onTap: _toggleNightTheme,
                    ),
                  ),
                  Expanded(
                    child: _ReaderControlAction(
                      icon: Icons.text_format,
                      label: '排版',
                      color: preset.textColor,
                      onTap: _showAppearanceSettings,
                    ),
                  ),
                  Expanded(
                    child: _ReaderControlAction(
                      icon: Icons.download_for_offline_outlined,
                      label: '缓存',
                      color: preset.textColor,
                      onTap: _showCache,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorView({Color? textColor}) => Center(
    child: Padding(
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
          OutlinedButton(onPressed: _load, child: const Text('重试')),
        ],
      ),
    ),
  );
}

class _ReaderControlAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ReaderControlAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(foregroundColor: color),
      onPressed: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class _ReaderAppearanceSheet extends StatefulWidget {
  final ReaderPreferences initialValue;
  final ValueChanged<ReaderPreferences> onChanged;

  const _ReaderAppearanceSheet({
    required this.initialValue,
    required this.onChanged,
  });

  @override
  State<_ReaderAppearanceSheet> createState() => _ReaderAppearanceSheetState();
}

class _ReaderAppearanceSheetState extends State<_ReaderAppearanceSheet> {
  late ReaderPreferences _value = widget.initialValue;

  void _update(ReaderPreferences value) {
    setState(() => _value = value.normalized());
    widget.onChanged(_value);
  }

  @override
  Widget build(BuildContext context) {
    final preset = _value.themePreset;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      color: preset.sheetColor,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    '排版设置',
                    style: TextStyle(
                      color: preset.textColor,
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: preset.accentColor,
                    ),
                    onPressed: () => _update(const ReaderPreferences()),
                    child: const Text('恢复默认'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '阅读背景',
                style: TextStyle(color: preset.mutedTextColor, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final option in ReaderThemePreset.values)
                    _ReaderThemeChoice(
                      preset: option,
                      selected: option == preset,
                      onTap: () {
                        _update(_value.copyWith(themePreset: option));
                      },
                    ),
                ],
              ),
              const SizedBox(height: 18),
              _ReaderSettingSlider(
                label: '字号',
                valueLabel: _value.fontSize.round().toString(),
                value: _value.fontSize,
                min: 14,
                max: 32,
                divisions: 18,
                preset: preset,
                onChanged: (value) {
                  _update(_value.copyWith(fontSize: value));
                },
              ),
              const SizedBox(height: 10),
              Text(
                '字重',
                style: TextStyle(color: preset.textColor, fontSize: 14),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final option in const [300, 400, 500, 600, 700])
                    _ReaderWeightChoice(
                      weight: option,
                      selected: _value.fontWeight == option,
                      preset: preset,
                      onTap: () {
                        _update(_value.copyWith(fontWeight: option));
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _ReaderSettingSlider(
                label: '行距',
                valueLabel: _value.lineHeight.toStringAsFixed(1),
                value: _value.lineHeight,
                min: 1.2,
                max: 2.4,
                divisions: 12,
                preset: preset,
                onChanged: (value) {
                  _update(_value.copyWith(lineHeight: value));
                },
              ),
              _ReaderSettingSlider(
                label: '段距',
                valueLabel: '${_value.paragraphSpacing.round()}',
                value: _value.paragraphSpacing,
                min: 0,
                max: 32,
                divisions: 16,
                preset: preset,
                onChanged: (value) {
                  _update(_value.copyWith(paragraphSpacing: value));
                },
              ),
              _ReaderSettingSlider(
                label: '左右边距',
                valueLabel: '${_value.horizontalPadding.round()}',
                value: _value.horizontalPadding,
                min: 8,
                max: 48,
                divisions: 20,
                preset: preset,
                onChanged: (value) {
                  _update(_value.copyWith(horizontalPadding: value));
                },
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: preset.accentColor,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('完成'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReaderThemeChoice extends StatelessWidget {
  final ReaderThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  const _ReaderThemeChoice({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: preset.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 66,
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: preset.backgroundColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? preset.accentColor
                  : preset.textColor.withValues(alpha: 0.18),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected ? preset.accentColor : preset.textColor,
                size: 20,
              ),
              const SizedBox(height: 4),
              Text(
                preset.label,
                style: TextStyle(color: preset.textColor, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReaderWeightChoice extends StatelessWidget {
  final int weight;
  final bool selected;
  final ReaderThemePreset preset;
  final VoidCallback onTap;

  const _ReaderWeightChoice({
    required this.weight,
    required this.selected,
    required this.preset,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 38,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? preset.accentColor.withValues(alpha: 0.16)
              : preset.textColor.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(9),
          border: selected ? Border.all(color: preset.accentColor) : null,
        ),
        child: Text(
          '字',
          style: TextStyle(
            color: preset.textColor,
            fontWeight: _fontWeight(weight),
          ),
        ),
      ),
    );
  }
}

class _ReaderSettingSlider extends StatelessWidget {
  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ReaderThemePreset preset;
  final ValueChanged<double> onChanged;

  const _ReaderSettingSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.preset,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 68,
          child: Text(
            label,
            style: TextStyle(color: preset.textColor, fontSize: 14),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: preset.accentColor,
              thumbColor: preset.accentColor,
              overlayColor: preset.accentColor.withValues(alpha: 0.16),
              inactiveTrackColor: preset.textColor.withValues(alpha: 0.18),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            valueLabel,
            textAlign: TextAlign.end,
            style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
          ),
        ),
      ],
    );
  }
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

extension on ReaderThemePreset {
  bool get isDark => this == ReaderThemePreset.dark;

  String get label => switch (this) {
    ReaderThemePreset.light => '明亮',
    ReaderThemePreset.eyeCare => '护眼',
    ReaderThemePreset.parchment => '纸张',
    ReaderThemePreset.dark => '夜间',
  };

  Color get backgroundColor => switch (this) {
    ReaderThemePreset.light => const Color(0xFFFAF9F6),
    ReaderThemePreset.eyeCare => const Color(0xFFE8F1DF),
    ReaderThemePreset.parchment => const Color(0xFFF3E4C2),
    ReaderThemePreset.dark => const Color(0xFF171717),
  };

  Color get textColor => switch (this) {
    ReaderThemePreset.light => const Color(0xFF292724),
    ReaderThemePreset.eyeCare => const Color(0xFF273128),
    ReaderThemePreset.parchment => const Color(0xFF493D2B),
    ReaderThemePreset.dark => const Color(0xFFD2D2D2),
  };

  Color get accentColor => switch (this) {
    ReaderThemePreset.eyeCare => const Color(0xFF4F6F52),
    ReaderThemePreset.dark => const Color(0xFFE86A49),
    _ => const Color(0xFFE8532D),
  };

  Color get mutedTextColor => textColor.withValues(alpha: 0.65);

  Color get panelColor => Color.alphaBlend(
    textColor.withValues(alpha: isDark ? 0.09 : 0.055),
    backgroundColor,
  );

  Color get sheetColor => panelColor;
}

FontWeight _fontWeight(int value) => switch (value) {
  <= 300 => FontWeight.w300,
  400 => FontWeight.w400,
  500 => FontWeight.w500,
  600 => FontWeight.w600,
  _ => FontWeight.w700,
};
