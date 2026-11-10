// Settings home.
//
// Layout ported from Wenku8_Flutter (revision ebcd7f1) `lib/pages.dart`
// SettingsPage: archive masthead + `FeatureEntry` section cards opening
// `ArchiveFeaturePage` option lists.
//
// Mechanical substitutions:
// - Upstream `LibraryState` settings are replaced by fqapp's preference
//   services; every fqapp setting, preference key and immediate-effect
//   behaviour is preserved (theme mode / e-ink / OLED, reading entry points,
//   listening, short drama playback, data and service pages).
// - `GlassSettingMenu` and the glass switch come from fqapp's vendored
//   `setting_menu.dart` / `glass_controls.dart`.
// - Upstream items fqapp does not have (force portrait, start page, combined
//   shelf, language, fonts, dictionaries, lane sync, widgets, frame rate,
//   low-performance mode) are intentionally absent, per the product
//   boundary: "do not add upstream settings fqapp lacks".
// - Haptics use fqapp's app-wide preference, shared by both UI styles (#303).
// - Windows keeps the existing two-pane `DesktopSettingsBody` inside the
//   archive shell so the desktop settings workflow is unchanged.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_theme.dart';
import '../services/app_theme_style.dart';
import '../services/app_style_tokens.dart';
import '../services/audio_preferences.dart';
import '../services/desktop_platform.dart';
import '../services/native_player.dart';
import '../services/player_layout_preferences.dart';
import '../services/player_preferences.dart';
import '../services/book_open_preferences.dart';
import '../services/drama_mute_preferences.dart';
import '../services/haptic_preferences.dart';
import '../services/library_store.dart';
import '../widgets/desktop_settings_body.dart';
import '../widgets/settings/settings_archive_rows.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/settings/classic_settings_icons.dart';
import '../widgets/wenku/wenku_ui.dart';
import 'about_page.dart';
import 'api_service_page.dart';
import 'cached_books_page.dart';
import 'cached_dramas_page.dart';
import 'library_backup_page.dart';
import 'settings_category_page.dart';
import 'system_tts_settings_page.dart';
import 'text_replacement_page.dart';
import 'theme_page.dart';
import 'ai_reading/settings/ai_settings_page.dart';

/// Settings home: a list of category entries (PiliPlus multi-level
/// navigation). Each category opens its own archive option page.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 开关读的是 ValueNotifier：先把持久化的值读出来，读到后自动重绘。
    unawaited(BookOpenPreferences.instance.load());
    final style = AppStyleTokens.of(context);
    final categories = <SettingsCategory>[
      SettingsCategory(
        icon: SettingsCategoryIcons.appearance,
        title: '外观',
        subtitle: HapticPreferences.supported
            ? '主题模式、振动反馈、播放页布局'
            : '主题模式、OLED 纯黑、播放页布局',
        // 用 builder 而不是固定 items：切到深色 / 切回浅色后，分类页重建
        // 时会重新判定，OLED 行不必退出重进就能出现或消失。
        // 播放页布局只在手机端有效（Windows 由 DesktopVideoChrome 承担）。
        itemsBuilder: (context) => [
          _themeModeItem(),
          if (HapticPreferences.supported) _hapticsItem(),
          if (isDarkAppearance(
            systemBrightness: MediaQuery.platformBrightnessOf(context),
          ))
            _oledModeItem(),
          if (!isWindowsDesktop) _playerLayoutItem(),
        ],
      ),
      SettingsCategory(
        icon: CupertinoIcons.paintbrush,
        title: '主题',
        subtitle: '经典主题、档案主题',
        pageBuilder: (_) => const ThemePage(),
        items: const [],
      ),
      SettingsCategory(
        icon: SettingsCategoryIcons.reading,
        title: '阅读',
        subtitle: '阅读入口、正文替换、AI 阅读优化',
        items: [
          _shelfDirectReaderItem(),
          _discoverDirectReaderItem(),
          SettingsItem(
            icon: CupertinoIcons.textformat,
            title: '正文替换',
            subtitle: '自定义普通文本或正则替换规则',
            onTap: (context, _) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TextReplacementPage()),
            ),
          ),
          SettingsItem(
            icon: LucideIcons.sparkles,
            title: 'AI 阅读优化',
            subtitle: '校对、反馈保护、预校对与预算',
            onTap: (context, _) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AiSettingsPage()),
            ),
          ),
        ],
      ),
      SettingsCategory(
        icon: SettingsCategoryIcons.listening,
        title: '听书',
        subtitle: '后台播放、通知栏控制与系统朗读',
        items: [
          _backgroundAudioItem(),
          if (!isWindowsDesktop) _audioRateEngineItem(),
          SettingsItem(
            icon: CupertinoIcons.mic,
            title: '系统朗读',
            subtitle: '选择 TTS 引擎与语速，支持本地书',
            onTap: (context, _) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SystemTtsSettingsPage()),
            ),
          ),
        ],
      ),
      SettingsCategory(
        icon: SettingsCategoryIcons.drama,
        title: '短剧',
        subtitle: '播放',
        items: [
          _muteWhenColdStartItem(),
          if (!isWindowsDesktop) _floatingWindowItem(),
          if (!isWindowsDesktop) _videoDecoderItem(),
        ],
      ),
      SettingsCategory(
        icon: SettingsCategoryIcons.data,
        title: '数据',
        subtitle: '备份与恢复、缓存、阅读与播放历史',
        items: [
          SettingsItem(
            icon: CupertinoIcons.folder,
            title: '备份与导入',
            subtitle: '本机备份、恢复与番茄书架导入',
            onTap: (context, _) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LibraryBackupPage()),
            ),
          ),
          SettingsItem(
            icon: CupertinoIcons.book,
            title: '小说离线缓存',
            subtitle: '离线续读、查看占用和清理缓存',
            onTap: (context, _) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CachedBooksPage()),
            ),
          ),
          SettingsItem(
            icon: CupertinoIcons.play_rectangle,
            title: '短剧离线缓存',
            subtitle: '短剧下载、离线播放和清理缓存',
            onTap: (context, _) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CachedDramasPage()),
            ),
          ),
          _clearHistItem(),
        ],
      ),
      SettingsCategory(
        icon: SettingsCategoryIcons.service,
        title: '服务',
        subtitle: '本地接口地址与可用端点',
        pageBuilder: (_) => const ApiServicePage(),
        items: const [],
      ),
      SettingsCategory(
        icon: SettingsCategoryIcons.about,
        title: '关于',
        subtitle: '版本与应用信息',
        pageBuilder: (_) => const AboutPage(),
        items: const [],
      ),
    ];

    // Keep the desktop body at one element path while switching themes: its
    // nested Navigator owns the theme picker and must not be recreated mid-tap.
    if (isWindowsDesktop) {
      return WenkuPage(
        header: _header(context),
        child: Padding(
          padding: EdgeInsets.only(
            top:
                MediaQuery.paddingOf(context).top + FrostedHeader.toolbarHeight,
          ),
          child: DesktopSettingsBody(
            categories: style.isClassic
                ? [
                    for (final category in categories)
                      _classicCategory(category),
                  ]
                : categories,
          ),
        ),
      );
    }

    if (style.isClassic) {
      // Restore the single grouped card from f329399, not rounded archive
      // FeatureEntry cards. The category models still own all current actions.
      final classicCategories = [
        for (final category in categories) _classicCategory(category),
      ];
      return SettingsScaffold(
        title: '设置',
        body: ListView(
          key: const PageStorageKey('settings-classic'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            SettingsGroupCard(
              children: [
                for (final category in classicCategories)
                  SettingsRow(
                    key: ValueKey('settings-entry-${category.title}'),
                    icon: category.icon,
                    iconTile: true,
                    title: category.title,
                    subtitle: category.title == '主题'
                        ? AppThemeStyleStore.instance.value.label
                        : category.subtitle,
                    onTap: () => _openCategory(context, category),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    return WenkuPage(
      header: _header(context),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            key: const PageStorageKey('settings'),
            padding: featurePadding(context),
            children: [
              for (var index = 0; index < categories.length; index++) ...[
                if (index > 0) SizedBox(height: style.entryGap),
                FeatureEntry(
                  key: ValueKey('settings-entry-${categories[index].title}'),
                  title: categories[index].title,
                  subtitle: categories[index].subtitle,
                  icon: categories[index].icon,
                  // The current theme is a value, not a control: it belongs
                  // next to the chevron, and the chevron has to land in the
                  // same place as every other row's.
                  trailingText: categories[index].title == '主题'
                      ? AppThemeStyleStore.instance.value.label
                      : null,
                  onTap: () => _openCategory(context, categories[index]),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static SettingsCategory _classicCategory(SettingsCategory category) =>
      SettingsCategory(
        icon: classicSettingsIcon(category.title, category.icon),
        title: category.title,
        subtitle: category.subtitle,
        items: category.items,
        itemsBuilder: category.itemsBuilder,
        pageBuilder: category.pageBuilder,
      );

  /// Settings is opened as a route (the “我的” entry and the Windows rail),
  /// so the upstream tab-style [ArchiveMasthead] needs a way back. The
  /// masthead stays untouched; the back button only appears when this page
  /// actually sits on top of another route.
  static Widget _header(BuildContext context) {
    const masthead = ArchiveMasthead(title: '设置', code: '04 / SYSTEM PROFILE');
    if (!Navigator.of(context).canPop()) {
      return const Align(alignment: Alignment.centerLeft, child: masthead);
    }
    return Row(
      children: [
        GlassIconButton(
          icon: CupertinoIcons.back,
          label: '返回',
          onPressed: () => Navigator.maybePop(context),
        ),
        const SizedBox(width: 8),
        const Expanded(child: masthead),
      ],
    );
  }

  static void _openCategory(BuildContext context, SettingsCategory cat) {
    final pageBuilder = cat.pageBuilder;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            pageBuilder ??
            (_) => SettingsCategoryPage(
              title: cat.title,
              items: cat.items,
              itemsBuilder: cat.itemsBuilder,
            ),
      ),
    );
  }

  // ── 外观 ──────────────────────────────────────────────────────────────

  /// 主题模式（参考 legado 的 themeMode）：跟随系统 / 浅色 / 深色 / 墨水屏
  /// 四选一，墨水屏既然也是一种外观就并进这个入口，不再单列一个开关。
  SettingsItem _themeModeItem() => SettingsItem(
    icon: CupertinoIcons.moon_stars,
    title: '主题模式',
    rowBuilder: (context) => ListenableBuilder(
      listenable: Listenable.merge([themeModeNotifier, einkModeNotifier]),
      builder: (context, _) => GlassSettingMenu<_AppearanceChoice>(
        icon: CupertinoIcons.moon_stars,
        label: '主题模式',
        value: _appearance,
        options: {
          for (final choice in _AppearanceChoice.values) choice: choice.label,
        },
        reduceMotion: MediaQuery.disableAnimationsOf(context),
        onChanged: (choice) => _setAppearance(context, choice),
      ),
    ),
  );

  /// 当前外观：墨水屏优先级最高（深色反白在墨水屏上残影最重），
  /// 没有开墨水屏时再按深色模式取值。
  _AppearanceChoice get _appearance {
    if (einkModeNotifier.value) return _AppearanceChoice.eink;
    switch (themeModeNotifier.value) {
      case ThemeMode.light:
        return _AppearanceChoice.light;
      case ThemeMode.dark:
        return _AppearanceChoice.dark;
      case ThemeMode.system:
        return _AppearanceChoice.system;
    }
  }

  /// 主题模式落盘：浅色 / 深色 / 跟随系统写 theme_mode，墨水屏另存
  /// eink_mode。选墨水屏时保留原先的浅色 / 深色值，退出墨水屏能回到它。
  Future<void> _setAppearance(
    BuildContext context,
    _AppearanceChoice choice,
  ) async {
    final eink = choice == _AppearanceChoice.eink;
    final mode = switch (choice) {
      _AppearanceChoice.system => ThemeMode.system,
      _AppearanceChoice.light => ThemeMode.light,
      _AppearanceChoice.dark => ThemeMode.dark,
      _AppearanceChoice.eink => themeModeNotifier.value,
    };
    einkModeNotifier.value = eink;
    themeModeNotifier.value = mode;
    // 墨水屏恒为浅色外观，OLED 纯黑无从生效：一并关掉，否则以后切回深色
    // 会被上一次的纯黑默默接管。
    if (eink) oledModeNotifier.value = false;
    try {
      final sp = await SharedPreferences.getInstance();
      final modeSaved = await sp.setString(themeModeKey, mode.name);
      final einkSaved = await sp.setBool(einkModeKey, eink);
      final oledSaved = eink ? await sp.setBool(oledModeKey, false) : true;
      if (!modeSaved || !einkSaved || !oledSaved) {
        throw StateError('Appearance preference was not saved');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('外观已更新，但未能保存')));
      }
    }
  }

  SettingsItem _hapticsItem() => SettingsItem(
    icon: CupertinoIcons.waveform,
    title: '振动反馈',
    rowBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: HapticPreferences.instance,
      builder: (context, value, _) => SettingsToggleRow(
        key: const ValueKey('settings-haptics'),
        icon: CupertinoIcons.waveform,
        title: '振动反馈',
        description: '控制按钮、书架与播放手势的振动，不影响系统键盘',
        value: value,
        onChanged: (enabled) async {
          final saved = await HapticPreferences.instance.setEnabled(enabled);
          if (!saved && context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('未能完整应用或保存振动设置，请重试')));
          }
        },
      ),
    ),
  );

  /// OLED 纯黑：画布纯黑省电，卡片 / 弹层保持近黑，靠描边撑住层次。
  /// 只在深色外观下显示（浅色 / 墨水屏没有可省的黑）。
  SettingsItem _oledModeItem() => SettingsItem(
    icon: CupertinoIcons.device_phone_portrait,
    title: 'OLED 纯黑',
    rowBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: oledModeNotifier,
      builder: (context, value, _) => SettingsToggleRow(
        icon: CupertinoIcons.device_phone_portrait,
        title: 'OLED 纯黑',
        description: '大面积纯黑省电，仅在深色外观下生效',
        value: value,
        onChanged: (v) => _setOledMode(context, v),
      ),
    ),
  );

  Future<void> _setOledMode(BuildContext context, bool value) async {
    oledModeNotifier.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      if (!await sp.setBool(oledModeKey, value)) {
        throw StateError('OLED preference was not saved');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('OLED 纯黑已更新，但未能保存')));
      }
    }
  }

  /// 播放页布局：沉浸式 / 横屏片源自动分屏 / 始终分屏。
  ///
  /// 只影响短剧播放页，Windows 隐藏（桌面已有 304dp 停靠选集面板）。
  SettingsItem _playerLayoutItem() => SettingsItem(
    icon: CupertinoIcons.rectangle_split_3x1,
    title: '播放页布局',
    rowBuilder: (context) => ValueListenableBuilder<PlayerLayoutMode>(
      valueListenable: PlayerLayoutPreferences.mode,
      builder: (context, value, _) => GlassSettingMenu<PlayerLayoutMode>(
        icon: CupertinoIcons.rectangle_split_3x1,
        label: '播放页布局',
        value: value,
        // 行内保留短标签（「自动分屏」），弹层里仍是完整说明性标签。
        valueLabel: value.shortLabel,
        options: {for (final mode in PlayerLayoutMode.values) mode: mode.label},
        reduceMotion: MediaQuery.disableAnimationsOf(context),
        onChanged: (mode) => _setPlayerLayout(context, mode),
      ),
    ),
  );

  Future<void> _setPlayerLayout(
    BuildContext context,
    PlayerLayoutMode value,
  ) async {
    final previous = PlayerLayoutPreferences.mode.value;
    if (previous == value) return;
    PlayerLayoutPreferences.mode.value = value;
    try {
      if (!await PlayerLayoutPreferences.save(value)) {
        throw StateError('Player layout preference was not saved');
      }
    } catch (_) {
      // 落盘失败就退回原选择，避免界面显示与实际不一致。
      PlayerLayoutPreferences.mode.value = previous;
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未能保存播放页布局，已恢复原设置')));
      }
    }
  }

  // ── 阅读 ──────────────────────────────────────────────────────────────

  /// issue #19 第 3 条：点书跳过详情页，直接按上次进度进阅读器（小说/漫画）。
  /// 切后台悬浮窗播放（#24，默认关）：开启且已授予悬浮窗权限时，切到
  /// 后台或锁屏用悬浮小窗继续播；关闭则切后台暂停（现有行为）。
  /// 开启时若无权限，先打开系统设置让用户授予，授予后回来再点一次。
  SettingsItem _floatingWindowItem() => SettingsItem(
    icon: CupertinoIcons.rectangle_on_rectangle,
    title: '切后台悬浮窗播放',
    rowBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: PlayerPreferences.floatingWindow,
      builder: (context, value, _) => SettingsToggleRow(
        icon: CupertinoIcons.rectangle_on_rectangle,
        title: '切后台悬浮窗播放',
        description: '切到后台或锁屏时用悬浮小窗继续播放，需要悬浮窗权限',
        value: value,
        // 系统授权页期间不能先把开关画成「开」；授权回来后才跟随偏好翻转。
        optimistic: false,
        onChanged: (enabled) => _setFloatingWindow(context, enabled),
      ),
    ),
  );

  Future<void> _setFloatingWindow(BuildContext context, bool enabled) async {
    if (!enabled) {
      await PlayerPreferences.setFloatingWindow(false);
      return;
    }
    if (await NativePlayer.canDrawOverlays()) {
      await PlayerPreferences.setFloatingWindow(true);
      return;
    }
    await NativePlayer.requestOverlayPermission();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请在系统设置中允许“显示在其他应用的上层”，然后回来再开启')),
      );
    }
  }

  /// 默认关＝现有行为（先进详情页）。听书/短剧与加载失败时仍停留在详情页。
  ///
  /// 书架的「我的书」和发现入口分成两条（issue #103）：书架里的书点开多半是
  /// 接着读，首页/搜索里的书往往还要先看简介，一条全局开关会让两边互相干扰。
  SettingsItem _shelfDirectReaderItem() => SettingsItem(
    icon: CupertinoIcons.book,
    title: '书架点书直接进入阅读',
    rowBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: BookOpenPreferences.instance.shelfDirectReader,
      builder: (context, value, _) => SettingsToggleRow(
        icon: CupertinoIcons.book,
        title: '书架点书直接进入阅读',
        description: '在书架、阅读历史里点书时跳过详情页，接着上次进度读',
        value: value,
        onChanged: (v) => BookOpenPreferences.instance.setShelfDirectReader(v),
      ),
    ),
  );

  SettingsItem _discoverDirectReaderItem() => SettingsItem(
    icon: CupertinoIcons.search,
    title: '首页与搜索点书直接进入阅读',
    rowBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: BookOpenPreferences.instance.discoverDirectReader,
      builder: (context, value, _) => SettingsToggleRow(
        icon: CupertinoIcons.search,
        title: '首页与搜索点书直接进入阅读',
        description: '在首页、搜索、榜单、作者页等入口点书时跳过详情页',
        value: value,
        onChanged: (v) =>
            BookOpenPreferences.instance.setDiscoverDirectReader(v),
      ),
    ),
  );

  // ── 听书 ──────────────────────────────────────────────────────────────

  SettingsItem _backgroundAudioItem() => SettingsItem(
    icon: CupertinoIcons.headphones,
    title: '后台听书与保活',
    rowBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: AudioPreferences.instance.backgroundPlayback,
      builder: (context, value, _) => SettingsToggleRow(
        icon: CupertinoIcons.headphones,
        title: '后台听书与保活',
        description: '切到后台或锁屏时继续播放，并在通知栏常驻控制卡片',
        value: value,
        onChanged: (v) => AudioPreferences.instance.setBackgroundPlayback(v),
      ),
    ),
  );

  /// 听书倍速的变速实现（issue #129）：默认交给系统混音器，高倍速下明显
  /// 没那么「电音」；内建 Sonic 作为厂商实现异常时的回退档。
  ///
  /// 与「视频解码器」同理：audio sink 在 build 时定型，新建播放器才生效。
  SettingsItem _audioRateEngineItem() => SettingsItem(
    icon: CupertinoIcons.speedometer,
    title: '听书变速引擎',
    rowBuilder: (context) => ValueListenableBuilder<AudioRateEngine>(
      valueListenable: AudioPreferences.instance.rateEngine,
      builder: (context, value, _) => GlassSettingMenu<AudioRateEngine>(
        icon: CupertinoIcons.speedometer,
        label: '听书变速引擎',
        value: value,
        options: {
          for (final engine in AudioRateEngine.values) engine: engine.label,
        },
        reduceMotion: MediaQuery.disableAnimationsOf(context),
        onChanged: AudioPreferences.instance.setRateEngine,
      ),
    ),
  );

  // ── 短剧 ──────────────────────────────────────────────────────────────

  /// 官方设置项「开启应用时默认静音」（`GlobalMuteConfig` 标题，持久层
  /// `open_mute_when_cold_start`，默认 false＝有声起播）。
  SettingsItem _muteWhenColdStartItem() => SettingsItem(
    icon: CupertinoIcons.volume_off,
    title: '开启应用时默认静音',
    rowBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: DramaMutePreferences.instance.muteWhenColdStart,
      builder: (context, value, _) => SettingsToggleRow(
        icon: CupertinoIcons.volume_off,
        title: '开启应用时默认静音',
        description: '进入短剧时静音播放，可在播放页取消',
        value: value,
        onChanged: DramaMutePreferences.instance.set,
      ),
    ),
  );

  /// 视频解码器（issue #92）：硬解异常的机型可以手动切软解。
  ///
  /// 只有**新起的播放器**会采用新设置——ExoPlayer 的 renderer 在 build 时
  /// 定型，所以行内说明写明需重新进入播放页。
  SettingsItem _videoDecoderItem() => SettingsItem(
    icon: CupertinoIcons.videocam,
    title: '视频解码器',
    rowBuilder: (context) => const _VideoDecoderMenu(),
  );

  // ── 数据 ──────────────────────────────────────────────────────────────

  SettingsItem _clearHistItem() => SettingsItem(
    icon: CupertinoIcons.trash,
    title: '清空历史',
    subtitle: '删除全部阅读/播放历史与累计时长',
    onTap: (context, setState) => _confirmClear(
      context,
      '清空历史',
      '确定清空全部阅读/播放历史与累计时长吗？',
      LibraryStore.instance.clearReadingData,
    ),
  );

  Future<void> _confirmClear(
    BuildContext context,
    String title,
    String message,
    Future<void> Function() action,
  ) async {
    final ok = await showSettingsConfirmDialog(
      context: context,
      title: title,
      message: message,
      confirmLabel: '清空',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    try {
      await action();
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已清空')));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('清空失败，请重试')));
      }
    }
  }
}

/// 视频解码器选择行：先读出持久化值，选择后把行内值同步为新选择。
///
/// Kept stateful so a save that only updates the decoder cache rebuilds the
/// selector; the upstream `StateSetter` refresh pattern is not needed here.
class _VideoDecoderMenu extends StatefulWidget {
  const _VideoDecoderMenu();

  @override
  State<_VideoDecoderMenu> createState() => _VideoDecoderMenuState();
}

class _VideoDecoderMenuState extends State<_VideoDecoderMenu> {
  VideoDecoderPreference _value = DecoderPreferenceCache.current;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await PlayerPreferences.loadVideoDecoder();
      if (mounted) setState(() => _value = value);
    } catch (_) {
      // Keep the in-memory default when disk cannot be read.
    }
  }

  Future<void> _save(BuildContext context, VideoDecoderPreference value) async {
    if (value == _value) return;
    try {
      await DecoderPreferenceCache.set(value);
      if (mounted) setState(() => _value = value);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('解码器设置未能保存')));
      }
    }
  }

  @override
  Widget build(BuildContext context) =>
      GlassSettingMenu<VideoDecoderPreference>(
        icon: CupertinoIcons.videocam,
        label: '视频解码器',
        value: _value,
        options: {
          for (final value in VideoDecoderPreference.values) value: value.label,
        },
        reduceMotion: MediaQuery.disableAnimationsOf(context),
        onChanged: (value) => _save(context, value),
      );
}

/// 主题模式的可选项：三种深浅色模式 + 墨水屏。墨水屏本不是 ThemeMode，
/// 但用户眼里它就是第四种外观，所以放进同一个选择器（同 legado）。
enum _AppearanceChoice {
  system('跟随系统'),
  light('浅色'),
  dark('深色'),
  eink('墨水屏');

  const _AppearanceChoice(this.label);

  final String label;
}
