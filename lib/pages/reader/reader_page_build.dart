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
    // 墨水屏：顶栏、段落选择条与菜单里的玻璃控件都在这个作用域下，
    // 实时折射在 EPD 上会留灰阶残影，统一退回轻量不透明底板。
    return preset.isEink
        ? PerformanceScope(
            preferences: const PerformancePreferences(enabled: true),
            explicitReduceMotion: true,
            child: surface,
          )
        : surface;
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
            child: FadeTransition(
              opacity: animation,
              // 上游 ReaderChromeLayer 的入场是「滑入 + 轻微放大」；这里保留
              // fqapp 的 AnimatedSwitcher 路由行为，补上同样的缩放。
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.96, end: 1).animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
                child: child,
              ),
            ),
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

  /// 上游阅读页顶栏：左右玻璃圆钮夹一条居中的书名。fqapp 的缓存 / 本章评论 /
  /// 书架 / 收起动作都保留成右侧玻璃钮。
  Widget _buildToolbar(ReaderThemePreset preset) => Material(
    key: const ValueKey('reader-toolbar'),
    color: preset.panelColor,
    elevation: 0,
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: preset.borderColor)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Row(
            children: [
              SizedBox(
                width: 46,
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
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
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
              ),
              if (!widget.localOnly)
                ReaderCacheButton(preset: preset, onTap: _showCache),
              if (!_loading &&
                  _error == null &&
                  _ideas.total > 0 &&
                  _chapterEndParagraph() != null)
                GlassIconButton(
                  key: const ValueKey('reader-toolbar-chapter-comments'),
                  icon: CupertinoIcons.chat_bubble,
                  label: '本章评论',
                  color: preset.textColor,
                  onPressed: () => unawaited(
                    _showIdeas(focusParaIndex: _chapterEndParagraph()),
                  ),
                ),
              ValueListenableBuilder<int>(
                valueListenable: ShelfStore.instance.listenable,
                builder: (context, _, _) {
                  final inShelfNow = inShelf(_shelfEntry);
                  return GlassIconButton(
                    key: const ValueKey('reader-shelf-button'),
                    icon: inShelfNow
                        ? CupertinoIcons.bookmark_fill
                        : CupertinoIcons.bookmark,
                    label: inShelfNow ? '已在书架' : '加入书架',
                    color: preset.textColor,
                    onPressed: () =>
                        unawaited(toggleShelf(context, _shelfEntry)),
                  );
                },
              ),
              GlassIconButton(
                key: const ValueKey('reader-collapse-menu'),
                icon: CupertinoIcons.chevron_up,
                label: '收起阅读菜单',
                color: preset.textColor,
                onPressed: _toggleControls,
              ),
            ],
          ),
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
          onAi: _aiView?.aiEnabled == true ? _showAiPanel : null,
          aiLabel: _aiView?.hasCache == true ? 'AI 已校对' : 'AI 校对',
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
