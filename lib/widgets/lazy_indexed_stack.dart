import 'package:flutter/widgets.dart';

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
  }

  @override
  void didUpdateWidget(LazyIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visited.removeWhere((index) => index >= widget.children.length);
    _visited.add(widget.index);
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
