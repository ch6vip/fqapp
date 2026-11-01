part of '../reader_page.dart';

/// Reader preferences, device/brightness control and the settings sheets.
extension _ReaderPagePreferences on _ReaderPageState {
  bool get _paged => _preferences.pageMode == ReaderPageMode.paged;

  /// 阅读器自己的书架条目（issue #103）：详情页传了原 item 就用它，否则按本页
  /// 已有的书籍字段兜底。书架 key 是 `kind:id`，这里固定 'book'——漫画走自己的
  /// 阅读器（kind 'manga'），两者在书架上本就是两条。
  MediaItem get _shelfEntry =>
      widget.shelfItem ??
      MediaItem(
        id: widget.bookId,
        title: widget.title,
        cover: widget.cover,
        author: '',
        badge: '',
        ep: '',
        kind: 'book',
      );

  /// 全局墨水屏模式覆盖阅读器显示预设（#15/#9）：开启时阅读器强制纯黑白，
  /// 不改用户保存的预设，关闭后恢复原预设。夜间切换等仍写保存的预设。
  ///
  /// 全局 OLED 纯黑同理：只在深色外观下生效，所以阅读背景强制到夜间预设
  ///（颜色再由 [ReaderThemeColors.isOled] 降到 #000000），退出深色后回到
  /// 原预设。
  ReaderThemePreset get _effectivePreset {
    if (einkModeNotifier.value) return ReaderThemePreset.eink;
    if (oledActive()) return ReaderThemePreset.dark;
    return _preferences.themePreset;
  }

  /// 排版用的偏好：墨水屏模式下把预设换成 eink，正文/标题才是 #000000。
  ///
  /// 页面背景早就走 [_effectivePreset]，但 [ReaderLayoutSpec] 的正文、标题
  /// 颜色和 [ReaderControls] 自己的读色都取自这里传入的 preferences。之前
  /// 两处直接传 [_preferences]，于是全局墨水屏开启后正文仍用用户保存预设的
  /// textColor（默认米白 #292724）——实测设备上正文主色 RGB(41,39,36)，
  /// 墨水屏把它量化成明显发灰的一档。保存的预设不动，关闭墨水屏即恢复。
  ReaderPreferences get _displayPreferences {
    if (einkModeNotifier.value) {
      return _preferences.copyWith(
        themePreset: ReaderThemePreset.eink,
        // 墨水屏最低 500 字重：Flutter 没有关亚像素抗锯齿的 API，
        // 加粗是唯一能用的笔画加深手段。
        fontWeight: einkEffectiveFontWeight(
          eink: true,
          fontWeight: _preferences.fontWeight,
        ),
      );
    }
    // OLED：正文 / 标题颜色同样要走夜间，否则排版层会继续用保存预设的浅色
    // 纸面正文色，在纯黑底上既刺眼又和背景对不上。
    if (oledActive()) {
      return _preferences.copyWith(themePreset: ReaderThemePreset.dark);
    }
    return _preferences;
  }

  /// 原生层（MainActivity.dispatchKeyEvent）拦截到音量键后回调：仅在阅读页
  /// 当前路由、未显示控制栏、已开启音量键翻页、且为分页模式时翻页。
  void _onVolumeKey(int direction) {
    if (!mounted ||
        !_routeCurrent ||
        _controlsVisible ||
        !_preferences.volumeKeyTurn ||
        !_paged) {
      return;
    }
    _takeOverListening();
    _stopAutoTurn();
    unawaited(_turnPage(direction));
  }

  /// 根据当前状态同步原生是否拦截音量键：仅当阅读页是当前路由、未显示控制栏、
  /// 已开启音量键翻页、且为分页模式时启用。其余情况放行系统音量。
  void _syncVolumeKeyEnabled() {
    unawaited(
      VolumeKeyService.instance.setEnabled(
        _routeCurrent &&
            _preferences.volumeKeyTurn &&
            !_controlsVisible &&
            _paged,
      ),
    );
  }

  void _syncSystemBars() {
    if (!_preferencesReady) return;
    unawaited(
      _device.setImmersive(
        _appActive &&
            (_routeCurrent || _ideasSheetOpen) &&
            widget.chapters.isNotEmpty,
        showStatusBar: _preferences.showSystemStatusBar,
      ),
    );
  }

  Future<void> _loadPreferences() async {
    ReaderPreferences preferences;
    try {
      preferences = await ReaderPreferences.load();
    } catch (_) {
      preferences = const ReaderPreferences();
    }
    if (!mounted) return;
    _setState(() {
      _preferences = preferences;
      _preferencesReady = true;
      if (preferences.themePreset != ReaderThemePreset.dark) {
        _dayTheme = preferences.themePreset;
      }
    });
    if (_controlsVisible) _loadReaderMenuData();
    _syncSystemBars();
    _syncVolumeKeyEnabled();
    await _loadFont(preferences.fontPath);
    if (mounted && _appActive) unawaited(_refreshDevice());
  }

  Future<void> _refreshDevice() async {
    if (!_preferencesReady || !_appActive || widget.chapters.isEmpty) return;
    final generation = ++_deviceGeneration;
    final status = await _device.start(
      followSystem: _preferences.followSystemBrightness,
      brightness: _preferences.brightness,
    );
    if (!mounted || generation != _deviceGeneration || !_appActive) return;
    _setState(() {
      _deviceAvailable = status != null;
      if (status != null) _deviceStatus = status;
    });
    if (status != null) {
      _deviceSubscription ??= _device.changes.listen((status) {
        if (mounted && _appActive) _setState(() => _deviceStatus = status);
      }, onError: (Object _) {});
    }
    // 进入阅读器即按偏好应用常亮(否则只有动过设置才生效)。
    unawaited(_device.keepScreenOn(_preferences.keepScreenOn));
  }

  Future<void> _loadFont(String path) async {
    final generation = ++_fontGeneration;
    try {
      final family = await ReaderFonts.load(path);
      if (!mounted || generation != _fontGeneration) return;
      _setState(() => _fontFamily = family);
    } on ReaderFontLimitException {
      if (!mounted || generation != _fontGeneration) return;
      _setState(() => _fontFamily = null);
      _showMessage('已导入字体过多，重启应用后可继续更换字体');
    } catch (_) {
      if (!mounted || generation != _fontGeneration) return;
      _setState(() {
        _fontFamily = null;
        _preferences = _preferences.copyWith(fontPath: '', fontName: '');
        _preferencesDirty = true;
      });
      _showMessage('字体无法读取，已使用系统字体');
    }
  }

  Future<ReaderFont?> _pickFont() async {
    final font = await _device.pickFont();
    if (font == null) return null;
    try {
      await ReaderFonts.load(font.path);
    } on ReaderFontLimitException {
      if (mounted) _showMessage('已导入字体过多，重启应用后可继续更换字体');
      return null;
    }
    return font;
  }

  Future<void> _savePreferences({bool applyKeepScreenOn = true}) async {
    if (applyKeepScreenOn) {
      unawaited(_device.keepScreenOn(_preferences.keepScreenOn));
    }
    if (!_preferencesReady || !_preferencesDirty) return;
    final snapshot = _preferences;
    _preferencesDirty = false;
    try {
      await snapshot.save();
    } catch (_) {
      _preferencesDirty = true;
      if (mounted) _showMessage('设置保存失败，请重试');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _changeBrightness(double value, {bool followSystem = false}) {
    _preferencesDirty = true;
    final generation = ++_brightnessGeneration;
    _setState(
      () => _preferences = _preferences.copyWith(
        brightness: value,
        followSystemBrightness: followSystem,
      ),
    );
    unawaited(
      _device.setBrightness(followSystem: followSystem, brightness: value).then(
        (applied) {
          if (!applied && mounted && generation == _brightnessGeneration) {
            _showMessage('暂时无法调整亮度，请重新进入阅读界面');
          }
        },
      ),
    );
  }

  void _toggleControls() {
    _stopAutoTurn();
    if (!_controlsVisible) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
    _setControlsVisible(!_controlsVisible);
    if (_controlsVisible) _loadReaderMenuData();
  }

  void _setControlsVisible(bool visible) {
    if (!visible) _cancelVideoOpen();
    _setState(() => _controlsVisibility.value = visible);
    _syncVolumeKeyEnabled();
  }

  /// 点击区域九宫格分发：按点按位置取九宫格动作执行。
  void _handleTapZone(Offset position, BoxConstraints constraints) {
    final action = readerTapZoneActionAt(
      zones: _preferences.tapZones,
      dx: position.dx,
      dy: position.dy,
      width: constraints.maxWidth,
      height: constraints.maxHeight,
    );
    switch (action) {
      case ReaderTapZoneAction.none:
        break;
      case ReaderTapZoneAction.menu:
        _toggleControls();
      case ReaderTapZoneAction.prevPage:
        _takeOverListening();
        unawaited(_turnPage(-1));
      case ReaderTapZoneAction.nextPage:
        _takeOverListening();
        unawaited(_turnPage(1));
      case ReaderTapZoneAction.prevChapter:
        unawaited(_prev());
      case ReaderTapZoneAction.nextChapter:
        unawaited(_next());
      case ReaderTapZoneAction.toc:
        unawaited(_showDirectory());
    }
  }

  void _previewPreferences(ReaderPreferences preferences) {
    if (!preferences.showVideoButton ||
        preferences.videoChapterSync != _preferences.videoChapterSync) {
      _cancelVideoOpen();
    }
    _captureScrollProgress(updateTextOffset: true);
    _preferencesDirty = true;
    final fontChanged = preferences.fontPath != _preferences.fontPath;
    final intervalChanged =
        preferences.einkRefreshInterval != _preferences.einkRefreshInterval;
    final joinChanged =
        preferences.scrollChapterMode != _preferences.scrollChapterMode;
    _setState(() {
      if (joinChanged) _chapterLayout = null;
      _preferences = preferences.normalized();
      if (_preferences.themePreset != ReaderThemePreset.dark) {
        _dayTheme = _preferences.themePreset;
      }
      // 刷新间隔改变时清零计数，避免沿用旧阈值导致久不刷新或立刻刷新。
      if (intervalChanged) _einkPageCounter = 0;
    });
    _syncSystemBars();
    if (fontChanged) unawaited(_loadFont(preferences.fontPath));
    if (_controlsVisible) unawaited(_loadVideoMatch());
  }

  Future<void> _showTextReplacement() => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => TextReplacementPage(store: _replacementStore),
    ),
  );

  Future<void> _showAppearanceSettings() async {
    // 设置面板不再收起阅读菜单：关闭后底部工具条仍在，用户不用再点一次。
    await showReaderSettingsSheet(
      context: context,
      initialValue: _preferences,
      onChanged: _previewPreferences,
      onPickFont: _pickFont,
      deviceAvailable: _deviceAvailable,
      systemBrightness: _deviceStatus.systemBrightness,
      onBrightness: _changeBrightness,
      onBrightnessEnd: () => unawaited(_savePreferences()),
      onFollowSystem: _followSystemBrightness,
      autoTurnActive: _autoTurnTimer != null,
      onAutoTurn: _toggleAutoTurn,
      einkOverride: einkModeNotifier.value,
      oledOverride: oledActive(),
      onTextReplacement: _showTextReplacement,
      onListeningSource: () => unawaited(_openListening()),
    );
    // 墨水屏：排版面板关闭后刷一次，清掉面板残影。
    _maybeEinkRefresh();
    await _savePreferences();
  }

  /// 跟随系统：在跟随与手动之间切换，亮度取当前系统值或用户值。
  void _followSystemBrightness() {
    _changeBrightness(
      _preferences.followSystemBrightness
          ? _deviceStatus.systemBrightness ?? _preferences.brightness
          : _preferences.brightness,
      followSystem: !_preferences.followSystemBrightness,
    );
    unawaited(_savePreferences());
  }

  void _toggleNightTheme() {
    // 全局墨水屏覆盖显示，点夜间不会有任何可见变化，先提示而非静默无响应。
    if (einkModeNotifier.value) {
      _showMessage('全局墨水屏已开启，先在 设置 → 外观 换成其它主题');
      return;
    }
    // OLED 同理：阅读背景被全局纯黑接管，点夜间看不出变化。
    if (oledActive()) {
      _showMessage('全局 OLED 纯黑已开启，先在 设置 → 外观 关闭它再切换背景');
      return;
    }
    final nextPreset = _preferences.themePreset == ReaderThemePreset.dark
        ? _dayTheme
        : ReaderThemePreset.dark;
    _previewPreferences(_preferences.copyWith(themePreset: nextPreset));
    unawaited(_savePreferences());
  }

  Future<void> _showDirectory() async {
    _setControlsVisible(false);
    Set<String> cachedIds = {};
    try {
      cachedIds = await _diskCache.cachedChapterIds(widget.bookId);
    } catch (_) {}
    if (!mounted) return;
    final preset = _effectivePreset;
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      // 与 ReaderSettingsSheetFrame 的顶部圆角一致，只用于裁掉越界内容。
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) => ReaderDirectorySheet(
        chapters: widget.chapters,
        currentIndex: _index,
        cachedIds: cachedIds,
        preset: preset,
      ),
    );
    // 墨水屏：目录关闭后刷一次（选了章节时切章本身也会刷一次，不叠加也无妨）。
    _maybeEinkRefresh();
    if (selected != null && mounted) await _jumpToChapter(selected);
  }

  Future<void> _showCache() {
    _setControlsVisible(false);
    final preset = _effectivePreset;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) => ChapterCacheSheet(
        book: _cachedBook,
        currentIndex: _index,
        cache: _diskCache,
        loader: _fetchChapter,
        onContentAvailable: _onChapterContentAvailable,
        shell: ChapterCacheShell.reader,
        readerPreset: preset,
      ),
    );
  }
}
