// Ported from Wenku8_Flutter (revision ebcd7f1) notice grammar:
//   `lib/app_ui.dart` ContentNotice (34dp ambient ArchiveIcon, 17sp title,
//   thin-line message) and the archive empty-state composition.
//
// fqapp additions:
// - The three existing empty-state classes keep their names, copy and action
//   keys (`shelf-browse-button`, `shelf-cached-books-button`,
//   `collection-find-drama-button`); only the visual grammar changes from the
//   old HomePalette icon brick to the archive notice.
// - `ShelfFilteredEmptyState` is new: a filtered-to-nothing state with a
//   `shelf-clear-filters` action.

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../wenku/src/app_text.dart';
import '../wenku/wenku_glass.dart';
import '../wenku/wenku_icons.dart';

/// The shared archive notice: 34dp ambient icon, 17sp title, 12sp message.
Widget _archiveNotice(
  BuildContext context, {
  required IconData icon,
  required String title,
  String? message,
  List<Widget> actions = const [],
}) => Center(
  child: SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ArchiveIcon(
          icon,
          ambient: true,
          size: 34,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 16),
        AppText(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        if (message != null) ...[
          const SizedBox(height: 8),
          AppText(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (actions.isNotEmpty) ...[const SizedBox(height: 16), ...actions],
      ],
    ),
  ),
);

/// 空书架（官方文案延续）：书架暂无书籍 + 去书城找书。
///
/// [onCachedBooks] 非空时多给一条「查看离线缓存」：书架空、又断网时
/// 「去书城找书」是条死路，而用户手里可能正好有下载好的内容。
class ShelfEmptyState extends StatelessWidget {
  final VoidCallback? onBrowse;
  final VoidCallback? onCachedBooks;

  const ShelfEmptyState({super.key, this.onBrowse, this.onCachedBooks});

  @override
  Widget build(BuildContext context) => _archiveNotice(
    context,
    icon: LucideIcons.book_open,
    title: '书架暂无书籍',
    message: '去书城发现海量故事，随时随地畅读',
    actions: [
      GlassPillButton(
        key: const Key('shelf-browse-button'),
        icon: LucideIcons.compass,
        label: '去书城找书',
        onPressed: onBrowse,
      ),
      if (onCachedBooks != null)
        GlassTextButton(
          key: const Key('shelf-cached-books-button'),
          onPressed: onCachedBooks,
          child: const AppText('查看离线缓存'),
        ),
    ],
  );
}

/// 收藏 tab 空态（官方收藏页形态）：文案随筛选变化（暂无短剧 / 暂无
/// 漫剧 / 暂无收藏内容），下方给「找短剧」入口切到短剧 tab。
class ShelfCollectionEmptyState extends StatelessWidget {
  final String text;
  final VoidCallback? onFindDrama;

  const ShelfCollectionEmptyState({
    super.key,
    required this.text,
    this.onFindDrama,
  });

  @override
  Widget build(BuildContext context) => _archiveNotice(
    context,
    icon: LucideIcons.clapperboard,
    title: text,
    actions: [
      GlassPillButton(
        key: const Key('collection-find-drama-button'),
        icon: LucideIcons.clapperboard,
        label: '找短剧',
        onPressed: onFindDrama,
      ),
    ],
  );
}

/// 官方通用空态文案（RecyclerBookLayoutV2）：空历史 / 筛选无结果。
class ShelfEmptyHint extends StatelessWidget {
  final String text;

  const ShelfEmptyHint({super.key, required this.text});

  @override
  Widget build(BuildContext context) =>
      _archiveNotice(context, icon: LucideIcons.search_x, title: text);
}

/// 筛选后无结果：给一条明确的「清除筛选」出口，避免用户以为书架空了。
class ShelfFilteredEmptyState extends StatelessWidget {
  final String text;
  final VoidCallback? onClearFilters;

  const ShelfFilteredEmptyState({
    super.key,
    required this.text,
    this.onClearFilters,
  });

  @override
  Widget build(BuildContext context) => _archiveNotice(
    context,
    icon: LucideIcons.search_x,
    title: text,
    actions: [
      GlassTextButton(
        key: const Key('shelf-clear-filters'),
        onPressed: onClearFilters,
        child: const AppText('清除筛选'),
      ),
    ],
  );
}
