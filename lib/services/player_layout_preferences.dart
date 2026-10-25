import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放页布局偏好（设置 → 外观 → 播放页布局）。
///
/// 只作用于短剧播放页；通用播放器（详情页电影/电视剧）保持原布局。
/// 默认沉浸式，与加入该偏好之前的行为一致。
enum PlayerLayoutMode {
  immersive(
    storageName: 'immersive',
    label: '沉浸式',
    shortLabel: '沉浸式',
    description: '保持现在的全屏刷剧，不显示下半区面板',
  ),
  auto(
    storageName: 'auto',
    label: '横屏片源自动分屏',
    shortLabel: '自动分屏',
    description: '竖屏设备播放横屏片源时自动分屏，竖屏片源保持沉浸式',
  ),
  split(
    storageName: 'split',
    label: '始终分屏',
    shortLabel: '始终分屏',
    description: '竖屏上下分栏，横屏左右分栏',
  );

  const PlayerLayoutMode({
    required this.storageName,
    required this.label,
    required this.shortLabel,
    required this.description,
  });

  /// 落盘值；改名会丢掉用户已保存的选择，不要随文案调整。
  final String storageName;
  final String label;
  final String shortLabel;
  final String description;

  static PlayerLayoutMode fromStorage(String? value) {
    for (final mode in values) {
      if (mode.storageName == value) return mode;
    }
    return PlayerLayoutMode.immersive;
  }
}

/// 播放页布局偏好的持久化入口。
///
/// 与主题模式一样用全局 [ValueNotifier]：设置页写入后播放页立即重建，
/// 不需要退出重进。读盘失败一律回落到默认沉浸式，不能影响播放。
class PlayerLayoutPreferences {
  const PlayerLayoutPreferences._();

  /// SharedPreferences key：`player_layout_mode` = 'immersive'|'auto'|'split'。
  static const key = 'player_layout_mode';

  static final ValueNotifier<PlayerLayoutMode> mode =
      ValueNotifier<PlayerLayoutMode>(PlayerLayoutMode.immersive);

  static PlayerLayoutMode decode(String? value) =>
      PlayerLayoutMode.fromStorage(value);

  /// 写入偏好；返回 false 表示平台通道没有确认保存。
  static Future<bool> save(PlayerLayoutMode value) async {
    final sp = await SharedPreferences.getInstance();
    return sp.setString(key, value.storageName);
  }
}
