import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../widgets/home/home_design.dart';
import 'about_page.dart';
import 'cached_books_page.dart';
import 'cached_dramas_page.dart';
import 'settings_page.dart';
import 'stats_page.dart';

/// 个人中心（我的）页：顶部书友卡片 + 快捷入口（章节缓存/剧集缓存/设置/关于）
/// + 嵌入式阅读与视听统计。
class MinePage extends StatelessWidget {
  const MinePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = HomePalette.of(context);

    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: const Text('我的'),
        centerTitle: false,
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.settings),
            tooltip: '设置',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: StatsPage(
        header: _buildProfileHeader(context, scheme, palette),
      ),
    );
  }

  Widget _buildProfileHeader(
    BuildContext context,
    ColorScheme scheme,
    HomePalette palette,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 个人概览卡片
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.line, width: 0.6),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFEF5038), Color(0xFFF27A65)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: HomePalette.accent.withValues(alpha: 0.22),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  LucideIcons.circle_user_round,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '番茄书友',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '沉浸阅读，记录每一个好故事',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: palette.muted,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsPage()),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: palette.soft,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: palette.line, width: 0.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.sliders_horizontal,
                        size: 13,
                        color: palette.accentText,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '设置',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: palette.accentText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 4个快捷入口
        Row(
          children: [
            _buildShortcutTile(
              context: context,
              icon: LucideIcons.book_marked,
              iconColor: const Color(0xFF3B82F6),
              label: '章节缓存',
              palette: palette,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CachedBooksPage()),
              ),
            ),
            const SizedBox(width: 8),
            _buildShortcutTile(
              context: context,
              icon: LucideIcons.film,
              iconColor: const Color(0xFFEF5038),
              label: '剧集缓存',
              palette: palette,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CachedDramasPage()),
              ),
            ),
            const SizedBox(width: 8),
            _buildShortcutTile(
              context: context,
              icon: LucideIcons.sliders_horizontal,
              iconColor: const Color(0xFF10B981),
              label: '应用设置',
              palette: palette,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              ),
            ),
            const SizedBox(width: 8),
            _buildShortcutTile(
              context: context,
              icon: LucideIcons.info,
              iconColor: const Color(0xFF8B5CF6),
              label: '关于我们',
              palette: palette,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AboutPage()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Container(
              width: 3.5,
              height: 14,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: HomePalette.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(
              '阅读与视听统计',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: palette.ink,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildShortcutTile({
    required BuildContext context,
    required IconData icon,
    required Color iconColor,
    required String label,
    required HomePalette palette,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.line, width: 0.6),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 18, color: iconColor),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: palette.ink,
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
