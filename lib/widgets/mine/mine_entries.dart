import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../pages/about_page.dart';
import '../../pages/cached_books_page.dart';
import '../../pages/cached_dramas_page.dart';
import '../../pages/library_backup_page.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';

/// 我的 页底部的入口列表：离线缓存 / 备份与导入 / 关于。应用设置在标题栏齿轮。
class MineEntries extends StatelessWidget {
  const MineEntries({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: homeSectionGap),
      child: Column(
        children: [
          Divider(height: 1, thickness: 0.6, color: palette.line),
          MineEntryRow(
            icon: LucideIcons.hard_drive_download,
            label: '离线缓存',
            onTap: () => _showCacheChoices(context),
          ),
          MineEntryRow(
            icon: LucideIcons.archive_restore,
            label: '备份与导入',
            onTap: () => _push(context, const LibraryBackupPage()),
          ),
          MineEntryRow(
            icon: LucideIcons.info,
            label: '关于',
            onTap: () => _push(context, const AboutPage()),
          ),
        ],
      ),
    );
  }
}

void _push(BuildContext context, Widget page) =>
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));

/// 小说章节和短剧剧集是两套缓存，各自有管理页；这里只做分流。
Future<void> _showCacheChoices(BuildContext context) {
  final palette = HomePalette.of(context);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: palette.surface,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MineEntryRow(
            icon: LucideIcons.book_open,
            label: '小说章节',
            onTap: () {
              Navigator.pop(sheet);
              _push(context, const CachedBooksPage());
            },
          ),
          MineEntryRow(
            icon: LucideIcons.clapperboard,
            label: '短剧剧集',
            onTap: () {
              Navigator.pop(sheet);
              _push(context, const CachedDramasPage());
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

class MineEntryRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const MineEntryRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomePressable(
      onTap: onTap,
      borderRadius: BorderRadius.zero,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: Row(
            children: [
              Icon(icon, size: 19, color: palette.ink),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.3,
                    color: palette.ink,
                  ),
                ),
              ),
              Icon(LucideIcons.chevron_right, size: 16, color: palette.muted),
            ],
          ),
        ),
      ),
    );
  }
}
