import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_archive.dart';
import 'home_design.dart';

/// 书城顶栏：店名、档案编号、右端两个轻量入口（搜索 / 分类）。
///
/// 2026-11 首页重做后不再有搜索胶囊和热搜轮换：顶栏只留身份和两个动作，
/// 热搜词仍在搜索页里。高度固定，不随内容滚动。
class HomeMasthead extends StatelessWidget {
  /// 应用名（`android:label` 同值）。
  static const String brand = '什锦铺';

  /// 店名下面的档案编号，纯装饰性的识别行。
  static const String brandCode = 'SHIJINPU / STORY ARCHIVE';

  static const double actionSize = 36;

  final VoidCallback onSearch;

  /// 分类入口。null 时不占位。
  final VoidCallback? onCategory;

  const HomeMasthead({super.key, required this.onSearch, this.onCategory});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  brand,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 20,
                    height: 1.18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(height: 3),
                const HomeCode(brandCode, size: 8),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _HeaderAction(
            key: const Key('home_search_button'),
            icon: LucideIcons.search,
            label: '搜索',
            palette: palette,
            onTap: onSearch,
          ),
          if (onCategory != null) ...[
            const SizedBox(width: 8),
            _HeaderAction(
              key: const Key('home_category_button'),
              icon: LucideIcons.layout_grid,
              label: '分类',
              palette: palette,
              onTap: onCategory!,
            ),
          ],
        ],
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    super.key,
    required this.icon,
    required this.label,
    required this.palette,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final HomePalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: HomePressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HomeMasthead.actionSize / 2),
        semanticLabel: label,
        child: SizedBox.square(
          dimension: HomeMasthead.actionSize,
          child: Icon(icon, size: 19, color: palette.ink),
        ),
      ),
    );
  }
}
