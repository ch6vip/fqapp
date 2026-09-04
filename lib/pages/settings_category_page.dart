import 'package:flutter/material.dart';

/// PiliPlus-style settings category entry (shown on the settings home page).
class SettingsCategory {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<SettingsItem> items;
  /// When set, tapping the category opens [pageBuilder] directly instead of
  /// the generic category page (e.g. the About entry jumps straight to the
  /// About page).
  final WidgetBuilder? pageBuilder;

  const SettingsCategory({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.items,
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

  const SettingsCategoryPage({
    super.key,
    required this.title,
    required this.items,
  });

  @override
  State<SettingsCategoryPage> createState() => _SettingsCategoryPageState();
}

class _SettingsCategoryPageState extends State<SettingsCategoryPage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < widget.items.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 56),
                  _buildRow(widget.items[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(SettingsItem item) {
    final rowBuilder = item.rowBuilder;
    if (rowBuilder != null) return rowBuilder(context);
    final theme = Theme.of(context);
    return ListTile(
      onTap: item.onTap == null
          ? null
          : () => item.onTap!(context, setState),
      leading: Icon(item.icon, color: theme.colorScheme.primary),
      title: Text(item.title, style: theme.textTheme.titleMedium),
      subtitle: item.subtitle == null
          ? null
          : Text(
              item.subtitle!,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
      trailing: item.trailingBuilder?.call(context) ?? item.trailing,
    );
  }
}
