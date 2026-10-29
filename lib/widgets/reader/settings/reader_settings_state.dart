import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../services/reader_preferences.dart';

/// 阅读设置面板共用的编辑状态。
///
/// 阅读页每次收到新的排版都会同步重排整章；滑块每帧 `onChanged` 都往上传
/// 会掉帧。这里让面板自己的控件即时更新，向阅读页的写入按 120ms 尾随合并，
/// 松手（[flushPreferences]）与面板销毁时把最后一次值补发出去。
abstract class ReaderSettingsState<T extends StatefulWidget> extends State<T> {
  ReaderPreferences get initialPreferences;

  ValueChanged<ReaderPreferences> get onPreferencesChanged;

  late ReaderPreferences value = initialPreferences.normalized();

  Timer? _debounce;
  bool _pending = false;

  /// 面板内改动：立即刷新自身，稍后合并通知阅读页。
  void updatePreferences(ReaderPreferences next) {
    setState(() => value = next.normalized());
    _pending = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), flushPreferences);
  }

  /// 只同步本地值（子面板已经负责通知阅读页），不再触发二次通知。
  void adoptPreferences(ReaderPreferences next) {
    setState(() => value = next.normalized());
  }

  /// 把待发送的值立刻发给阅读页；滑块松手、面板关闭时调用。
  void flushPreferences() {
    _debounce?.cancel();
    _debounce = null;
    if (!mounted || !_pending) return;
    _pending = false;
    onPreferencesChanged(value);
  }

  @override
  void dispose() {
    // 拖动中途关闭面板时，最后一次值仍要落到阅读页与偏好里。
    flushPreferences();
    super.dispose();
  }
}
