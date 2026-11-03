import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'home_provider.dart';

/// 切分类：**只把内容区摆回第一行，顶部区域一点不动**。
///
/// 之前这里给每个分类记账，切过去再把视图跳回该分类上次的位置。问题是滚动
/// 视图只有一个：跳位置发生在换内容之前，屏幕上是「列表先窜到别处、再整块被
/// 换掉」，读起来就是「整页重新加载了一个界面」。
///
/// 短剧页没有这个毛病——它的顶栏在滚动视图外面，切频道只是换内容。所以这里
/// 对齐它：新分类从自己的第一行开始显示，而搜索行（hero）已经滚出就保持滚出。
/// 把「分类条吸顶时的滚动位置」当作内容区的第一行：搜索行的高度就是它。
class HomeTabSwitch {
  HomeTabSwitch(this._scroll, this._ref, this._heroKey);

  final ScrollController _scroll;
  final WidgetRef _ref;
  final GlobalKey _heroKey;

  /// 搜索行的高度 = 分类条吸顶时的滚动位置。滚出屏幕后 sliver 仍会布局它
  /// 的 child，所以随时量都拿得到；量不到就一点不动（宁可保持原位，也不要
  /// 把搜索行重新带回来）。
  double? _measurePinOffset() {
    final box = _heroKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.size.height;
  }

  void select(int index) {
    if (index == _ref.read(homeProvider).tabIndex) return;
    final pin = _measurePinOffset();
    if (pin != null && _scroll.hasClients && _scroll.position.pixels > pin) {
      _scroll.jumpTo(pin);
    }
    _ref.read(homeProvider.notifier).selectTab(index);
  }
}
