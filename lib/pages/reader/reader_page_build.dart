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
    // One decision per build, from the live scope, never from the animated
    // theme tokens. Archive keeps the Wenku8/glass chrome untouched.
    final classic = AppUiScope.isClassic(context);
    final windowPadding = MediaQuery.paddingOf(context);
    final overlayStyle = preset.isDark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    final surface = PopScope<Object?>(
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
            resizeToAvoidBottomInset: false,
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
                          // 「从本页听」= 从当前页第一段重新起播，引擎跟圆钮
                          // 听书同一个默认值（系统朗读时留在阅读页念，不再
                          // 硬吃作品音频），由 `_openListening` 统一分派。
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
                if (!classic &&
                    !_settingsPreviewActive &&
                    !_progressPreviewActive)
                  ReaderEdgeBlur(animation: _chrome)
                // The empty slot keeps the chrome elements in place across a
                // style switch, so the pager/menu subtree is never recreated.
                else
                  const SizedBox.shrink(),
                _menuEdge(
                  top: true,
                  child: _buildToolbar(preset, classic: classic),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedBuilder(
                    animation: _chrome,
                    child: _buildReaderControls(preset, classic: classic),
                    builder: (context, child) => Offstage(
                      offstage: _chrome.value == 0 || _settingsPreviewActive,
                      child: child,
                    ),
                  ),
                ),
                // 墨水屏软件白闪：盖全屏白帧，迫使 EPD 控制器全量刷新。
                if (_einkFlashVisible)
                  const Positioned.fill(child: ColoredBox(color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
    // Keep ancestry stable when paper changes while a panel is open: only the
    // performance policy changes, not the pager/scroll controller identity.
    return PerformanceScope(
      preferences: preset.isEink
          ? const PerformancePreferences(enabled: true)
          : PerformanceScope.of(context),
      explicitReduceMotion: preset.isEink || _reduceReaderMotion,
      child: surface,
    );
  }

  Widget _menuEdge({required bool top, required Widget child}) => Positioned(
    top: top ? 0 : null,
    bottom: top ? null : 0,
    left: 0,
    right: 0,
    child: ReaderChromeLayer(
      animation: _settingsPreviewActive || _progressPreviewActive
          ? const AlwaysStoppedAnimation(0)
          : _chrome,
      interactionThreshold: 0,
      slide: Offset(0, top ? -1 : 1),
      child: child,
    ),
  );

  /// Wenku8's transparent header rides above the progressive edge; fqapp-only
  /// actions move to a real overflow menu instead of squeezing the book title.
  /// The classic style gets its own solid, two-line header.
  Widget _buildToolbar(ReaderThemePreset preset, {required bool classic}) =>
      classic
      ? _buildClassicToolbar(preset)
      : Material(
          key: const ValueKey('reader-toolbar'),
          color: preset.isEink || MediaQuery.highContrastOf(context)
              ? preset.panelColor
              : Colors.transparent,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 88,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: GlassIconButton(
                        key: const ValueKey('reader-back-entry'),
                        icon: CupertinoIcons.back,
                        label: '返回书籍',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      widget.title,
                      key: const ValueKey('reader-header-book-title'),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: preset.textColor,
                        fontSize: 16,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: GlassIconButton(
                      key: const ValueKey('reader-header-listen'),
                      icon: CupertinoIcons.headphones,
                      label: '听书',
                      onPressed: _loading || _error != null
                          ? null
                          : () => unawaited(_openListening(fromPage: true)),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: GlassMenuAnchor(
                      child: Builder(
                        builder: (anchor) => GlassIconButton(
                          key: const ValueKey('reader-header-more'),
                          icon: CupertinoIcons.ellipsis,
                          label: '更多阅读操作',
                          onPressed: () =>
                              unawaited(_showReaderActions(anchor)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

  Widget _buildClassicToolbar(ReaderThemePreset preset) {
    // The shelf icon must follow shelf writes without rebuilding the page.
    return ValueListenableBuilder<int>(
      valueListenable: ShelfStore.instance.listenable,
      builder: (context, _, _) => ReaderClassicToolbar(
        preset: preset,
        title: widget.title,
        chapterNumber: _index + 1,
        showCache: !widget.localOnly,
        showComments:
            !_loading &&
            _error == null &&
            _ideas.total > 0 &&
            _chapterEndParagraph() != null,
        inShelf: inShelf(_shelfEntry),
        onBack: () => Navigator.of(context).pop(),
        onCache: () => unawaited(_showCache()),
        onComments: () =>
            unawaited(_showIdeas(focusParaIndex: _chapterEndParagraph())),
        onShelf: () => unawaited(toggleShelf(context, _shelfEntry)),
        onCollapse: _toggleControls,
      ),
    );
  }

  Future<void> _showReaderActions(BuildContext anchor) async {
    _readerPanelOpen = true;
    final action = await showGlassMenu<String>(
      context: anchor,
      reduceMotion: _reduceReaderMotion,
      builder: (menu) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.localOnly)
            GlassMenuItem(
              key: const ValueKey('reader-cache'),
              icon: CupertinoIcons.tray_arrow_down,
              label: '缓存',
              onPressed: () => Navigator.pop(menu, 'cache'),
            ),
          if (!_loading &&
              _error == null &&
              _ideas.total > 0 &&
              _chapterEndParagraph() != null)
            GlassMenuItem(
              key: const ValueKey('reader-toolbar-chapter-comments'),
              icon: CupertinoIcons.chat_bubble,
              label: '本章评论',
              order: 1,
              onPressed: () => Navigator.pop(menu, 'comments'),
            ),
          GlassMenuItem(
            key: const ValueKey('reader-shelf-button'),
            icon: inShelf(_shelfEntry)
                ? CupertinoIcons.bookmark_fill
                : CupertinoIcons.bookmark,
            label: inShelf(_shelfEntry) ? '已在书架' : '加入书架',
            order: 2,
            onPressed: () => Navigator.pop(menu, 'shelf'),
          ),
          GlassMenuItem(
            icon: CupertinoIcons.textformat,
            label: '阅读设置',
            order: 3,
            onPressed: () => Navigator.pop(menu, 'settings'),
          ),
          GlassMenuItem(
            icon: CupertinoIcons.chevron_up,
            label: '专注阅读 · 隐藏控件',
            order: 4,
            onPressed: () => Navigator.pop(menu, 'hide'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'cache':
        await _showCache();
      case 'comments':
        await _showIdeas(focusParaIndex: _chapterEndParagraph());
      case 'shelf':
        await toggleShelf(context, _shelfEntry);
      case 'settings':
        await _showAppearanceSettings();
      case 'hide':
        _setControlsVisible(false);
    }
  }

  Widget _buildReaderControls(
    ReaderThemePreset preset, {
    required bool classic,
  }) => Column(
    key: _bottomControlsKey,
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Visibility(
        visible: !_settingsPreviewActive && !_progressPreviewActive,
        maintainSize: true,
        maintainState: true,
        maintainAnimation: true,
        child: ReaderChromeLayer(
          animation: _chrome,
          interactionThreshold: 0,
          maintainSize: true,
          slide: const Offset(0, 1),
          clip: false,
          child: _buildReaderMenuPlayers(preset),
        ),
      ),
      ListenableBuilder(
        listenable: _scrollController,
        builder: (context, _) => classic
            // The archive dock runs its own chrome layers; the classic sheet is
            // one Material panel, so the same `_chrome` drives it from outside.
            // `maintainSize` keeps the measured height (and the selection bar's
            // clearance) identical while it slides, and reduce-motion/e-ink
            // already jump `_chrome` straight to its end value.
            ? ReaderChromeLayer(
                animation: _chrome,
                interactionThreshold: 0,
                maintainSize: true,
                slide: const Offset(0, 1),
                clip: false,
                child: ReaderClassicControls(
                  // Two progress meanings live in this sheet; see the widget.
                  key: const ValueKey('reader-classic-controls'),
                  preset: preset,
                  chapterIndex: _index,
                  chapterCount: widget.chapters.length,
                  chapterTitleAt: (index) => widget
                      .chapters[index.clamp(0, widget.chapters.length - 1)]
                      .title,
                  fraction: _chapterLocalFraction,
                  onPrevious: _index > 0 && !_loading ? _prev : null,
                  onNext: _index < widget.chapters.length - 1 && !_loading
                      ? _next
                      : null,
                  onSeekEnd: (index) => unawaited(_jumpToChapter(index)),
                  onPreview: _previewChapterFraction,
                  onCommitted: _commitChapterFraction,
                  onPreviewChanged: _setChapterPreview,
                  onDirectory: _showDirectory,
                  onBookmarks: _showBookmarks,
                  onFind: _loading || !_progressReady ? null : _showFind,
                  onNight: _toggleNightTheme,
                  onAppearance: _showAppearanceSettings,
                  onOperations: () => _showAppearanceSettings(
                    section: ReaderSettingsSection.operations,
                  ),
                  onAi: _currentAiView?.aiEnabled == true ? _showAiPanel : null,
                  aiLabel: _currentAiView?.hasCache == true
                      ? 'AI 已校对'
                      : 'AI 校对',
                ),
              )
            : ReaderControls(
                key: const ValueKey('reader-controls'),
                preferences: _displayPreferences,
                chapterIndex: _index,
                chapterTitle: _chapter.title,
                fraction: _chapterLocalFraction,
                animation: _settingsPreviewActive
                    ? const AlwaysStoppedAnimation(0)
                    : _chrome,
                previewing: _progressPreviewActive,
                onPrevious: _index > 0 && !_loading ? _prev : null,
                onNext: _index < widget.chapters.length - 1 && !_loading
                    ? _next
                    : null,
                onPreview: _previewChapterFraction,
                onCommitted: _commitChapterFraction,
                onPreviewChanged: _setChapterPreview,
                onDirectory: _showDirectory,
                onBookmarks: _showBookmarks,
                onNight: _toggleNightTheme,
                onAppearance: () => _showAppearanceSettings(
                  section: ReaderSettingsSection.appearance,
                ),
                onOperations: () => _showAppearanceSettings(
                  section: ReaderSettingsSection.operations,
                ),
                onFind: _loading || !_progressReady ? null : _showFind,
                onAi: _currentAiView?.aiEnabled == true ? _showAiPanel : null,
                aiLabel: _currentAiView?.hasCache == true ? 'AI 已校对' : 'AI 校对',
              ),
      ),
    ],
  );

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
          // 空版权页和暂不可用章节不应把整本书困在重试页。
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            children: [
              if (_index > 0)
                TextButton(onPressed: _prev, child: const Text('上一章')),
              TextButton(onPressed: _showDirectory, child: const Text('目录')),
              if (_index < widget.chapters.length - 1)
                TextButton(onPressed: _next, child: const Text('下一章')),
            ],
          ),
        ],
      ),
    ),
  );
}
