import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_theme.dart';
import '../services/app_theme_style.dart';
import '../services/app_style_tokens.dart';
import '../widgets/wenku/wenku_ui.dart';

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
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '主题',
    code: 'APPEARANCE / THEME',
    child: ValueListenableBuilder<AppThemeStyle>(
      valueListenable: _store,
      builder: (context, selected, _) => ListView(
        key: const PageStorageKey('theme-selection'),
        padding: featurePadding(context),
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
            '主题不改变书架布局、阅读配色或数据。深色、墨水屏和 OLED 设置保持不变。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    ),
  );
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
                    child: ContentPanel(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 48,
                            height: 64,
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(
                                tokens.coverRadius,
                              ),
                            ),
                            child: Icon(Icons.menu_book, color: scheme.primary),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (tokens.showDecorativeCodes) ...[
                                  const ArchiveCode('01 / READING'),
                                  const SizedBox(height: 4),
                                ],
                                const Text(
                                  '继续阅读',
                                  style: TextStyle(fontWeight: FontWeight.w600),
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
