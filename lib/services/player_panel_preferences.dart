import 'package:shared_preferences/shared_preferences.dart';

import 'player_style_config.dart';

/// 更多面板里「需要落盘」的那几项的官方存储语义。
///
/// 官方有两套完全不同的做法，这里逐项照搬（`ShortSeriesMorePanelDialogV2`
/// 的 `ActionItemSingleChoiceHolder.onBind` / `onClick`）：
/// - **画面撑满**：SP `is_fill_screen`，键 `is_fill_screen`，
///   默认值 `!short_video_setting_opt_v679.default_video_size_aspect_fit`，
///   并且**只在竖屏**（`sb4.e.q()`）时该默认值生效，其余情况缺省 false
///   （`FillScreenDataManager.java:27-37`）
/// - **默认静音**：官方**不落盘**，只有 `tm3.b` 的静态字段
///   （`tm3/b.java:17-21`：`b/c/d/e/f` 均无初始化器，JVM 缺省全 false；
///   `m()` 开静音、`a()` 关静音、`g()` 启动时设置检查），
///   跨进程靠本地广播 `action_on_default_mute_play_status_changed` + extra
///   `key_default_mute_play`（`jq3/d0.java:390` 读 extra 缺省 false）。
///   **出厂 = 有声**；此前注释「e = true」是误读，已更正。
///
/// 弹幕开关的落盘在 `DanmakuPreference`（另一个文件，另一套键）。
class PlayerPanelPreferences {
  const PlayerPanelPreferences._();

  /// 官方 SP 名与键同名（`d.a.b(ctx, "is_fill_screen")`）。
  static const fillScreenStore = 'is_fill_screen';
  static const fillScreenKey = 'is_fill_screen';

  /// 默认静音的官方初始值：`tm3/b.java` 的 `e` 静态缺省 **false（有声）**。
  ///
  /// 官方**不落盘**，所以这里也只在进程内保存，重启回到 false——
  /// 这不是偷懒，是与官方一致的行为（官方全屏进页音量取 `e()`，
  /// `fullscreen/a.java` 持有者经广播同步）。
  static bool _defaultMute = false;

  static bool get defaultMute => _defaultMute;

  static void setDefaultMute(bool enabled) => _defaultMute = enabled;

  /// 官方读取（`FillScreenDataManager.a()`）：
  ///
  /// 有 SP 值就用 SP 值；没有 SP 值时**竖屏直接 false**，
  /// 其余情况才用 `!default_video_size_aspect_fit`——
  /// 这个分支是官方源码里显式的：
  /// `if (e.q() && !sp.contains(KEY)) return false;`
  /// `return sp.getBoolean(KEY, !config.defaultVideoSizeAspectFit);`
  static Future<bool> loadFillScreen({bool portrait = true}) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getBool(fillScreenKey);
    if (saved != null) return saved;
    if (portrait) return false;
    return !PlayerStyleConfig.instance.defaultVideoSizeAspectFit;
  }

  static Future<void> saveFillScreen(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(fillScreenKey, enabled);
  }
}
