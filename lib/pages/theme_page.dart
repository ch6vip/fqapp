import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_theme.dart';
import '../services/app_theme_style.dart';
import '../services/app_style_tokens.dart';
import '../widgets/wenku/wenku_ui.dart';
import '../widgets/settings/settings_widgets.dart';

/// Built-in app themes share every route and data store. Preview cards use
/// their own theme without changing the surrounding route until selected.
class ThemePage extends StatefulWidget {
  const ThemePage({super.key, this.store});

  final AppThemeStyleStore? store;

  @override
  State<ThemePage> createState() => _ThemePageState();
}

class _ThemePageState extends State<ThemePage> {
  AppThemeStyleStore get _store => widget.store ?? AppThemeStyleStore.instance;
  int _selection = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_store.load());
  }

  Future<void> _select(AppThemeStyle style) async {
    final selection = ++_selection;
    final saved = await _store.select(style);
    if (!mounted || selection != _selection || saved) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('主题已切换，但未能保存。请重试。')));
  }

  @override
  Widget build(BuildContext context) {
    final classic = AppStyleTokens.of(context).isClassic;
    final body = ValueListenableBuilder<AppThemeStyle>(
      valueListenable: _store,
      builder: (context, selected, _) => ListView(
        key: const PageStorageKey('theme-selection'),
        padding: classic
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
            : featurePadding(context),
        children: [
          const Text('选一个喜欢的界面，点选即生效。'),
          const SizedBox(height: 16),
          for (final style in AppThemeStyle.values) ...[
            _ThemeChoice(
              style: style,
              selected: selected == style,
              onTap: () => unawaited(_select(style)),
            ),
            const SizedBox(height: 16),
          ],
          Text(
            '经典主题恢复老版首页、封面书架、阅读统计和设置列表。两套书架布局分别记忆，阅读配色与数据保持不变。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
    return classic
        ? SettingsScaffold(title: '主题', body: body)
        : ArchiveFeaturePage(
            title: '主题',
            code: 'APPEARANCE / THEME',
            child: body,
          );
  }
}

class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({
    required this.style,
    required this.selected,
    required this.onTap,
  });

  final AppThemeStyle style;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final outer = Theme.of(context);
    final theme = WenkuTheme.create(
      outer.brightness,
      eink: einkModeNotifier.value,
      oled: oledActive(systemBrightness: outer.brightness),
      highContrast: MediaQuery.highContrastOf(context),
      style: style,
    );
    final tokens = AppStyleTokens.forStyle(style);
    final scheme = theme.colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(tokens.panelRadius),
      side: BorderSide(
        color: selected ? outer.colorScheme.primary : outer.dividerColor,
        width: selected ? 2 : 1,
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: style.label,
      child: Theme(
        data: theme,
        child: Material(
          color: theme.scaffoldBackgroundColor,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('theme-choice-${style.name}'),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          style.label,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        selected ? Icons.check_circle : Icons.circle_outlined,
                        key: ValueKey('theme-selected-${style.name}-$selected'),
                        color: selected
                            ? outer.colorScheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    style.description,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  // A real themed panel previews corners, spacing and code
                  // visibility. No network images or private library data.
                  ExcludeSemantics(
                    child: style == AppThemeStyle.classic
                        ? _ClassicPreview(scheme: scheme)
                        : ContentPanel(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 48,
                                  height: 64,
                                  decoration: BoxDecoration(
                                    color: scheme.primary.withValues(
                                      alpha: .12,
                                    ),
                                    borderRadius: BorderRadius.circular(
                                      tokens.coverRadius,
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.menu_book,
                                    color: scheme.primary,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (tokens.showDecorativeCodes) ...[
                                        const ArchiveCode('01 / READING'),
                                        const SizedBox(height: 4),
                                      ],
                                      const Text(
                                        '继续阅读',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '书名与进度，一目了然',
                                        style: TextStyle(
                                          color: scheme.onSurfaceVariant,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Preview of the original structure, not a rounded archive content panel.
class _ClassicPreview extends StatelessWidget {
  const _ClassicPreview({required this.scheme});
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.search, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('搜索书名或作者', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      const Text('排行榜', style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Row(
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(
              child: Container(
                height: 64,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: .08 + i * .03),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(
                    'TOP ${i + 1}',
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ],
  );
}
