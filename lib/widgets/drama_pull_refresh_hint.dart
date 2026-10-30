import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 下拉达到这个距离（逻辑像素）就进入「正在刷新内容」的就绪态。
///
/// 页面里收手势的判定与这里的提示文案共用这一个口径。
const double kDramaPullRefreshTrigger = 64.0;

/// 短剧页下拉刷新的提示条（官方 `aq0.xml`，16sp「下拉刷新内容」）。
///
/// 下拉距离每帧都在变。距离用 notifier 推进来，只有这条提示跟着重建；
/// feed / 网格与顶栏不参与，滚动时不再整页 setState。
class DramaPullRefreshHint extends StatelessWidget {
  const DramaPullRefreshHint({
    super.key,
    required this.distance,
    this.trigger = kDramaPullRefreshTrigger,
    required this.color,
  });

  /// 当前下拉距离（逻辑像素），0 表示不显示。
  final ValueListenable<double> distance;

  /// 达到该距离即视为「已就绪，松手刷新」。
  final double trigger;

  /// 浅色页用墨色（白字在白底上看不见），视频流仍用白字。
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: distance,
      builder: (context, value, _) {
        if (value <= 0) return const SizedBox.shrink();
        return Center(
          child: SizedBox(
            height: 22,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value >= trigger ? '正在刷新内容' : '下拉刷新内容',
                  style: TextStyle(fontSize: 16, color: color),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
