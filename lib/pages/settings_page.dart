import '../services/desktop_platform.dart';
import '../widgets/desktop_settings_body.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_theme.dart';
import '../services/audio_preferences.dart';
import '../services/native_player.dart';
import '../services/player_preferences.dart';
import '../services/player_layout_preferences.dart';
import '../services/book_open_preferences.dart';
import '../services/drama_mute_preferences.dart';
import '../services/library_store.dart';
import '../widgets/home/home_design.dart';
import 'about_page.dart';
import 'api_service_page.dart';
import 'cached_books_page.dart';
import 'cached_dramas_page.dart';
import 'library_backup_page.dart';
import 'settings_category_page.dart';
import 'system_tts_settings_page.dart';
import 'text_replacement_page.dart';

/// Settings home: a list of category entries (PiliPlus multi-level
/// navigation). Each category opens its own CommonSetting-style page.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 开关读的是 ValueNotifier：先把持久化的值读出来，读到后自动重绘。
    unawaited(BookOpenPreferences.instance.load());
    final palette = HomePalette.of(context);
    final categories = <SettingsCategory>[
      SettingsCategory(
        icon: LucideIcons.palette,
        title: '外观',
        subtitle: '主题模式、OLED 纯黑、播放页布局',
        // 用 builder 而不是固定 items：切到深色 / 切回浅色后，分类页重建
        // 时会重新判定，OLED 行不必退出重进就能出现或消失。
        // 播放页布局只在手机端有效（Windows 由 DesktopVideoChrome 承担）。
        itemsBuilder: (context) => [
          _themeModeItem(),
          if (isDarkAppearance(
            systemBrightness: MediaQuery.platformBrightnessOf(context),
          ))
            _oledModeItem(),
          if (!isWindowsDesktop) _playerLayoutItem(),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.book_open,
        title: '阅读',
        subtitle: '阅读入口、正文替换',
        items: [
          _shelfDirectReaderItem(),
          _discoverDirectReaderItem(),
          SettingsItem(
            icon: Icons.find_replace,
            title: '正文替换',
            subtitle: '自定义普通文本或正则替换规则',
            onTap: (context, _) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TextReplacementPage()),
            ),
          ),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.headphones,
        title: '听书',
        subtitle: '后台播放、通知栏控制与系统朗读',
        items: [
          _backgroundAudioItem(),
          if (!isWindowsDesktop) _audioRateEngineItem(),
          SettingsItem(
            icon: LucideIcons.mic,
            title: '系统朗读',
            subtitle: '选择 TTS 引擎与语速，支持本地书',
            onTap: (context, setState) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SystemTtsSettingsPage()),
            ),
          ),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.film,
        title: '短剧',
        subtitle: '播放',
        items: [
          _muteWhenColdStartItem(),
          if (!isWindowsDesktop) _floatingWindowItem(),
          if (!isWindowsDesktop) _videoDecoderItem(),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.database,
        title: '数据',
        subtitle: '备份与恢复、缓存、阅读与播放历史',
        items: [
          SettingsItem(
            icon: LucideIcons.database,
            title: '备份与导入',
            subtitle: '本机备份、恢复与番茄书架导入',
            onTap: (context, setState) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LibraryBackupPage()),
            ),
          ),
          SettingsItem(
            icon: LucideIcons.bookmark,
            title: '章节缓存',
            subtitle: '离线续读、查看占用和清理缓存',
            onTap: (context, setState) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CachedBooksPage()),
            ),
          ),
          SettingsItem(
            icon: LucideIcons.clapperboard,
            title: '剧集离线缓存',
            subtitle: '短剧下载、离线播放和清理缓存',
            onTap: (context, setState) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CachedDramasPage()),
            ),
          ),
          _clearHistItem(),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.cpu,
        title: '服务',
        subtitle: '本地接口地址与可用端点',
        pageBuilder: (_) => const ApiServicePage(),
        items: const [],
      ),
      SettingsCategory(
        icon: LucideIcons.info,
        title: '关于',
        subtitle: '版本与应用信息',
        pageBuilder: (_) => const AboutPage(),
        items: const [],
      ),
    ];

    const categoryColors = [
      Color(0xFFEF5038), // 外观
      Color(0xFF14B8A6), // 阅读
      Color(0xFF8B5CF6), // 听书
      Color(0xFFF59E0B), // 短剧
      Color(0xFF3B82F6), // 数据
      Color(0xFF10B981), // 服务
      Color(0xFF6366F1), // 关于
    ];

    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: true,
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: isWindowsDesktop
          ? DesktopSettingsBody(categories: categories)
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                Material(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: palette.line, width: 0.6),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < categories.length; i++) ...[
                          if (i > 0)
                            Divider(height: 1, indent: 68, color: palette.line),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 4,
                            ),
                            leading: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color:
                                    (i < categoryColors.length
                                            ? categoryColors[i]
                                            : HomePalette.accent)
                                        .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                categories[i].icon,
                                size: 20,
                                color: i < categoryColors.length
                                    ? categoryColors[i]
                                    : HomePalette.accent,
                              ),
                            ),
                            title: Text(
                              categories[i].title,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: palette.ink,
                              ),
                            ),
                            subtitle: Text(
                              categories[i].subtitle,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: palette.muted,
                              ),
                            ),
                            trailing: Icon(
                              LucideIcons.chevron_right,
                              size: 18,
                              color: palette.muted,
                            ),
                            onTap: () {
                              final cat = categories[i];
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
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  // ── 外观 ──────────────────────────────────────────────────────────────

  /// 主题模式（参考 legado 的 themeMode）：跟随系统 / 浅色 / 深色 / 墨水屏
  /// 四选一，墨水屏既然也是一种外观就并进这个入口，不再单列一个开关。
  SettingsItem _themeModeItem() => SettingsItem(
    icon: LucideIcons.sun_moon,
    title: '主题模式',
    trailingBuilder: (context) => ListenableBuilder(
      listenable: Listenable.merge([themeModeNotifier, einkModeNotifier]),
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _appearance.label,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
          const SizedBox(width: 4),
          const Icon(LucideIcons.chevron_right, size: 18),
        ],
      ),
    ),
    onTap: (context, setState) => _showThemeModeDialog(context),
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

  Future<void> _showThemeModeDialog(BuildContext context) async {
    final selected = await showDialog<_AppearanceChoice>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('主题模式'),
        children: [
          RadioGroup<_AppearanceChoice>(
            groupValue: _appearance,
            onChanged: (v) {
              if (v != null) Navigator.pop(c, v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final choice in _AppearanceChoice.values)
                  RadioListTile<_AppearanceChoice>(
                    value: choice,
                    title: Text(choice.label),
                    subtitle: choice == _AppearanceChoice.eink
                        ? const Text('纯黑白、无毛玻璃、无过渡动画，适合墨水屏设备')
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    await _setAppearance(context, selected);
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

  /// OLED 纯黑：画布纯黑省电，卡片 / 弹层保持近黑，靠描边撑住层次。
  /// 只在深色外观下显示（浅色 / 墨水屏没有可省的黑）。
  SettingsItem _oledModeItem() => SettingsItem(
    icon: LucideIcons.smartphone,
    title: 'OLED 纯黑',
    subtitle: '大面积纯黑省电，仅在深色外观下生效',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: oledModeNotifier,
      builder: (context, value, _) => Switch(
        value: value,
        onChanged: (v) => unawaited(_setOledMode(context, v)),
      ),
    ),
    onTap: (context, setState) {
      unawaited(_setOledMode(context, !oledModeNotifier.value));
    },
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
    icon: Icons.vertical_split_rounded,
    title: '播放页布局',
    subtitle: '短剧可分屏显示选集和评论，横屏时左右分栏',
    trailingBuilder: (context) => ValueListenableBuilder<PlayerLayoutMode>(
      valueListenable: PlayerLayoutPreferences.mode,
      builder: (context, value, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value.shortLabel,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
          const SizedBox(width: 4),
          const Icon(LucideIcons.chevron_right, size: 18),
        ],
      ),
    ),
    onTap: (context, setState) => _showPlayerLayoutDialog(context),
  );

  Future<void> _showPlayerLayoutDialog(BuildContext context) async {
    final current = PlayerLayoutPreferences.mode.value;
    final selected = await showDialog<PlayerLayoutMode>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('播放页布局'),
        children: [
          RadioGroup<PlayerLayoutMode>(
            groupValue: current,
            onChanged: (value) {
              if (value != null) Navigator.pop(dialogContext, value);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in PlayerLayoutMode.values)
                  RadioListTile<PlayerLayoutMode>(
                    value: mode,
                    title: Text(mode.label),
                    subtitle: Text(mode.description),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    await _setPlayerLayout(context, selected);
  }

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
    icon: LucideIcons.video,
    title: '切后台悬浮窗播放',
    subtitle: '切到后台或锁屏时用悬浮小窗继续播放，需要悬浮窗权限',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: PlayerPreferences.floatingWindow,
      builder: (context, value, _) => Switch(
        value: value,
        onChanged: (enabled) => unawaited(_setFloatingWindow(context, enabled)),
      ),
    ),
    onTap: (context, setState) {
      final current = PlayerPreferences.floatingWindow.value;
      unawaited(_setFloatingWindow(context, !current));
    },
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
    icon: LucideIcons.book_open,
    title: '书架点书直接进入阅读',
    subtitle: '在书架、阅读历史里点书时跳过详情页，接着上次进度读',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: BookOpenPreferences.instance.shelfDirectReader,
      builder: (context, value, _) => Switch(
        value: value,
        onChanged: (v) =>
            unawaited(BookOpenPreferences.instance.setShelfDirectReader(v)),
      ),
    ),
    onTap: (context, setState) {
      final current = BookOpenPreferences.instance.shelfDirectReader.value;
      unawaited(BookOpenPreferences.instance.setShelfDirectReader(!current));
    },
  );

  SettingsItem _discoverDirectReaderItem() => SettingsItem(
    icon: LucideIcons.search,
    title: '首页与搜索点书直接进入阅读',
    subtitle: '在首页、搜索、榜单、作者页等入口点书时跳过详情页',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: BookOpenPreferences.instance.discoverDirectReader,
      builder: (context, value, _) => Switch(
        value: value,
        onChanged: (v) =>
            unawaited(BookOpenPreferences.instance.setDiscoverDirectReader(v)),
      ),
    ),
    onTap: (context, setState) {
      final current = BookOpenPreferences.instance.discoverDirectReader.value;
      unawaited(BookOpenPreferences.instance.setDiscoverDirectReader(!current));
    },
  );
  // ── 听书 ──────────────────────────────────────────────────────────────

  SettingsItem _backgroundAudioItem() => SettingsItem(
    icon: LucideIcons.radio,
    title: '后台听书与保活',
    subtitle: '切到后台或锁屏时继续播放，并在通知栏常驻控制卡片',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: AudioPreferences.instance.backgroundPlayback,
      builder: (context, value, _) => Switch(
        value: value,
        onChanged: (v) =>
            unawaited(AudioPreferences.instance.setBackgroundPlayback(v)),
      ),
    ),
    onTap: (context, setState) {
      final current = AudioPreferences.instance.backgroundPlayback.value;
      unawaited(AudioPreferences.instance.setBackgroundPlayback(!current));
    },
  );

  /// 听书倍速的变速实现（issue #129）：默认交给系统混音器，高倍速下明显
  /// 没那么「电音」；内建 Sonic 作为厂商实现异常时的回退档。
  ///
  /// 与「视频解码器」同理：audio sink 在 build 时定型，新建播放器才生效。
  SettingsItem _audioRateEngineItem() => SettingsItem(
    icon: LucideIcons.gauge,
    title: '听书变速引擎',
    subtitle: '高倍速发毛、像电音时可在两档间切换，重新进入听书页生效',
    trailingBuilder: (context) => ValueListenableBuilder<AudioRateEngine>(
      valueListenable: AudioPreferences.instance.rateEngine,
      builder: (context, value, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value.label,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
          const SizedBox(width: 4),
          const Icon(LucideIcons.chevron_right, size: 18),
        ],
      ),
    ),
    onTap: (context, setState) => _showAudioRateEngineDialog(context, setState),
  );

  Future<void> _showAudioRateEngineDialog(
    BuildContext context,
    StateSetter refresh,
  ) async {
    final current = AudioPreferences.instance.rateEngine.value;
    final selected = await showDialog<AudioRateEngine>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('听书变速引擎'),
        children: [
          RadioGroup<AudioRateEngine>(
            groupValue: current,
            onChanged: (v) {
              if (v != null) Navigator.pop(c, v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final value in AudioRateEngine.values)
                  RadioListTile<AudioRateEngine>(
                    value: value,
                    title: Text(value.label),
                    subtitle: Text(switch (value) {
                      AudioRateEngine.wsola =>
                        '与番茄官方同一套算法（FFmpeg atempo），高倍速听感最接近原声',
                      AudioRateEngine.platform => '系统混音器变速，不依赖本应用的 native 库',
                      AudioRateEngine.builtIn =>
                        'Media3 内建 Sonic，最稳（默认，1.0.121 的行为）',
                    }),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    await AudioPreferences.instance.setRateEngine(selected);
    refresh(() {});
  }

  // ── 短剧 ──────────────────────────────────────────────────────────────

  /// 官方设置项「开启应用时默认静音」（`GlobalMuteConfig` 标题，持久层
  /// `open_mute_when_cold_start`，默认 false＝有声起播）。
  SettingsItem _muteWhenColdStartItem() => SettingsItem(
    icon: LucideIcons.volume_x,
    title: '开启应用时默认静音',
    subtitle: '进入短剧时静音播放，可在播放页取消',
    // Switch 走 ValueListenableBuilder，翻转后无需依赖页面的 setState。
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: DramaMutePreferences.instance.muteWhenColdStart,
      builder: (context, value, _) => Switch(
        value: value,
        onChanged: (v) => unawaited(DramaMutePreferences.instance.set(v)),
      ),
    ),
    onTap: (context, setState) {
      final current = DramaMutePreferences.instance.muteWhenColdStart.value;
      unawaited(DramaMutePreferences.instance.set(!current));
    },
  );

  /// 视频解码器（issue #92）：硬解异常的机型可以手动切软解。
  ///
  /// 只有**新起的播放器**会采用新设置——ExoPlayer 的 renderer 在 build 时
  /// 定型，所以行内说明写明需重新进入播放页。
  SettingsItem _videoDecoderItem() => SettingsItem(
    icon: LucideIcons.monitor_play,
    title: '视频解码器',
    subtitle: '画面异常（黑屏、卡住、绿屏）时改用软解，重新进入播放页生效',
    trailingBuilder: (context) => FutureBuilder<VideoDecoderPreference>(
      future: PlayerPreferences.loadVideoDecoder(),
      builder: (context, snapshot) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            (snapshot.data ?? VideoDecoderPreference.automatic).label,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
          const SizedBox(width: 4),
          const Icon(LucideIcons.chevron_right, size: 18),
        ],
      ),
    ),
    onTap: (context, setState) => _showVideoDecoderDialog(context, setState),
  );

  Future<void> _showVideoDecoderDialog(
    BuildContext context,
    StateSetter refresh,
  ) async {
    final current = await PlayerPreferences.loadVideoDecoder();
    if (!context.mounted) return;
    final selected = await showDialog<VideoDecoderPreference>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('视频解码器'),
        children: [
          RadioGroup<VideoDecoderPreference>(
            groupValue: current,
            onChanged: (v) {
              if (v != null) Navigator.pop(c, v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final value in VideoDecoderPreference.values)
                  RadioListTile<VideoDecoderPreference>(
                    value: value,
                    title: Text(value.label),
                    subtitle: value == VideoDecoderPreference.software
                        ? const Text('更耗电，但能绕开部分芯片的硬解缺陷')
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    try {
      await DecoderPreferenceCache.set(selected);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('解码器设置未能保存')));
      }
      return;
    }
    refresh(() {});
  }

  // ── 数据 ──────────────────────────────────────────────────────────────

  SettingsItem _clearHistItem() => SettingsItem(
    icon: LucideIcons.trash,
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
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

  // ── 关于 ──────────────────────────────────────────────────────────────
  // The About category opens the About page directly via its pageBuilder;
  // no category-page items are needed.
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
