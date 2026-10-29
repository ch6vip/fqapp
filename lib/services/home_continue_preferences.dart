import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

/// 「继续阅读」那一行的关闭状态。
///
/// 只对**被关掉的那一本**生效：换另一本书在读时这一行会重新出现，关闭
/// 不会把功能永久关死，也不需要用户去设置里找回来。页面只问 [isDismissed]。
class HomeContinuePreferences {
  HomeContinuePreferences._();

  static final HomeContinuePreferences instance = HomeContinuePreferences._();

  static const _key = 'home_continue_dismissed';

  /// 被关掉的那本书的 `kind:id`；null 表示没关过。
  final ValueNotifier<String?> dismissedId = ValueNotifier<String?>(null);

  bool _loaded = false;

  static String idOf(MediaItem item) => '${item.kind}:${item.id}';

  bool isDismissed(MediaItem item) => dismissedId.value == idOf(item);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      dismissedId.value = sp.getString(_key);
    } catch (_) {
      // A broken optional preference reads as "not dismissed".
    }
  }

  Future<void> dismiss(MediaItem item) async {
    dismissedId.value = idOf(item);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_key, idOf(item));
    } catch (_) {
      // The in-session value still applies; only persistence failed.
    }
  }

  /// 忘掉已加载状态，让下一次 [load] 重新读 SharedPreferences。
  ///
  /// 只为测试存在：`_loaded` 是进程级一次性守卫，`setMockInitialValues`
  /// 换掉的初值不会被已加载过的实例重新读取。
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    dismissedId.value = null;
  }
}
