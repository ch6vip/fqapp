part of '../reader_page.dart';

/// Reader scaffold: desktop chrome, surface, toolbar and error view.
extension _ReaderPageBuild on _ReaderPageState {
  Widget _buildReader(BuildContext context) {
    if (!isWindowsDesktop) return _buildReaderSurface(context);
    return LayoutBuilder(
      builder: (context, bounds) => ColoredBox(
        color: _effectivePreset.backgroundColor,
        child: Row(
          children: [
            if (bounds.maxWidth >= 1000)
              DesktopChapterSidebar(
                chapters: widget.chapters,
                currentIndex: _index,
                onSelected: (index) => unawaited(_jumpToChapter(index)),
              ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 880),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Focus(
                        autofocus: true,
                        onKeyEvent: (node, event) {
                          if (event is! KeyDownEvent ||
                              FocusManager.instance.primaryFocus?.context
                                      ?.findAncestorWidgetOfExactType<
                                        EditableText
                                      >() !=
                                  null) {
                            return KeyEventResult.ignored;
                          }
                          final key = event.logicalKey;
                          if ([
                            LogicalKeyboardKey.arrowRight,
                            LogicalKeyboardKey.pageDown,
                          ].contains(key)) {
                            unawaited(_turnPage(1));
                            return KeyEventResult.handled;
                          }
                          if ([
                            LogicalKeyboardKey.arrowLeft,
                            LogicalKeyboardKey.pageUp,
                          ].contains(key)) {
                            unawaited(_turnPage(-1));
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: Listener(
                          onPointerSignal: _desktopScroll,
                          child: _buildReaderSurface(context),
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ValueListenableBuilder<double>(
                            valueListenable: DesktopPlatform.readerBrightness,
                            builder: (_, brightness, _) => ColoredBox(
                              color: Colors.black.withValues(
                                alpha: 1 - brightness,
                              ),
                            ),
                          ),
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
  }

  Widget _buildReaderSurface(BuildContext context) {
    final preset = _effectivePreset;
    final windowPadding = MediaQuery.paddingOf(context);
    final overlayStyle = preset.isDark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    return PopScope<Object?>(
      canPop: !_controlsVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _controlsVisible) _toggleControls();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle.copyWith(
          statusBarColor: preset.backgroundColor,
          systemNavigationBarColor: preset.backgroundColor,
        ),
        child: Theme(
          data: preset.theme(Theme.of(context)),
          child: Scaffold(
            backgroundColor: preset.backgroundColor,
            body: Stack(
              fit: StackFit.expand,
              children: [
                SafeArea(
                  child: Column(
                    children: [
                      if (_preferences.readingInfoMode ==
                          ReaderInfoMode.detailed)
                        GestureDetector(
                          onTap: _toggleControls,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: preset.mutedTextColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Flexible(
                                  child: Text(
                                    _chapter.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: TextStyle(
                                      color: preset.mutedTextColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Expanded(
                        child: ReaderPlayerPillHost(
                          bookId: widget.bookId,
                          preset: preset,
                          animate: !einkModeNotifier.value,
                          controlsVisible: _controlsVisible,
                          highlightOnScreen: () => readerNarrationOnScreen(
                            layout: _chapterLayout,
                            range: _narrationRange,
                            paged: _paged,
                            pageIndex: _pageIndex,
                            scrollController: _scrollController,
                            scrollOffset: _joined
                                ? _joinedKey.currentState?.position?.scroll
                                : null,
                          ),
                          normalPage: () => readerSyncPillNormalPage(
                            layout: _chapterLayout,
                            paged: _paged,
                            pageIndex: _pageIndex,
                          ),
                          onReturnOriginalProgress: _returnToOriginalProgress,
                          onListenFromPage: () =>
                              unawaited(_openListening(fromPage: true)),
                          viewportChanges: _scrollController,
                          footerBuilder: _preferences.showReadingInfo
                              ? (player) => ListenableBuilder(
                                  listenable: _scrollController,
                                  builder: (context, _) => ReaderStatusBar(
                                    playerControl: player,
                                    key: const ValueKey('reader-status-bar'),
                                    preset: preset,
                                    compact:
                                        _preferences.readingInfoMode ==
                                        ReaderInfoMode.compact,
                                    status: _deviceStatus,
                                    progress: _chapterProgress(),
                                    chapterIndex: _index,
                                    chapterCount: widget.chapters.length,
                                    paged: _paged,
                                    pageIndex: _chapterLayout == null
                                        ? null
                                        : _pageIndex,
                                    pageCount: _chapterLayout?.pages.length,
                                  ),
                                )
                              : null,
                          child: SizedBox.expand(
                            key: _viewportKey,
                            child: _buildContent(preset, windowPadding),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _menuEdge(top: true, child: _buildToolbar(preset)),
                _menuEdge(top: false, child: _buildReaderControls(preset)),
                // 墨水屏软件白闪：盖全屏白帧，迫使 EPD 控制器全量刷新。
                if (_einkFlashVisible)
                  const Positioned.fill(child: ColoredBox(color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuEdge({required bool top, required Widget child}) => Positioned(
    top: top ? 0 : null,
    bottom: top ? null : 0,
    left: 0,
    right: 0,
    child: IgnorePointer(
      ignoring: !_controlsVisible,
      child: ExcludeSemantics(
        excluding: !_controlsVisible,
        child: AnimatedSwitcher(
          // 墨水屏：菜单滑入/淡出动画也会留残影，直接跳变。
          duration: einkModeNotifier.value
              ? Duration.zero
              : const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween<Offset>(
              begin: Offset(0, top ? -1 : 1),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
            children: [...previousChildren, ?currentChild],
          ),
          child: _controlsVisible ? child : const SizedBox.shrink(),
        ),
      ),
    ),
  );

  Widget _buildToolbar(ReaderThemePreset preset) => Material(
    key: const ValueKey('reader-toolbar'),
    color: preset.panelColor,
    elevation: 2,
    shadowColor: Colors.black12,
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            IconButton(
              tooltip: '返回书籍',
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(LucideIcons.arrow_left, color: preset.textColor),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: preset.textColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '正在阅读 · 第 ${_index + 1} 章',
                    style: TextStyle(
                      color: preset.mutedTextColor,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (!widget.localOnly)
              ReaderCacheButton(preset: preset, onTap: _showCache),
            if (!_loading &&
                _error == null &&
                _ideas.total > 0 &&
                _chapterEndParagraph() != null)
              IconButton(
                key: const ValueKey('reader-toolbar-chapter-comments'),
                tooltip: '本章评论',
                onPressed: () => unawaited(
                  _showIdeas(focusParaIndex: _chapterEndParagraph()),
                ),
                icon: Icon(LucideIcons.message_circle, color: preset.textColor),
              ),
            ValueListenableBuilder<int>(
              valueListenable: ShelfStore.instance.listenable,
              builder: (context, _, _) {
                final inShelfNow = inShelf(_shelfEntry);
                return IconButton(
                  key: const ValueKey('reader-shelf-button'),
                  tooltip: inShelfNow ? '已在书架' : '加入书架',
                  onPressed: () => unawaited(toggleShelf(context, _shelfEntry)),
                  icon: Icon(
                    inShelfNow
                        ? LucideIcons.bookmark_check
                        : LucideIcons.bookmark_plus,
                    color: preset.textColor,
                  ),
                );
              },
            ),
            IconButton(
              tooltip: '收起阅读菜单',
              onPressed: _toggleControls,
              icon: Icon(LucideIcons.chevron_up, color: preset.textColor),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildReaderControls(ReaderThemePreset preset) {
    final seekValue = _chapterSeekValue ?? _index.toDouble();
    final previewIndex = seekValue.round().clamp(0, widget.chapters.length - 1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildReaderMenuPlayers(preset),
        ReaderControls(
          key: const ValueKey('reader-controls'),
          preferences: _displayPreferences,
          chapterIndex: previewIndex,
          chapterCount: widget.chapters.length,
          chapterTitle: widget.chapters[previewIndex].title,
          seekValue: seekValue,
          onPrevious: _index > 0 ? _prev : null,
          onNext: _index < widget.chapters.length - 1 ? _next : null,
          onSeek: (value) => _setState(() => _chapterSeekValue = value),
          onSeekEnd: (value) {
            _setState(() => _chapterSeekValue = null);
            _jumpToChapter(value.round());
          },
          onDirectory: _showDirectory,
          onNight: _toggleNightTheme,
          onAppearance: _showAppearanceSettings,
        ),
      ],
    );
  }

  Widget _errorView({Color? textColor}) => Center(
    child: SingleChildScrollView(
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
          OutlinedButton(
            onPressed: () => _load(startAtEnd: _requestedStartAtEnd),
            child: const Text('重试'),
          ),
        ],
      ),
    ),
  );
}
