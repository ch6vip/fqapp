import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../widgets/home/home_design.dart';
import 'about_page.dart';
import 'cached_books_page.dart';
import 'cached_dramas_page.dart';
import 'settings_page.dart';
import 'stats_page.dart';

/// 个人中心（我的）页：书友卡片 + 快捷入口 + 嵌入式阅读与视听统计。
class MinePage extends StatelessWidget {
  const MinePage({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);

    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: const Text('我的'),
        centerTitle: false,
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
          color: palette.primary,
        ),
        iconTheme: IconThemeData(color: palette.primary),
      ),
      body: StatsPage(header: _profileHeader(context, palette)),
    );
  }

  Widget _profileHeader(BuildContext context, HomePalette palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HomeSpace.gutter),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '书友',
                  style: TextStyle(
                    fontSize: 26,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    color: palette.primary,
                  ),
                ),
              ),
              _QuietButton(
                icon: LucideIcons.sliders_horizontal,
                label: '设置',
                onTap: () => _open(context, const SettingsPage()),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HomeSpace.gutter),
          child: Text(
            '沉浸阅读，记录每一个好故事',
            style: TextStyle(fontSize: 13, color: palette.secondary),
          ),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HomeSpace.gutter),
          child: Row(
            children: [
              Expanded(
                child: _Shortcut(
                  icon: LucideIcons.bookmark,
                  label: '章节缓存',
                  palette: palette,
                  onTap: () => _open(context, const CachedBooksPage()),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Shortcut(
                  icon: LucideIcons.film,
                  label: '剧集缓存',
                  palette: palette,
                  onTap: () => _open(context, const CachedDramasPage()),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Shortcut(
                  icon: LucideIcons.sliders_horizontal,
                  label: '应用设置',
                  palette: palette,
                  onTap: () => _open(context, const SettingsPage()),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Shortcut(
                  icon: LucideIcons.info,
                  label: '关于我们',
                  palette: palette,
                  onTap: () => _open(context, const AboutPage()),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HomeSpace.gutter,
            28,
            HomeSpace.gutter,
            8,
          ),
          child: Text(
            '阅读与视听统计',
            style: HomeType.section.copyWith(color: palette.primary),
          ),
        ),
      ],
    );
  }

  void _open(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }
}

class _QuietButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _QuietButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Material(
      color: palette.chipBg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: palette.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: palette.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Shortcut extends StatelessWidget {
  final IconData icon;
  final String label;
  final HomePalette palette;
  final VoidCallback onTap;

  const _Shortcut({
    required this.icon,
    required this.label,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: palette.chipBg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: palette.primary),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: palette.secondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
