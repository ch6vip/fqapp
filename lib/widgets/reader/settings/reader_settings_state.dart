import 'package:flutter/widgets.dart';

import '../../../services/reader_preferences.dart';

/// 阅读设置面板共用的编辑状态。
///
/// 面板控件先在本地 `value` 上即时生效，再把结果交给阅读页。面板里的控件
/// 都是离散点按（chip / 开关 / 步进器 / 动作按钮），因此立即写入；连续拖动
/// 的亮度滑条由阅读页自己的回调直接处理，不经过这里。
abstract class ReaderSettingsState<T extends StatefulWidget> extends State<T> {
  ReaderPreferences get initialPreferences;

  ValueChanged<ReaderPreferences> get onPreferencesChanged;

  late ReaderPreferences value = initialPreferences.normalized();

  /// 面板内离散改动：立即刷新自身并通知阅读页。
  void commitPreferences(ReaderPreferences next) {
    setState(() => value = next.normalized());
    onPreferencesChanged(value);
  }

  /// 只同步本地值（子面板已经负责通知阅读页），不再触发二次通知。
  void adoptPreferences(ReaderPreferences next) {
    setState(() => value = next.normalized());
  }
}
