import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 短剧「开启应用时默认静音」的持久化开关。
///
/// 官方的静音是三层结构（反编译依据见
/// .agents/notes/implemented/feature/2026-09-27-feed-mute-official-logic.md）：
/// 服务端总开关（`video_mute_config_v639.default_mute`，本地缺省 false）、
/// 本设置（官方键 `open_mute_when_cold_start`，MMKV
/// `short_video_mute_global_manager`，**默认 false**＝有声起播）、以及会话态
/// `tm3.b.needMutePlay`（点药丸/按音量键解除后会话内不再静音）。本仓库没有
/// 服务端开关与音量键监听，对齐的是后两层：默认有声，只有用户开了这个设置
/// 才在进入短剧页时静音并给出「取消静音」药丸。
class DramaMutePreferences {
  DramaMutePreferences._();

  static final DramaMutePreferences instance = DramaMutePreferences._();

  static const _key = 'drama_mute_when_cold_start';

  /// Whether the short-drama feed starts muted. Loaded from SharedPreferences
  /// by [load]; before that completes it reads the official default (unmuted).
  final ValueNotifier<bool> muteWhenColdStart = ValueNotifier<bool>(false);

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      muteWhenColdStart.value = sp.getBool(_key) ?? false;
    } catch (_) {
      // A broken optional preference reads as the official default (unmuted).
    }
  }

  /// 忘掉已加载状态，让下一次 [load] 重新读 SharedPreferences。
  ///
  /// 只为测试存在：`_loaded` 是进程级一次性守卫，`setMockInitialValues`
  /// 换掉的初值不会被已加载过的实例重新读取（整文件跑挂、单跑过的根因）。
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    muteWhenColdStart.value = false;
  }

  Future<void> set(bool value) async {
    muteWhenColdStart.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_key, value);
    } catch (_) {
      // The in-session value still applies; only persistence failed.
    }
  }
}
