import 'package:flutter/widgets.dart';

import '../services/shell_visibility.dart';

/// Mount a tab on its first visit, then retain its scroll and widget state.
/// Hidden tabs are muted, including when the containing route is offstage.
class LazyIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;

  const LazyIndexedStack({
    super.key,
    required this.index,
    required this.children,
  }) : assert(index >= 0 && index < children.length);

  @override
  State<LazyIndexedStack> createState() => _LazyIndexedStackState();
}

class _LazyIndexedStackState extends State<LazyIndexedStack> {
  final _visited = <int>{};

  @override
  void initState() {
    super.initState();
    _visited.add(widget.index);
    // 桌面壳层与测试也用这个容器：可见性同样广播给页面，别让隐藏页继续
    // 响应数据变更（页面不再依赖 TickerMode）。首帧也广播一次，否则页面
    // 在挂载时读到的是上一个容器的残留下标。
    shellVisibleTab.value = widget.index;
  }

  @override
  void didUpdateWidget(LazyIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visited.removeWhere((index) => index >= widget.children.length);
    _visited.add(widget.index);
    shellVisibleTab.value = widget.index;
  }

  @override
  void dispose() {
    // 只清自己写进去的值：同一测试里可能有多个容器或页面并存。
    if (shellVisibleTab.value == widget.index) shellVisibleTab.value = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IndexedStack(
    index: widget.index,
    children: [
      for (var index = 0; index < widget.children.length; index++)
        TickerMode(
          enabled: index == widget.index,
          child: _visited.contains(index)
              ? widget.children[index]
              : const SizedBox.shrink(),
        ),
    ],
  );
}
