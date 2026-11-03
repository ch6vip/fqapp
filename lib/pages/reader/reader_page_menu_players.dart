part of '../reader_page.dart';

extension _ReaderPageMenuPlayers on _ReaderPageState {
  Widget _buildReaderMenuPlayers(
    ReaderThemePreset preset,
  ) => ReaderAudioBridge.buildMenuForBook(
    context,
    bookId: widget.bookId,
    builder: (context, currentBook) {
      final match = _videoMatch;
      final video =
          _preferences.showVideoButton && match != null && match.available;
      final reducedMotion =
          preset.isEink ||
          MediaQuery.disableAnimationsOf(context) ||
          MediaQuery.accessibleNavigationOf(context);
      return Stack(
        alignment: Alignment.bottomLeft,
        children: [
          ReaderListenCapsuleHost(monochrome: preset.isEink),
          if (video)
            // 87 = 听书钮的下边距 20 + 直径 42 + 两颗钮之间 11 的间隙；两颗
            // 钮一起缩到 42 后这条留白得跟着收，否则「看」会飘到正文里。
            Padding(
              padding: const EdgeInsets.only(right: 16, bottom: 73),
              child: Align(
                alignment: Alignment.centerRight,
                child: ReaderVideoButton(
                  menuVisibility: _controlsVisibility,
                  preset: preset,
                  cover: match.covers[match.seriesId] ?? '',
                  loading: _openingVideo,
                  onTap: _loading || _error != null
                      ? null
                      : () => unawaited(_openReaderVideo()),
                ),
              ),
            ),
          IgnorePointer(
            ignoring: currentBook,
            child: ExcludeSemantics(
              excluding: currentBook,
              child: AnimatedSwitcher(
                duration: reducedMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 250),
                child: currentBook
                    ? const SizedBox.shrink()
                    : Padding(
                        key: const ValueKey('reader-listen-entry'),
                        padding: const EdgeInsets.only(right: 16, bottom: 20),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: ReaderListenButton(
                            preset: preset,
                            loading: _openingListening,
                            unavailable: _readerAudioUnavailable,
                            // 默认引擎直接起播：不再弹「听书方式」面板挡在
                            // 起播前面。引擎由设置里存的偏好决定，想换引擎
                            // 去听书胶囊上那个三点（未播放时它就是「选择
                            // 播放引擎」）。起点仍是当前页第一段。
                            onTap: _loading || _error != null
                                ? null
                                : () => unawaited(_openListening(fromPage: true)),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      );
    },
  );

  bool get _readerAudioUnavailable {
    final tones = _readerTones;
    return !widget.localOnly &&
        tones != null &&
        !tones.hasFixedTone &&
        tones.ttsTones.isEmpty &&
        tones.narratorTones.isEmpty;
  }

  void _loadReaderMenuData() {
    unawaited(_loadVideoMatch());
    unawaited(_loadReaderTones());
  }

  Future<void> _loadReaderTones() async {
    if (widget.localOnly ||
        widget.chapters.isEmpty ||
        _readerTones != null ||
        _readerTonesRequest != null) {
      return;
    }
    final now = DateTime.now();
    if (_readerTonesAttempt != null &&
        now.difference(_readerTonesAttempt!) < const Duration(seconds: 15)) {
      return;
    }
    _readerTonesAttempt = now;
    final request = _readerTonesRequest = BackendRequest();
    try {
      final tones = await ApiClient.instance.withCancellation(
        request,
        () => ApiClient.instance.bookTones(widget.bookId),
      );
      if (mounted && !request.isCancelled) {
        _setState(() => _readerTones = tones);
      }
    } catch (_) {
      // Unknown availability is retryable, not a copyright denial.
    } finally {
      if (identical(_readerTonesRequest, request)) _readerTonesRequest = null;
    }
  }
}
