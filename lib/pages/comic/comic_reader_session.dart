part of '../comic_reader_page.dart';

/// 漫画阅读器的会话逻辑：章节加载、位置记录、阅读时长与章节跳转。
///
/// 从 `comic_reader_page.dart` 拆出的 part，和 `reader_page.dart` 的
/// `reader/reader_page_progress.dart` 同一组织方式：这里只搬代码，行为不变。
extension _ComicReaderSession on _ComicReaderPageState {
  /// 记住目录，让「最近阅读/书架」下次能跳过详情页直接进漫画。
  ///
  /// 写入失败不影响阅读：拿不到目录最多是下次仍走详情页。
  Future<void> _rememberCatalogue() async {
    try {
      final store = widget.cache ?? ChapterCacheStore.instance;
      await store.saveBook(
        CachedBook(
          id: widget.bookId,
          title: widget.title,
          cover: widget.cover,
          chapters: widget.chapters,
        ),
      );
    } catch (_) {
      // 缓存不可写时保持原有入口。
    }
  }

  Future<void> _loadChapter() async {
    if (widget.chapters.isEmpty) return;
    final generation = ++_loadGeneration;
    final chapter = _chapter;
    _saveTimer?.cancel();
    ++_restoreTicket;
    // 换章后由新的 PageController(initialPage) 决定翻页起点。
    _pageController?.dispose();
    _pageController = null;
    _setState(() {
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
      _imageRequest?.cancel();
      final request = _imageRequest = BackendRequest();
      final images = await ApiClient.instance.withCancellation(
        request,
        () async =>
            await (widget.chapterLoader?.call(chapter) ??
                ApiClient.instance.comicImages(chapter.itemId)),
      );
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
      _setState(() {
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
      _setState(() {
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
    if (_pagedMode) {
      final controller = _pageController;
      if (controller != null && controller.hasClients) {
        final page = controller.page;
        if (page != null && page.isFinite) return page.roundToDouble();
      }
      return _lastPosition;
    }
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
      _setState(() {
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
    _scheduleRestore();
    return _layout!;
  }

  /// 首帧后完成位置恢复。
  ///
  /// 条漫模式依赖滚动偏移，翻页模式由 [PageController.initialPage] 定位，
  /// 只需解除 [_restoring] 让同一套进度记录逻辑接管。
  void _scheduleRestore() {
    final generation = _loadGeneration;
    final ticket = ++_restoreTicket;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _loadGeneration ||
          ticket != _restoreTicket) {
        return;
      }
      if (_pagedMode) {
        final controller = _pageController;
        if (controller == null || !controller.hasClients) return;
        _restoring = false;
        _recordVisiblePosition();
        return;
      }
      if (!_scroll.hasClients || _layout == null) return;
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
  }

  void _recordVisiblePosition() {
    if (_restoring || _images.isEmpty) return;
    if (!_pagedMode && !_scroll.hasClients) return;
    final position = _logicalPosition();
    final page = position.floor().clamp(0, _images.length - 1);
    if (_visiblePage != page) _setState(() => _visiblePage = page);
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

  /// 翻页模式的位置回调：与滚动模式共用同一套记录/保存路径。
  void _onPageChanged(int page) {
    if (_visiblePage != page) _setState(() => _visiblePage = page);
    if (_restoring) return;
    _recordVisiblePosition();
    if (!_progressReady) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _settleReadTime();
      unawaited(_saveProgress());
    });
  }

  int _currentPageIndex() {
    if (_images.isEmpty) return 0;
    return _logicalPosition().floor().clamp(0, _images.length - 1).toInt();
  }

  /// 条漫/翻页模式互切，当前页保持不变。
  void _togglePagedMode() {
    final page = _currentPageIndex();
    final stale = _pageController;
    final paged = !_pagedMode;
    _setState(() {
      _pagedMode = paged;
      if (paged) {
        _visiblePage = page;
        if (_readyImages.contains(page)) _lastPosition = page.toDouble();
        _restoring = false;
        _pageController = PageController(initialPage: page, keepPage: false);
      } else {
        _pageController = null;
        _restoreAnchor = page.toDouble();
        _restoring = true;
      }
    });
    stale?.dispose();
    if (!paged) {
      // 布局可能命中缓存，不会自动排队恢复回调，这里显式回到当前页。
      _scheduleRestore();
    }
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
    // _logicalPosition falls back to _lastPosition when no controller is
    // attached, and _lastPosition itself only moves on displayed pages.
    if (!_restoring) {
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
    _setState(() => _chapterIndex = index);
    unawaited(_loadChapter());
  }

  void _reloadChapter() {
    _settleReadTime();
    unawaited(_saveProgress());
    unawaited(_loadChapter());
  }

  Future<void> _showDirectory() async {
    final selected = await showComicDirectorySheet(
      context: context,
      chapters: widget.chapters,
      currentIndex: _chapterIndex,
    );
    if (mounted && selected != null) _changeChapter(selected);
  }

  Future<void> _showImage(int index) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ComicImageViewer(
        image: _images[index],
        pageNumber: index + 1,
        providerFactory: widget.imageProviderFactory,
        aspectRatio: _ratios[index],
      ),
    ),
  );

  PageController _ensurePageController() => _pageController ??= PageController(
    initialPage: _visiblePage,
    keepPage: false,
  );

  void _updateImageSizeForGeneration(int index, int width, int height) =>
      _updateImageSize(_loadGeneration, index, width, height);

  void _imageFailedForGeneration(int index) =>
      _imageFailed(_loadGeneration, index);
}
