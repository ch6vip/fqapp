import 'package:flutter/material.dart';

import '../widgets/home/home_design.dart';

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
    final palette = HomePalette.of(context);
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
                  for (var i = 0; i < widget.items.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        indent: 68,
                        color: palette.line,
                      ),
                    _buildRow(widget.items[i]),
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
