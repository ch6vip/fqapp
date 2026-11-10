// Settings category container.
//
// Layout ported from Wenku8_Flutter (revision ebcd7f1) `lib/pages.dart`
// SettingsPage._sectionEntry + ArchiveFeaturePage option lists:
//   ArchiveFeaturePage(title, code) with a ContentPanel of dividers.
//
// Mechanical substitutions:
// - `AppControls.toggle` / `GlassSettingMenu` are provided by fqapp's ported
//   settings components (`lib/widgets/wenku/glass_controls.dart`,
//   `setting_menu.dart`) through `SettingsToggleRow` /
//   `GlassSettingMenu`.
// - `ArchiveFeaturePage` -> `SettingsArchivePage`, which renders the same
//   header but omits the back button when the nearest Navigator has no route
//   to pop (the Windows two-pane shell).
// - The page keeps fqapp's `SettingsCategory` / `SettingsItem` data model so
//   the Windows two-pane [DesktopSettingsBody] keeps working unchanged.
// - `rowBuilder` is an fqapp addition: settings rows whose control is a
//   full-width `GlassSettingMenu` cannot be expressed as a trailing widget.
//   It renders exactly the upstream row shape inside the shared panel.

import 'package:flutter/cupertino.dart';

import '../services/app_style_tokens.dart';
import '../widgets/settings/classic_settings_icons.dart';
import '../widgets/settings/settings_widgets.dart';

import '../widgets/settings/settings_archive_page.dart';
import '../widgets/settings/settings_archive_rows.dart';
import '../widgets/wenku/wenku_ui.dart';

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

  /// Full-width custom row (e.g. an upstream `GlassSettingMenu`). When set,
  /// the standard icon/title/trailing fields are ignored.
  final Widget Function(BuildContext context)? rowBuilder;

  const SettingsItem({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.trailingBuilder,
    this.onTap,
    this.rowBuilder,
  });
}

/// Archive address shown under a category title. fqapp category names are its
/// own; the upstream `SYSTEM / ...` vocabulary is kept for the ported chrome.
String settingsCategoryCode(String title) => switch (title) {
  '外观' => 'SYSTEM / APPEARANCE',
  '阅读' => 'SYSTEM / READING',
  '听书' => 'SYSTEM / LISTENING',
  '短剧' => 'SYSTEM / DRAMA',
  '数据' => 'SYSTEM / STORAGE',
  '服务' => 'SYSTEM / SERVICE',
  '关于' => 'SYSTEM / ABOUT',
  _ => 'SYSTEM / SETTINGS',
};

/// The per-category settings page: archive masthead + one panel of setting
/// rows, matching upstream `ArchiveFeaturePage` option lists.
class SettingsCategoryPage extends StatefulWidget {
  final String title;
  final List<SettingsItem> items;

  /// 固定行 items 之外的可选来源：每次 build 重新生成，响应主题 / 墨水屏等
  /// 全局偏好变化（OLED 行会随深色外观出现或消失）。
  final List<SettingsItem> Function(BuildContext context)? itemsBuilder;

  final String? code;

  const SettingsCategoryPage({
    super.key,
    required this.title,
    this.items = const [],
    this.itemsBuilder,
    this.code,
  });

  @override
  State<SettingsCategoryPage> createState() => _SettingsCategoryPageState();
}

class _SettingsCategoryPageState extends State<SettingsCategoryPage> {
  @override
  Widget build(BuildContext context) {
    final items = widget.itemsBuilder?.call(context) ?? widget.items;
    if (AppStyleTokens.of(context).isClassic) {
      return SettingsScaffold(
        title: widget.title,
        body: ListView(
          key: PageStorageKey('settings-category-classic-${widget.title}'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            SettingsGroupCard(
              children: [for (final item in items) _buildItem(item)],
            ),
          ],
        ),
      );
    }
    return SettingsArchivePage(
      title: widget.title,
      code: widget.code ?? settingsCategoryCode(widget.title),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            key: PageStorageKey('settings-category-${widget.title}'),
            padding: featurePadding(context).add(
              EdgeInsets.only(
                left: MediaQuery.paddingOf(context).left,
                right: MediaQuery.paddingOf(context).right,
              ),
            ),
            children: [
              SettingsPanel(
                children: [for (final item in items) _buildItem(item)],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItem(SettingsItem item) {
    final rowBuilder = item.rowBuilder;
    if (rowBuilder != null) return rowBuilder(context);
    final trailing = item.trailingBuilder?.call(context) ?? item.trailing;
    if (AppStyleTokens.of(context).isClassic) {
      return SettingsRow(
        icon: classicSettingsIcon(item.title, item.icon),
        iconTile: true,
        title: item.title,
        subtitle: item.subtitle,
        trailing: trailing,
        onTap: item.onTap == null ? null : () => item.onTap!(context, setState),
      );
    }
    return SettingsLinkRow(
      icon: item.icon,
      title: item.title,
      subtitle: item.subtitle,
      trailing: trailing,
      onTap: item.onTap == null ? null : () => item.onTap!(context, setState),
    );
  }
}

/// Upstream settings rows use Cupertino glyphs; the home page maps fqapp
/// category icons here so category entries and their rows share a vocabulary.
abstract final class SettingsCategoryIcons {
  static const appearance = CupertinoIcons.paintbrush;
  static const reading = CupertinoIcons.book;
  static const listening = CupertinoIcons.waveform;
  static const drama = CupertinoIcons.play_rectangle;
  static const data = CupertinoIcons.folder;
  static const service = CupertinoIcons.wifi;
  static const about = CupertinoIcons.info;
}
