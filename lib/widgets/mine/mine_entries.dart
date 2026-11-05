import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../pages/about_page.dart';
import '../../pages/cached_books_page.dart';
import '../../pages/cached_dramas_page.dart';
import '../../pages/library_backup_page.dart';
import '../../pages/settings_page.dart';
import '../home/home_sheet.dart';
import '../wenku/wenku_ui.dart';

/// “我的”页的入口卡片，顺序沿用 Wenku8 Flutter 的设置／数据分层。
class MineEntries extends StatelessWidget {
  const MineEntries({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FeatureEntry(
          key: const ValueKey('mine-settings'),
          title: '设置',
          subtitle: '阅读、外观、播放与本地数据',
          icon: CupertinoIcons.settings,
          onTap: () => _push(context, const SettingsPage()),
        ),
        const SizedBox(height: 14),
        FeatureEntry(
          key: const ValueKey('mine-cache'),
          title: '离线缓存',
          subtitle: '管理小说与短剧的离线内容',
          icon: CupertinoIcons.tray_arrow_down,
          onTap: () => _showCacheChoices(context),
        ),
        const SizedBox(height: 14),
        FeatureEntry(
          key: const ValueKey('mine-backup'),
          title: '备份与导入',
          subtitle: '本机备份、恢复与外部书架导入',
          icon: CupertinoIcons.archivebox,
          onTap: () => _push(context, const LibraryBackupPage()),
        ),
        const SizedBox(height: 14),
        // 上游“关于”副标题显示版本与更新状态；fqapp 没有 AppUpdates 模块，
        // 这里用静态说明替代。
        FeatureEntry(
          key: const ValueKey('mine-about'),
          title: '关于',
          subtitle: '版本与应用信息',
          icon: CupertinoIcons.info_circle,
          onTap: () => _push(context, const AboutPage()),
        ),
      ],
    );
  }
}

void _push(BuildContext context, Widget page) =>
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));

/// 小说与短剧使用两套缓存存储，入口仍先让用户选择要管理的类型。
Future<void> _showCacheChoices(BuildContext context) async {
  await showHomeSheet<void>(
    context: context,
    title: '离线缓存',
    contentPadding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
    children: [
      FeatureEntry(
        title: '小说离线缓存',
        subtitle: '离线续读、查看占用和清理缓存',
        icon: CupertinoIcons.book,
        onTap: () {
          Navigator.pop(context);
          _push(context, const CachedBooksPage());
        },
      ),
      const SizedBox(height: 14),
      FeatureEntry(
        title: '短剧离线缓存',
        subtitle: '短剧下载、离线播放和清理缓存',
        icon: CupertinoIcons.play_rectangle,
        onTap: () {
          Navigator.pop(context);
          _push(context, const CachedDramasPage());
        },
      ),
      const SizedBox(height: 8),
    ],
  );
}
