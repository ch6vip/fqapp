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
    super.key,
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
    required this.width,
  });

  final String label;
  final bool selected;
  final HomePalette palette;
  final VoidCallback onTap;

  /// The reserved width of the tab.
  ///
  /// A tab label is 18sp when selected and 15sp otherwise. Without a
  /// reserved width the tab would change width the moment the selection
  /// moves, the whole row would shift under the finger, and the tabs would
  /// visibly jump on every swipe. The label is centred inside the reserved
  /// width instead.
  final double width;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The label is centred in the reserved width, so the text can
              // change size without moving the tab.
              Center(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: selected ? 18 : 15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    letterSpacing: -.3,
                    color: selected ? palette.ink : palette.muted,
                  ),
                ),
              ),
              const SizedBox(height: 5),
              // The underline is drawn once for the whole row now, so it can
              // slide between tabs instead of each tab fading its own in.
              SizedBox(width: 26, height: 3),
            ],
          ),
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

/// 经典书架工具栏的分组胶囊：与「今日已读」胶囊同款外形，也是分组入口
/// （点开就是现有的分类弹层）。选中分组时用强调色描边与文字，长分组名
/// 只省略不折行，不会把工具栏挤高一行。
class _ClassicGroupChip extends StatelessWidget {
  const _ClassicGroupChip({
    super.key,
    required this.label,
    required this.active,
    required this.palette,
    required this.onTap,
  });

  final String label;
  final bool active;
  final HomePalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = active && !palette.eink;
    final border = palette.eink || active
        ? Border.all(color: accent ? HomePalette.accent : palette.line)
        : null;
    return Semantics(
      button: true,
      selected: active,
      label: '书架分组：$label',
      child: Tooltip(
        message: '书架分组：$label',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(ShelfTokens.radiusChip),
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(ShelfTokens.radiusChip),
              border: border,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.folder,
                  size: ShelfTokens.iconInline,
                  color: accent ? HomePalette.accent : palette.muted,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: ShelfTokens.subtitle,
                      fontWeight: FontWeight.w500,
                      color: accent ? HomePalette.accent : palette.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
    this.headerHeight = 0,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final Key? actionKey;
  final VoidCallback? onAction;
  final VoidCallback? onCachedBooks;

  /// 列表上方的动态头部高度（筛选状态栏 / 缓存扫描行）。空态锚点以固定
  /// 头部（tab + toolbar）为基准：动态头部把内容区下推 X、高度压缩 X，
  /// Align(−0.2) 锚点随之多沉 0.6X，比无动态头部的界面低 0.6 ×
  /// headerHeight。补偿用底部垫空隙实现（见 build 注释），与屏高无关，
  /// 且不能用 LayoutBuilder 换算 —— SliverFillRemaining 会查询
  /// intrinsic dimensions，LayoutBuilder 不支持。
  final double headerHeight;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    // Slightly above the geometric center: the header (tabs + toolbar) already
    // occupies ~110dp, so a plain Center would sink the notice below the
    // screen's visual center.
    //
    // Compensation geometry: the dynamic rows push the -0.2 anchor down by
    // 0.6 × headerHeight. Padding the block by P at the bottom lifts the
    // notice's own center by P/2 − 0.1P = 0.4P (the 0.1 factor comes from
    // the -0.2 alignment scaling with block height), so 0.4P = 0.6 ×
    // headerHeight → P = 1.5 × headerHeight restores the exact same
    // on-screen center as the views without dynamic rows.
    return Align(
      alignment: const Alignment(0, -0.2),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          ShelfTokens.screenPadding,
          ShelfTokens.screenPadding,
          ShelfTokens.screenPadding,
          ShelfTokens.screenPadding + 1.5 * headerHeight,
        ),
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
