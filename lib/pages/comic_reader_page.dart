import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/chapter_media.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/comic_page_layout.dart';
import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../services/reader_history.dart';
import '../services/user_facing_error.dart';

typedef ComicChapterLoader = Future<List<ComicImage>> Function(Chapter chapter);
typedef ComicImageProviderFactory =
    ImageProvider<Object> Function(ComicImage image);

class ComicReaderPage extends StatefulWidget {
  final String bookId;
  final String title;
  final String cover;
  final List<Chapter> chapters;
  final int startIndex;
  final ReaderStore? readerStore;
  final ComicChapterLoader? chapterLoader;
  final ComicImageProviderFactory? imageProviderFactory;

  const ComicReaderPage({
    super.key,
    required this.bookId,
    required this.title,
    this.cover = '',
    required this.chapters,
    required this.startIndex,
    this.readerStore,
    this.chapterLoader,
    this.imageProviderFactory,
  });

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage>
    with WidgetsBindingObserver {
  final _scroll = ScrollController(keepScrollOffset: false);
  late final ReaderStore _readerStore = scopedHistoryStore(
    widget.readerStore ?? LibraryStore.instance,
    'manga',
  );
  late final _history = ReaderHistory(_readerStore);
  late int _chapterIndex;
  List<ComicImage> _images = const [];
  List<double> _ratios = const [];
  final Set<int> _readyImages = {};
  ComicPageLayout? _layout;
  double _layoutWidth = 0;
  int _layoutRevision = 0;
  int _builtLayoutRevision = -1;
  double? _restoreAnchor;
  int _restoreTicket = 0;
  int _loadGeneration = 0;
  int _visiblePage = 0;
  double _lastPosition = 0;
  bool _restoring = true;
  bool _loading = true;
  bool _progressReady = false;
  bool _appActive = true;
  bool _sessionActive = false;
  DateTime _readStart = DateTime.now();
  Timer? _saveTimer;
  String? _error;

  Chapter get _chapter => widget.chapters[_chapterIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _chapterIndex = widget.chapters.isEmpty
        ? 0
        : widget.startIndex.clamp(0, widget.chapters.length - 1);
    _scroll.addListener(_onScroll);
    if (widget.chapters.isEmpty) {
      _loading = false;
      _error = '暂无可阅读章节';
    } else {
      unawaited(_loadChapter());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _settleReadTime();
    _sessionActive = false;
    unawaited(_saveProgress());
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (!active && _appActive) {
      _settleReadTime();
      _sessionActive = false;
      _appActive = false;
      unawaited(_saveProgress());
    } else if (active && !_appActive) {
      _appActive = true;
      _startReadTime();
    }
  }

  Future<void> _loadChapter() async {
    if (widget.chapters.isEmpty) return;
    final generation = ++_loadGeneration;
    final chapter = _chapter;
    _saveTimer?.cancel();
    ++_restoreTicket;
    setState(() {
      _loading = true;
      _error = null;
      _progressReady = false;
      _restoring = true;
      _sessionActive = false;
      _images = const [];
      _ratios = const [];
      _readyImages.clear();
      _layout = null;
      _restoreAnchor = null;
      _visiblePage = 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    // Serialized history reads also wait for the departing reader's save.
    final history = _history.load(widget.bookId).catchError((Object _) => null);
    try {
      final images =
          await (widget.chapterLoader?.call(chapter) ??
              ApiClient.instance.comicImages(chapter.itemId));
      if (!mounted || generation != _loadGeneration) return;
      if (images.isEmpty) throw const ApiException('本章暂无可阅读图片');
      final saved = await history;
      if (!mounted || generation != _loadGeneration) return;
      var position = 0.0;
      if (saved?['chapterId']?.toString() == chapter.itemId &&
          saved?['positionUnit'] == 'comic-page') {
        final value = saved?['position'];
        if (value is num && value.isFinite) {
          position = value.toDouble().clamp(0.0, images.length.toDouble());
        }
      }
      setState(() {
        _images = List.unmodifiable(images);
        _ratios = images.map(_initialRatio).toList();
        _restoreAnchor = position;
        _lastPosition = position;
        _visiblePage = position.floor().clamp(0, images.length - 1);
        ++_layoutRevision;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = userFacingError(error);
        _loading = false;
      });
    }
  }

  static double _initialRatio(ComicImage image) {
    final width = image.width;
    final height = image.height;
    return width != null && height != null && width > 0 && height > 0
        ? (width / height).clamp(0.01, 20.0)
        : 2 / 3;
  }

  double _logicalPosition() {
    if (_layout == null || !_scroll.hasClients) return _lastPosition;
    final scroll = _scroll.position;
    if (scroll.hasContentDimensions &&
        scroll.maxScrollExtent > 0 &&
        scroll.pixels >= scroll.maxScrollExtent - 1 &&
        _readyImages.contains(_images.length - 1)) {
      return _images.length.toDouble();
    }
    return _layout!.positionAtOffset(scroll.pixels);
  }

  void _updateImageSize(int generation, int index, int width, int height) {
    if (!mounted || generation != _loadGeneration || index >= _images.length) {
      return;
    }
    _readyImages.add(index);
    final ratio = (width / height).clamp(0.01, 20.0);
    if ((_ratios[index] - ratio).abs() > 0.0001) {
      // Capture against the layout that is on screen, before changing heights.
      _restoreAnchor ??= _logicalPosition();
      _restoring = true;
      setState(() {
        _ratios[index] = ratio;
        ++_layoutRevision;
      });
    } else {
      _recordVisiblePosition();
    }
  }

  void _imageFailed(int generation, int index) {
    if (!mounted || generation != _loadGeneration) return;
    _readyImages.remove(index);
    if (_visiblePage == index) {
      _settleReadTime();
      _sessionActive = false;
    }
  }

  ComicPageLayout _layoutFor(double width) {
    if (_layout != null &&
        _layoutWidth == width &&
        _builtLayoutRevision == _layoutRevision) {
      return _layout!;
    }
    _restoreAnchor ??= _logicalPosition();
    _restoring = true;
    _layout = ComicPageLayout(
      _ratios.map((ratio) => (width / ratio).clamp(96.0, width * 100)),
    );
    _layoutWidth = width;
    _builtLayoutRevision = _layoutRevision;
    final generation = _loadGeneration;
    final ticket = ++_restoreTicket;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _loadGeneration ||
          ticket != _restoreTicket ||
          !_scroll.hasClients ||
          _layout == null) {
        return;
      }
      final anchor = _restoreAnchor ?? 0;
      _restoreAnchor = null;
      _scroll.jumpTo(
        _layout!
            .offsetForPosition(anchor)
            .clamp(0.0, _scroll.position.maxScrollExtent),
      );
      _restoring = false;
      _recordVisiblePosition();
    });
    return _layout!;
  }

  void _recordVisiblePosition() {
    if (_restoring || _images.isEmpty || !_scroll.hasClients) return;
    final position = _logicalPosition();
    final page = position.floor().clamp(0, _images.length - 1);
    if (_visiblePage != page) setState(() => _visiblePage = page);
    if (!_readyImages.contains(page)) {
      _settleReadTime();
      _sessionActive = false;
      return;
    }
    _lastPosition = position;
    final firstDisplay = !_progressReady;
    _progressReady = true;
    _startReadTime();
    if (firstDisplay) unawaited(_saveProgress(createHistory: true));
  }

  void _onScroll() {
    _saveTimer?.cancel();
    if (_restoring) return;
    _recordVisiblePosition();
    if (!_progressReady) return;
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _settleReadTime();
      unawaited(_saveProgress());
    });
  }

  void _startReadTime() {
    if (_appActive &&
        _progressReady &&
        !_sessionActive &&
        _readyImages.contains(_visiblePage)) {
      _readStart = DateTime.now();
      _sessionActive = true;
    }
  }

  void _settleReadTime() {
    if (!_sessionActive) return;
    final now = DateTime.now();
    final seconds = now.difference(_readStart).inMilliseconds / 1000;
    _readStart = now;
    if (seconds >= 1) {
      unawaited(
        _readerStore
            .accumulateReadTime(widget.bookId, 'manga', seconds)
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> _saveProgress({bool createHistory = false}) async {
    if (!_progressReady || _images.isEmpty) return;
    // Only a successfully displayed image advances the durable position.
    if (!_restoring && _scroll.hasClients) {
      final position = _logicalPosition();
      final page = position.floor().clamp(0, _images.length - 1);
      if (_readyImages.contains(page)) _lastPosition = position;
    }
    await _history.save({
      'id': widget.bookId,
      'bookId': widget.bookId,
      'kind': 'manga',
      'title': widget.title,
      'cover': widget.cover,
      'chapterId': _chapter.itemId,
      'episode': _chapterIndex,
      'position': _lastPosition,
      'maxScroll': _images.length.toDouble(),
      'positionUnit': 'comic-page',
      'progress':
          ((_chapterIndex + _lastPosition / _images.length) /
                  widget.chapters.length)
              .clamp(0.0, 1.0),
      'time': DateTime.now().millisecondsSinceEpoch,
    }, createHistory: createHistory);
  }

  void _changeChapter(int index) {
    if (index < 0 ||
        index >= widget.chapters.length ||
        index == _chapterIndex) {
      return;
    }
    _saveTimer?.cancel();
    _settleReadTime();
    unawaited(
      _saveProgress(),
    ); // Snapshot is captured before changing chapters.
    setState(() => _chapterIndex = index);
    unawaited(_loadChapter());
  }

  void _reloadChapter() {
    _settleReadTime();
    unawaited(_saveProgress());
    unawaited(_loadChapter());
  }

  Future<void> _showDirectory() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: _ComicDirectory(
          chapters: widget.chapters,
          currentIndex: _chapterIndex,
        ),
      ),
    );
    if (mounted && selected != null) _changeChapter(selected);
  }

  Future<void> _showImage(int index) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _ComicImageViewer(
        image: _images[index],
        pageNumber: index + 1,
        providerFactory: widget.imageProviderFactory,
        aspectRatio: _ratios[index],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final empty = widget.chapters.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          empty ? widget.title : _chapter.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: empty
            ? null
            : [
                IconButton(
                  tooltip: '刷新章节',
                  onPressed: _loading ? null : _reloadChapter,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: '目录',
                  onPressed: _showDirectory,
                  icon: const Icon(Icons.list_alt),
                ),
              ],
      ),
      bottomNavigationBar: empty
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '上一章',
                      onPressed: _chapterIndex == 0
                          ? null
                          : () => _changeChapter(_chapterIndex - 1),
                      icon: const Icon(Icons.skip_previous),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '第 ${_chapterIndex + 1} / ${widget.chapters.length} 章',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          Text(
                            _images.isEmpty
                                ? '漫画阅读'
                                : '第 ${_visiblePage + 1} / ${_images.length} 页',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '下一章',
                      onPressed: _chapterIndex + 1 >= widget.chapters.length
                          ? null
                          : () => _changeChapter(_chapterIndex + 1),
                      icon: const Icon(Icons.skip_next),
                    ),
                  ],
                ),
              ),
            ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _errorView(canRetry: !empty)
            : LayoutBuilder(
                builder: (context, constraints) {
                  final width = math.min(
                    math.max(constraints.maxWidth, 1.0),
                    900.0,
                  );
                  final layout = _layoutFor(width);
                  final generation = _loadGeneration;
                  return ListView.builder(
                    key: const ValueKey('comic-reader-pages'),
                    controller: _scroll,
                    padding: EdgeInsets.zero,
                    addAutomaticKeepAlives: false,
                    itemCount: _images.length,
                    itemExtentBuilder: (index, _) => index < layout.pageCount
                        ? layout.heightAt(index)
                        : null,
                    itemBuilder: (context, index) => Center(
                      child: SizedBox(
                        width: width,
                        child: _ComicImageTile(
                          key: ValueKey('comic-image-$generation-$index'),
                          image: _images[index],
                          pageNumber: index + 1,
                          providerFactory: widget.imageProviderFactory,
                          onReady: (w, h) =>
                              _updateImageSize(generation, index, w, h),
                          onFailure: () => _imageFailed(generation, index),
                          onTap: () => _showImage(index),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _errorView({required bool canRetry}) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined, size: 48),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center),
          if (canRetry) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _reloadChapter,
              child: const Text('重新加载本章'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _ComicImageTile extends StatefulWidget {
  final ComicImage image;
  final int pageNumber;
  final ComicImageProviderFactory? providerFactory;
  final void Function(int width, int height)? onReady;
  final VoidCallback? onFailure;
  final VoidCallback? onTap;

  const _ComicImageTile({
    super.key,
    required this.image,
    required this.pageNumber,
    this.providerFactory,
    this.onReady,
    this.onFailure,
    this.onTap,
  });

  @override
  State<_ComicImageTile> createState() => _ComicImageTileState();
}

class _ComicImageTileState extends State<_ComicImageTile> {
  ImageProvider<Object>? _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  int _attempt = 0;
  bool _retrying = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_provider == null) _resolve();
  }

  void _resolve() {
    _removeListener();
    final provided = widget.providerFactory?.call(widget.image);
    _provider =
        provided ??
        CachedNetworkImageProvider(
          widget.image.url,
          headers: widget.image.headers,
          maxWidth: 2048,
          maxHeight: 8192,
        );
    final attempt = _attempt;
    var reported = false;
    _listener = ImageStreamListener(
      (info, synchronous) {
        final width = info.image.width;
        final height = info.image.height;
        info.dispose(); // This listener owns its ImageInfo clone, not Image's.
        if (reported) return;
        reported = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && attempt == _attempt) {
            widget.onReady?.call(width, height);
          }
        });
      },
      onError: (Object error, StackTrace? stack) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && attempt == _attempt) widget.onFailure?.call();
        });
      },
    );
    _stream = _provider!.resolve(createLocalImageConfiguration(context));
    _stream!.addListener(_listener!);
  }

  void _removeListener() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      if (widget.providerFactory == null) {
        await CachedNetworkImage.evictFromCache(widget.image.url);
      }
      await _provider?.evict();
    } catch (_) {
      // A cache cleanup failure should not suppress an explicit network retry.
    }
    if (!mounted) return;
    setState(() {
      ++_attempt;
      _retrying = false;
      _resolve();
    });
  }

  @override
  void dispose() {
    _removeListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '第 ${widget.pageNumber} 页漫画',
    button: widget.onTap != null,
    child: GestureDetector(
      onTap: widget.onTap,
      child: Image(
        key: ValueKey(_attempt),
        image: _provider!,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: false,
        frameBuilder: (context, child, frame, synchronous) => frame != null
            ? child
            : ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: Center(
                  child: SingleChildScrollView(
                    primary: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(),
                        ),
                        const SizedBox(height: 8),
                        Text('正在加载第 ${widget.pageNumber} 页'),
                      ],
                    ),
                  ),
                ),
              ),
        errorBuilder: (context, error, stack) => ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Center(
            child: SingleChildScrollView(
              primary: false,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '第 ${widget.pageNumber} 页加载失败',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _retrying ? null : _retry,
                      icon: const Icon(Icons.refresh),
                      label: Text(_retrying ? '正在重试' : '重试图片'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ComicDirectory extends StatefulWidget {
  final List<Chapter> chapters;
  final int currentIndex;
  const _ComicDirectory({required this.chapters, required this.currentIndex});

  @override
  State<_ComicDirectory> createState() => _ComicDirectoryState();
}

class _ComicDirectoryState extends State<_ComicDirectory> {
  late final _controller = ScrollController(
    initialScrollOffset: widget.currentIndex * 56.0,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          '目录 · 共 ${widget.chapters.length} 章',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      Expanded(
        child: ListView.builder(
          controller: _controller,
          itemExtent: 56,
          itemCount: widget.chapters.length,
          itemBuilder: (context, index) => ListTile(
            selected: index == widget.currentIndex,
            title: Text(
              widget.chapters[index].title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: index == widget.currentIndex
                ? const Icon(Icons.check)
                : null,
            onTap: () => Navigator.pop(context, index),
          ),
        ),
      ),
    ],
  );
}

class _ComicImageViewer extends StatelessWidget {
  final ComicImage image;
  final int pageNumber;
  final double aspectRatio;
  final ComicImageProviderFactory? providerFactory;

  const _ComicImageViewer({
    required this.image,
    required this.pageNumber,
    required this.aspectRatio,
    this.providerFactory,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('第 $pageNumber 页'),
      leading: IconButton(
        tooltip: '关闭大图',
        icon: const Icon(Icons.close),
        onPressed: () => Navigator.pop(context),
      ),
    ),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return InteractiveViewer(
            key: const ValueKey('comic-image-zoom'),
            constrained: false,
            minScale: 1,
            maxScale: 5,
            child: SizedBox(
              width: width,
              height: math.max(width / aspectRatio, constraints.maxHeight),
              child: _ComicImageTile(
                image: image,
                pageNumber: pageNumber,
                providerFactory: providerFactory,
              ),
            ),
          );
        },
      ),
    ),
  );
}
