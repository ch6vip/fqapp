import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../services/app_theme.dart';
import '../services/backend_service.dart';
import '../services/library_store.dart';
import '../widgets/reading_goal_dialog.dart';
import 'about_page.dart';
import 'cached_books_page.dart';
import 'settings_category_page.dart';

/// Settings home: a list of category entries (PiliPlus multi-level
/// navigation). Each category opens its own CommonSetting-style page.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    final categories = <SettingsCategory>[
      SettingsCategory(
        icon: Icons.palette_outlined,
        title: '外观',
        subtitle: '深色模式',
        items: [_themeModeItem()],
      ),
      SettingsCategory(
        icon: Icons.menu_book_outlined,
        title: '阅读',
        subtitle: '每日阅读目标',
        items: [_goalItem()],
      ),
      SettingsCategory(
        icon: Icons.storage_outlined,
        title: '数据',
        subtitle: '章节缓存、阅读与播放历史',
        items: [
          SettingsItem(
            icon: Icons.download_for_offline_outlined,
            title: '章节缓存',
            subtitle: '离线续读、查看占用和清理缓存',
            onTap: (context, setState) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CachedBooksPage()),
            ),
          ),
          _clearHistItem(),
        ],
      ),
      SettingsCategory(
        icon: Icons.memory,
        title: '服务',
        subtitle: '本地后端状态',
        items: [_backendItem(), _statusItem()],
      ),
      SettingsCategory(
        icon: Icons.info_outline,
        title: '关于',
        subtitle: '版本与应用信息',
        pageBuilder: (_) => const AboutPage(),
        items: const [],
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('设置'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < categories.length; i++) ...[
                  if (i > 0) Divider(height: 1, indent: 56),
                  ListTile(
                    leading: Icon(
                      categories[i].icon,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text(
                      categories[i].title,
                      style: theme.textTheme.titleMedium,
                    ),
                    subtitle: Text(
                      categories[i].subtitle,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: outline,
                      ),
                    ),
                    trailing: Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: outline,
                    ),
                    onTap: () {
                      final cat = categories[i];
                      final pageBuilder = cat.pageBuilder;
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder:
                              pageBuilder ??
                              (_) => SettingsCategoryPage(
                                title: cat.title,
                                items: cat.items,
                              ),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 外观 ──────────────────────────────────────────────────────────────

  SettingsItem _themeModeItem() => SettingsItem(
    icon: Icons.brightness_6_outlined,
    title: '深色模式',
    trailingBuilder: (context) => ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _modeLabel(mode),
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
          const Icon(Icons.chevron_right, size: 20),
        ],
      ),
    ),
    onTap: (context, setState) => _showThemeModeDialog(context),
  );

  String _modeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
      case ThemeMode.system:
        return '跟随系统';
    }
  }

  Future<void> _showThemeModeDialog(BuildContext context) async {
    final selected = await showDialog<ThemeMode>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('深色模式'),
        children: [
          RadioGroup<ThemeMode>(
            groupValue: themeModeNotifier.value,
            onChanged: (v) {
              if (v != null) Navigator.pop(c, v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final m in const [
                  ThemeMode.system,
                  ThemeMode.light,
                  ThemeMode.dark,
                ])
                  RadioListTile<ThemeMode>(
                    value: m,
                    title: Text(_modeLabel(m)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null) return;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(themeModeKey, selected.name);
    themeModeNotifier.value = selected;
  }

  // ── 阅读 ──────────────────────────────────────────────────────────────

  SettingsItem _goalItem() => SettingsItem(
    icon: Icons.track_changes_outlined,
    title: '每日阅读目标',
    subtitle: '设置每日阅读时长目标',
    onTap: (context, setState) => _editGoal(context),
  );

  Future<void> _editGoal(BuildContext context) async {
    final sp = await SharedPreferences.getInstance();
    if (!context.mounted) return;
    final current = sp.getInt('stats_daily_goal_minutes') ?? 30;
    final value = await showReadingGoalDialog(context, current);
    if (value != null) {
      await sp.setInt('stats_daily_goal_minutes', value);
    }
  }

  // ── 数据 ──────────────────────────────────────────────────────────────

  SettingsItem _clearHistItem() => SettingsItem(
    icon: Icons.history,
    title: '清空历史',
    subtitle: '删除全部阅读/播放记录',
    onTap: (context, setState) => _confirmClear(
      context,
      '清空历史',
      '确定清空全部阅读/播放历史吗？',
      LibraryStore.instance.clearHistory,
    ),
  );

  Future<void> _confirmClear(
    BuildContext context,
    String title,
    String message,
    Future<void> Function() action,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await action();
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已清空')));
      }
    }
  }

  // ── 服务 ──────────────────────────────────────────────────────────────

  SettingsItem _backendItem() => SettingsItem(
    icon: Icons.memory,
    title: '本地后端',
    subtitle: BackendService.instance.baseUrl,
  );

  SettingsItem _statusItem() => SettingsItem(
    icon: Icons.check_circle_outline,
    title: '服务状态',
    rowBuilder: (context) => const _ServiceStatusRow(),
  );

  // ── 关于 ──────────────────────────────────────────────────────────────
  // The About category opens the About page directly via its pageBuilder;
  // no category-page items are needed.
}

/// Self-refreshing service status row (health check + refresh button).
class _ServiceStatusRow extends StatefulWidget {
  const _ServiceStatusRow();

  @override
  State<_ServiceStatusRow> createState() => _ServiceStatusRowState();
}

class _ServiceStatusRowState extends State<_ServiceStatusRow> {
  String _status = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final ok = await ApiClient.instance.health();
    if (!mounted) return;
    setState(() => _status = ok ? '运行中' : '已停止');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final healthy = _status == '运行中';
    return ListTile(
      leading: Icon(
        healthy ? Icons.check_circle_outline : Icons.error_outline,
        color: healthy ? Colors.green : Colors.red,
      ),
      title: Text('服务状态', style: theme.textTheme.titleMedium),
      subtitle: Text(
        _status,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.refresh),
        onPressed: _refresh,
      ),
    );
  }
}
