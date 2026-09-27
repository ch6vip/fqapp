import 'dart:convert';

import 'package:flutter/services.dart';

/// 短剧播放器的官方服务端开关（`PlayerBottomStyleConfig` 等）。
///
/// 官方这些值来自 `is.snssdk.com/service/settings/v3/` 的短剧配置包；本仓库
/// 没有该账号/渠道的配置通道，因此把它们落在应用自带的 `config.json` 里，
/// 保持与官方同名的键，读取路径与其它运行时配置（`BackendService`）一致。
///
/// 已确认的键与默认值：
/// - `player_bottom_style_config.use_new_player_bottom_style`（默认 false）
/// - `player_bottom_style_config.has_banner`（默认 false）
/// - `func_reverse_of_clear_screen_v691.reverse`（默认 false）
/// - `landscape_func_config_v705.enable_lock`（默认 false）
/// - `pad_new_player_bottom_style`（官方 `PadFitPhaseTwo.newBottomStyle`）
///
/// 证据见 .agents/notes/proposed/architecture/2026-09-25-f01-f03-official-evidence.md。
class PlayerStyleConfig {
  const PlayerStyleConfig({
    this.useNewPlayerBottomStyle = false,
    this.hasBanner = false,
    this.padNewBottomStyle = false,
    this.reverseClearScreen = false,
    this.landscapeLockEnabled = false,
    this.defaultVideoSizeAspectFit = false,
    this.relateBookInEpisodesDialog = false,
  });

  /// 无配置时的形态：**旧底栏**、无横幅、无清屏反转、无横屏锁——
  /// 与官方 `PlayerBottomStyleConfig()` 的无参默认 `(false, false)` 对齐。
  /// 本仓库发布的 config.json 显式打开新底栏，默认常量不替它做主。
  static const PlayerStyleConfig defaults = PlayerStyleConfig(
    useNewPlayerBottomStyle: false,
  );

  /// Process-wide value. It is read by the player chrome, so it must be the
  /// same for every route; tests assign it directly.
  static PlayerStyleConfig instance = defaults;

  /// Guards the one bundle read (see [load]).
  static bool _loaded = false;

  final bool useNewPlayerBottomStyle;
  final bool hasBanner;
  final bool padNewBottomStyle;
  final bool reverseClearScreen;
  final bool landscapeLockEnabled;

  /// 官方 `short_video_setting_opt_v679.default_video_size_aspect_fit`
  /// （默认 false）。它只决定「画面撑满」的缺省值
  /// （`FillScreenDataManager.java:32`）。
  final bool defaultVideoSizeAspectFit;

  /// 官方 `series_relate_book_config_v659.relate_book_in_episodes_dialog`
  /// （**默认 false**）：选集面板里的「关联原著」条（`a1.java:1819-1828`）。
  /// 官方默认关，所以本地也默认关——不会在官方未显示的配置下强制添加。
  final bool relateBookInEpisodesDialog;

  /// 官方 `PlayerBottomStyleConfig.a()`：两个字段任一为真即走新底栏。
  bool get newBottomStyle => useNewPlayerBottomStyle || hasBanner;

  static PlayerStyleConfig fromJson(Map<String, dynamic> json) {
    final bottom = json['player_bottom_style_config'];
    final reverse = json['func_reverse_of_clear_screen_v691'];
    final landscape = json['landscape_func_config_v705'];
    final fill = json['short_video_setting_opt_v679'];
    return PlayerStyleConfig(
      useNewPlayerBottomStyle: _bool(bottom, 'use_new_player_bottom_style'),
      hasBanner: _bool(bottom, 'has_banner'),
      padNewBottomStyle: json['pad_new_player_bottom_style'] == true,
      reverseClearScreen: _bool(reverse, 'reverse'),
      landscapeLockEnabled: _bool(landscape, 'enable_lock'),
      defaultVideoSizeAspectFit: _bool(fill, 'default_video_size_aspect_fit'),
      relateBookInEpisodesDialog: _bool(
        json['series_relate_book_config_v659'],
        'relate_book_in_episodes_dialog',
      ),
    );
  }

  /// Loads the bundled config. A missing or malformed file keeps the defaults
  /// rather than failing startup: the switches are decoration compared to a
  /// playable series.
  ///
  /// The bundle read happens at most once per process: widget tests preload it
  /// inside `runAsync`, and a second asset read would land on the fake-async
  /// path and never complete.
  static Future<PlayerStyleConfig> load({
    AssetBundle? bundle,
    bool force = false,
  }) async {
    if (_loaded && !force) return instance;
    _loaded = true;
    try {
      final raw = await (bundle ?? rootBundle).loadString(
        'assets/config/config.json',
      );
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        instance = fromJson(decoded);
      }
    } catch (_) {
      // 保留默认值。
    }
    return instance;
  }

  static bool _bool(dynamic section, String key) {
    if (section is! Map) return false;
    return section[key] == true;
  }
}
