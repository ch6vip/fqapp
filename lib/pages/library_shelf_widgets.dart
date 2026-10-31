part of 'library_page.dart';

/// 书架页的私有小部件：编辑态底栏上滑、收藏筛选胶囊、一级 tab、图标
/// 按钮、版式分段与底栏条目。原来都写在 `library_page.dart` 里，把那个
/// 文件推过了行数预算，按职责挪到这里。
/// 编辑态底栏的上滑入场：AnimatedSlide + AnimatedOpacity，首帧隐藏、
/// 下一帧滑入（无障碍关闭动画时直接呈现）。
class _SlideUp extends StatefulWidget {
  final Widget child;

  const _SlideUp({required this.child});

  @override
  State<_SlideUp> createState() => _SlideUpState();
}

class _SlideUpState extends State<_SlideUp> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final disabled = MediaQuery.disableAnimationsOf(context);
    return AnimatedSlide(
      offset: _shown || disabled ? Offset.zero : const Offset(0, 1),
      duration: disabled ? Duration.zero : const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: _shown || disabled ? 1 : 0,
        duration: disabled ? Duration.zero : const Duration(milliseconds: 260),
        child: widget.child,
      ),
    );
  }
}

/// 一级 tab：选中 18sp w600，指示条宽度动画（AnimatedContainer）。
class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final HomePalette palette;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: selected ? 18 : 15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  letterSpacing: -0.3,
                  color: selected ? palette.ink : palette.muted,
                ),
              ),
              const SizedBox(height: 5),
              // 指示条宽度动画；高度恒定保持行高一致。
              AnimatedContainer(
                duration: _motionDuration(context, 220),
                curve: Curves.easeOutCubic,
                width: selected ? 26 : 0,
                height: 3,
                decoration: BoxDecoration(
                  color: selected ? HomePalette.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _IconAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onTap,
        style: IconButton.styleFrom(
          foregroundColor: color,
          padding: const EdgeInsets.all(8),
          minimumSize: const Size(38, 38),
        ),
        icon: Icon(icon, size: 21),
      ),
    );
  }
}

/// L2 版式分段控件：宫格 / 双列 / 列表三个图标按钮，与更多菜单同 handler。
class _LayoutSegments extends StatelessWidget {
  final BookshelfLayout current;
  final HomePalette palette;
  final ValueChanged<BookshelfLayout> onChanged;

  const _LayoutSegments({
    required this.current,
    required this.palette,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(ShelfTokens.radiusButton),
        border: Border.all(color: palette.line, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final layout in BookshelfLayout.values)
            Tooltip(
              message: layout.menuLabel,
              child: InkWell(
                key: Key('shelf-layout-${layout.segmentKey}'),
                onTap: () => onChanged(layout),
                borderRadius: BorderRadius.circular(9),
                child: Container(
                  width: 34,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: layout == current
                        ? HomePalette.accent.withValues(alpha: 0.15)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(
                    layout.menuIcon,
                    size: 17,
                    color: layout == current
                        ? HomePalette.accent
                        : palette.muted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 编辑态底栏条目：现代化操作胶囊按钮。
class _BottomAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _BottomAction({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = enabled ? color : color.withValues(alpha: 0.35);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ShelfTokens.radiusButton),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: fg),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                height: 1.2,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
