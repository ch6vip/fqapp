import 'package:flutter/material.dart';

import '../widgets/home/home_design.dart';

/// PiliPlus-style settings category entry (shown on the settings home page).
class SettingsCategory {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<SettingsItem> items;

  /// 行会随全局偏好增删的分类（如外观的 OLED）用 builder：分类页每次重建
  /// 都重新生成行，否则主题切到深色后 OLED 行要退出重进才能看到。
  final List<SettingsItem> Function(BuildContext context)? itemsBuilder;

  /// When set, tapping the category opens [pageBuilder] directly instead of
  /// the generic category page (e.g. the About entry jumps straight to the
  /// About page).
  final WidgetBuilder? pageBuilder;

  const SettingsCategory({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.items = const [],
    this.itemsBuilder,
    this.pageBuilder,
  });
}

/// One row inside a settings category page.
class SettingsItem {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget Function(BuildContext context)? trailingBuilder;

  /// When set, renders a fully custom row instead of the default ListTile.
  final Widget Function(BuildContext context)? rowBuilder;
  final void Function(BuildContext context, StateSetter setState)? onTap;

  const SettingsItem({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.trailingBuilder,
    this.rowBuilder,
    this.onTap,
  });
}

/// The per-category settings page (PiliPlus CommonSetting equivalent):
/// a titled page rendering one rounded card of setting rows.
class SettingsCategoryPage extends StatefulWidget {
  final String title;
  final List<SettingsItem> items;

  /// 固定行 items 之外的可选来源：每次 build 重新生成，响应主题 / 墨水屏等
  /// 全局偏好变化（OLED 行会随深色外观出现或消失）。
  final List<SettingsItem> Function(BuildContext context)? itemsBuilder;

  const SettingsCategoryPage({
    super.key,
    required this.title,
    this.items = const [],
    this.itemsBuilder,
  });

  @override
  State<SettingsCategoryPage> createState() => _SettingsCategoryPageState();
}

class _SettingsCategoryPageState extends State<SettingsCategoryPage> {
  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final items = widget.itemsBuilder?.call(context) ?? widget.items;
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: Text(widget.title),
        centerTitle: true,
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          Material(
            color: palette.surface,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: palette.line,
                  width: 0.6,
                ),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        indent: 68,
                        color: palette.line,
                      ),
                    _buildRow(items[i]),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(SettingsItem item) {
    final rowBuilder = item.rowBuilder;
    if (rowBuilder != null) return rowBuilder(context);
    final palette = HomePalette.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      onTap: item.onTap == null ? null : () => item.onTap!(context, setState),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: HomePalette.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(item.icon, size: 20, color: HomePalette.accent),
      ),
      title: Text(
        item.title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
          color: palette.ink,
        ),
      ),
      subtitle: item.subtitle == null
          ? null
          : Text(
              item.subtitle!,
              style: TextStyle(
                fontSize: 12.5,
                color: palette.muted,
              ),
            ),
      trailing: item.trailingBuilder?.call(context) ?? item.trailing,
    );
  }
}
