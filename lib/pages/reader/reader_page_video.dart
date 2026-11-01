part of '../reader_page.dart';

extension _ReaderPageVideo on _ReaderPageState {
  // Callers rebuild the menu after invalidating its pending navigation.
  void _cancelVideoOpen() {
    _videoOpenRequest?.cancel();
    _videoOpenRequest = null;
  }

  Future<void> _loadVideoMatch() async {
    if (widget.localOnly ||
        widget.chapters.isEmpty ||
        !_preferencesReady ||
        !_preferences.showVideoButton ||
        _videoMatch != null ||
        _videoMatchRequest != null) {
      return;
    }
    final now = DateTime.now();
    if (_videoMatchAttempt != null &&
        now.difference(_videoMatchAttempt!) < const Duration(seconds: 15)) {
      return;
    }
    _videoMatchAttempt = now;
    final request = _videoMatchRequest = BackendRequest();
    try {
      final match = await ApiClient.instance.withCancellation(
        request,
        () => ApiClient.instance.readerVideoMatch(widget.bookId),
      );
      if (mounted && !request.isCancelled) {
        _setState(() => _videoMatch = match);
      }
    } catch (_) {
      // An optional entry must not interrupt reading; retry on a later menu open.
    } finally {
      if (identical(_videoMatchRequest, request)) _videoMatchRequest = null;
    }
  }

  Future<void> _openReaderVideo() async {
    final match = _videoMatch;
    if (_openingVideo ||
        match == null ||
        !match.available ||
        _loading ||
        _error != null ||
        !_controlsVisible ||
        !_preferences.showVideoButton ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final chapterId = _chapter.itemId;
    final sync = _preferences.videoChapterSync;
    final mapped = sync ? match.chapters[chapterId] : null;
    final seriesId = mapped?.seriesId ?? match.seriesId;
    final request = BackendRequest();
    _setState(() => _videoOpenRequest = request);
    try {
      final api = ApiClient.instance;
      final (directory, detail) = await api.withCancellation(request, () async {
        return (
          await api.directory(seriesId, tab: '短剧'),
          await api.seriesDetail(seriesId),
        );
      });
      final volumes = await parseDirectoryAsync(directory);
      final episodes = [for (final volume in volumes) ...volume];
      if (episodes.isEmpty) throw const ApiException('暂无可播放的改编剧集');
      Map<String, dynamic>? saved;
      try {
        saved = await PlayerHistory(_readerStore).load(seriesId);
      } catch (_) {
        // Local history is optional; never synthesize a progress record.
      }
      if (!mounted ||
          request.isCancelled ||
          !_controlsVisible ||
          chapterId != _chapter.itemId) {
        return;
      }
      final mappedIndex = mapped == null
          ? -1
          : episodes.indexWhere((episode) => episode.itemId == mapped.videoId);
      final resumeIndex = resumeEpisodeIndex(saved, episodes);
      final index = mappedIndex >= 0 ? mappedIndex : resumeIndex ?? 0;
      if (episodes[index].disabled) {
        throw const ApiException('该剧集暂不可播放');
      }
      String? message;
      if (sync) {
        final maxIndex = widget.chapters.indexWhere(
          (chapter) => chapter.itemId == match.lastMatchedChapterId,
        );
        message = mappedIndex >= 0
            ? '已定位在读章节剧情'
            : resumeIndex == null
            ? '暂无本章剧情，将从首集播放'
            : maxIndex >= 0 && _index > maxIndex
            ? '暂无后续章节剧情，已定位上次在看'
            : '暂无本章剧情，已定位上次在看';
      }
      _captureScrollProgress();
      await _persistProgress();
      if (!mounted ||
          request.isCancelled ||
          !_controlsVisible ||
          !_preferences.showVideoButton ||
          ModalRoute.of(context)?.isCurrent != true ||
          chapterId != _chapter.itemId) {
        return;
      }
      // Hand navigation off before closing the menu cancels pending actions.
      _videoOpenRequest = null;
      _setControlsVisible(false);
      if (message != null) _showMessage(message);
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerPage(
            bookId: seriesId,
            kind: parseMediaIdResult(directory, seriesId)?.kind == 'manju'
                ? 'manju'
                : 'video',
            title: detail.title.isEmpty ? widget.title : detail.title,
            cover: detail.cover.isNotEmpty
                ? detail.cover
                : match.covers[seriesId] ?? '',
            eps: episodes,
            startIndex: index,
            shortSeries: true,
            initialSeriesDetail: detail,
            historyStore: _readerStore,
            // Chapter synchronization targets the episode beginning, not an
            // unrelated saved position inside that same episode.
            startPosition: mappedIndex >= 0 ? Duration.zero : null,
          ),
        ),
      );
    } catch (_) {
      if (mounted && !request.isCancelled) {
        _showMessage('改编剧暂时无法打开，请稍后重试');
      }
    } finally {
      if (mounted && identical(_videoOpenRequest, request)) {
        _setState(() => _videoOpenRequest = null);
      }
    }
  }
}
