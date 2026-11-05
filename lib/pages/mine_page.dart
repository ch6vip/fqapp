import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../widgets/mine/mine_entries.dart';
import '../widgets/wenku/wenku_ui.dart';
import 'reading_statistics_page.dart';

/// 我的：沿用 Wenku8 Flutter 的档案页骨架，数据与路由接 fqapp 本地能力。
///
/// 本页不连接文库账号，也不展示云端同步或伪造书签数量。身份卡只说明这是
/// 本机阅读档案；统计仍是 fqapp 原有本地统计视图，单独放在独立路由中。
class MinePage extends StatelessWidget {
  const MinePage({super.key});

  @override
  Widget build(BuildContext context) {
    return WenkuPage(
      header: const Align(
        alignment: Alignment.centerLeft,
        child: ArchiveMasthead(title: '我的', code: '04 / PERSONAL ARCHIVE'),
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            key: const PageStorageKey('my-page'),
            padding: featurePadding(
              context,
            ).copyWith(bottom: DockLayout.scrollPaddingOf(context)),
            children: [
              const _LocalIdentityPanel(),
              const SizedBox(height: 24),
              FeatureEntry(
                key: const ValueKey('mine-statistics'),
                title: '统计',
                subtitle: '阅读记录、藏书与阅读时长',
                icon: CupertinoIcons.chart_bar,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const ReadingStatisticsPage(),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const MineEntries(),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalIdentityPanel extends StatelessWidget {
  const _LocalIdentityPanel();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ContentPanel(
      key: const ValueKey('mine-local-identity'),
      child: Row(
        children: [
          // 上游此处为 56×56 账号头像/品牌图；fqapp 没有账号模块，统一使用本地品牌图。
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.asset(
              'assets/images/app_logo.webp',
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              cacheWidth: (56 * MediaQuery.devicePixelRatioOf(context)).ceil(),
              cacheHeight: (56 * MediaQuery.devicePixelRatioOf(context)).ceil(),
              excludeFromSemantics: true,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '什锦铺',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 7),
                Text(
                  '本地阅读档案 · 小说、短剧、漫画与听书',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          // 上游卡片可进入账号页并带 8/14 右箭头；本卡无跳转，故不画箭头。
        ],
      ),
    );
  }
}
