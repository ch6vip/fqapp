import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 短剧频道条的跨启动记忆。
///
/// 官方把频道选择写进 SP：`SeriesMallVM` 上报的 `tab_type` / `last_tab_type`
/// 就是当前与上一次选中的频道类型，冷启动据此回到上次看的频道。本地同样
/// 只存 `tab_type`——`title` 是服务端文案会变，类型才是频道的身份。
///
/// 读盘失败、类型不认识或该频道已从表里消失时一律回落到「推荐」，不能因为
/// 一条可选偏好挡住短剧页。
class DramaChannelPreferences {
  const DramaChannelPreferences._();

  /// SP key：当前频道 `tab_type`（16/8/24/18/30）。
  static const key = 'drama_channel_type';

  /// SP key：官方 `last_tab_type`，即上一次切换前选中的类型。
  static const lastKey = 'drama_channel_last_type';

  /// 上次选中的频道类型；null = 没有记录（落在「推荐」）。
  ///
  /// 启动时由 `main` 的 `SharedPreferences` 一次性灌入，页面在 `initState`
  /// 同步读取，首帧就是正确的频道，不会先闪一下「推荐」。
  static int? selectedType;

  /// 官方 `last_tab_type`；-1 = 没有「上一个」。
  static int lastType = -1;

  /// 启动时调用：把两份偏好读进内存态。
  static void load(SharedPreferences preferences) {
    selectedType = preferences.getInt(key);
    lastType = preferences.getInt(lastKey) ?? -1;
  }

  /// 记录一次频道切换。写盘失败不抛：偏好丢了只影响下次落点。
  ///
  /// 切到同一频道不算切换（`last_tab_type` 是「上一次**别的**频道」），
  /// 不写盘也内存态不变。
  static Future<void> save(int type) async {
    final previous = selectedType;
    if (previous == type) return;
    selectedType = type;
    lastType = previous ?? -1;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(key, type);
      if (previous != null) {
        await preferences.setInt(lastKey, previous);
      }
    } catch (_) {
      // 平台通道不可用（测试/首次启动）时保持内存态即可。
    }
  }

  /// 测试用：把内存态恢复成「没有记录」。
  @visibleForTesting
  static void reset() {
    selectedType = null;
    lastType = -1;
  }
}
