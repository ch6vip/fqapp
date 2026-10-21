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
        subtitle: '深色模式、墨水屏模式',
        items: [_themeModeItem(), _einkModeItem()],
      ),
      SettingsCategory(
        icon: LucideIcons.book_open,
        title: '阅读',
        subtitle: '点书直达阅读器（书架 / 发现入口）',
        items: [_shelfDirectReaderItem(), _discoverDirectReaderItem()],
      ),
      SettingsCategory(
        icon: LucideIcons.headphones,
        title: '听书',
        subtitle: '后台播放、通知栏控制与系统朗读',
        items: [
          _backgroundAudioItem(),
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

  SettingsItem _themeModeItem() => SettingsItem(
    icon: LucideIcons.sun_moon,
    title: '深色模式',
    trailingBuilder: (context) => ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _modeLabel(mode),
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
          const SizedBox(width: 4),
          const Icon(LucideIcons.chevron_right, size: 18),
        ],
      ),
    ),
    onTap: (context, setState) => _showThemeModeDialog(context),
  );

  String _modeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
      case ThemeMode.system:
        return '跟随系统';
    }
  }

  Future<void> _showThemeModeDialog(BuildContext context) async {
    final selected = await showDialog<ThemeMode>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('深色模式'),
        children: [
          RadioGroup<ThemeMode>(
            groupValue: themeModeNotifier.value,
            onChanged: (v) {
              if (v != null) Navigator.pop(c, v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final m in const [
                  ThemeMode.system,
                  ThemeMode.light,
                  ThemeMode.dark,
                ])
                  RadioListTile<ThemeMode>(
                    value: m,
                    title: Text(_modeLabel(m)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    themeModeNotifier.value = selected;
    try {
      final sp = await SharedPreferences.getInstance();
      if (!await sp.setString(themeModeKey, selected.name)) {
        throw StateError('Theme preference was not saved');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('外观已更新，但未能保存')));
      }
    }
  }

  /// #15/#9 墨水屏模式：纯黑白、无毛玻璃、无过渡动画。开启时强制浅色，
  /// 深色模式恢复后仍按原设置生效。
  SettingsItem _einkModeItem() => SettingsItem(
    icon: LucideIcons.book_open,
    title: '墨水屏模式',
    subtitle: '纯黑白、无毛玻璃、无过渡动画，适合墨水屏设备',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: einkModeNotifier,
      builder: (context, value, _) => Switch(
        value: value,
        onChanged: (v) => unawaited(_setEinkMode(context, v)),
      ),
    ),
    onTap: (context, setState) {
      unawaited(_setEinkMode(context, !einkModeNotifier.value));
    },
  );

  Future<void> _setEinkMode(BuildContext context, bool value) async {
    einkModeNotifier.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      if (!await sp.setBool(einkModeKey, value)) {
        throw StateError('E-ink preference was not saved');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('墨水屏模式已更新，但未能保存')));
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
        onChanged: (enabled) =>
            unawaited(_setFloatingWindow(context, enabled)),
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
        const SnackBar(
          content: Text('请在系统设置中允许“显示在其他应用的上层”，然后回来再开启'),
        ),
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
        onChanged: (v) => unawaited(
          BookOpenPreferences.instance.setShelfDirectReader(v),
        ),
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
        onChanged: (v) => unawaited(
          BookOpenPreferences.instance.setDiscoverDirectReader(v),
        ),
      ),
    ),
    onTap: (context, setState) {
      final current =
          BookOpenPreferences.instance.discoverDirectReader.value;
      unawaited(
        BookOpenPreferences.instance.setDiscoverDirectReader(!current),
      );
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
