import 'package:flutter/material.dart';

import '../widgets/settings/settings_widgets.dart';

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
  final void Function(BuildContext context, StateSetter setState)? onTap;

  const SettingsItem({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.trailingBuilder,
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
    final items = widget.itemsBuilder?.call(context) ?? widget.items;
    return SettingsScaffold(
      title: widget.title,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          SettingsGroupCard(
            children: [for (final item in items) _buildRow(item)],
          ),
        ],
      ),
    );
  }

  Widget _buildRow(SettingsItem item) {
    final trailing = item.trailingBuilder?.call(context) ?? item.trailing;
    return SettingsRow(
      icon: item.icon,
      iconTile: true,
      title: item.title,
      subtitle: item.subtitle,
      trailing: trailing,
      onTap: item.onTap == null ? null : () => item.onTap!(context, setState),
    );
  }
}
