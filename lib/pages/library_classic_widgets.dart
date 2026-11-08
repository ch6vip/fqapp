part of 'library_page.dart';

/// Three-layout controls ported from f329399's library_shelf_widgets.dart.
enum _ClassicMenuAction {
  importBook('导入图书', LucideIcons.plus),
  cachedBooks('离线缓存', LucideIcons.download),
  switchGrid('切换为宫格', LucideIcons.layout_grid, BookshelfLayout.grid),
  switchDouble('切换为双列', LucideIcons.columns_2, BookshelfLayout.doubleColumn),
  switchList('切换为列表', LucideIcons.list, BookshelfLayout.list),
  filter('排序与筛选', Icons.filter_list),
  categories('分类与分组', LucideIcons.folder),
  clearFilters('清除筛选', Icons.filter_alt_off_outlined),
  edit('编辑书架', LucideIcons.pencil),
  clearHistory('清空历史', LucideIcons.trash);

  const _ClassicMenuAction(this.label, this.icon, [this.layout]);
  final String label;
  final IconData icon;
  final BookshelfLayout? layout;
}

class _ClassicTabButton extends StatelessWidget {
  const _ClassicTabButton({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final HomePalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: selected ? 18 : 15,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                letterSpacing: -.3,
                color: selected ? palette.ink : palette.muted,
              ),
            ),
            const SizedBox(height: 5),
            AnimatedContainer(
              key: ValueKey('classic-tab-underline-$label'),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
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

class _ClassicLayoutSegments extends StatelessWidget {
  const _ClassicLayoutSegments({
    required this.current,
    required this.palette,
    required this.onChanged,
  });

  final BookshelfLayout current;
  final HomePalette palette;
  final ValueChanged<BookshelfLayout> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: palette.soft,
      borderRadius: BorderRadius.circular(ShelfTokens.radiusButton),
      border: Border.all(color: palette.line, width: .5),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final layout in BookshelfLayout.values)
          Tooltip(
            message: layout.menuLabel,
            child: Semantics(
              button: true,
              selected: layout == current,
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
                        ? HomePalette.accent.withValues(alpha: .15)
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
          ),
      ],
    ),
  );
}

class _ClassicEmptyNotice extends StatelessWidget {
  const _ClassicEmptyNotice({
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.actionKey,
    this.onAction,
    this.onCachedBooks,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final Key? actionKey;
  final VoidCallback? onAction;
  final VoidCallback? onCachedBooks;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ShelfTokens.screenPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: palette.soft,
                borderRadius: BorderRadius.circular(ShelfTokens.radiusCard),
              ),
              child: Icon(
                icon,
                size: 48,
                color: palette.eink
                    ? Colors.black
                    : palette.muted.withValues(alpha: .65),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: palette.ink,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: palette.muted),
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: 20),
              FilledButton(
                key: actionKey,
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: palette.eink
                      ? palette.ink
                      : HomePalette.accent,
                  foregroundColor: palette.eink ? palette.canvas : Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                child: Text(actionLabel!),
              ),
            ],
            if (onCachedBooks != null) ...[
              const SizedBox(height: 10),
              TextButton.icon(
                key: const Key('shelf-cached-books-button'),
                onPressed: onCachedBooks,
                style: TextButton.styleFrom(foregroundColor: palette.muted),
                icon: const Icon(LucideIcons.download, size: 16),
                label: const Text('查看离线缓存'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ClassicBottomAction extends StatelessWidget {
  const _ClassicBottomAction({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = onTap == null ? color.withValues(alpha: .35) : color;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ShelfTokens.radiusButton),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: foreground),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                height: 1.2,
                color: foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
