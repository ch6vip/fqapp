import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_theme.dart';
import '../services/app_theme_style.dart';
import '../services/app_style_tokens.dart';
import '../widgets/settings/settings_widgets.dart';
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
  Widget build(BuildContext context) {
    final classic = AppStyleTokens.of(context).isClassic;
    final body = ValueListenableBuilder<AppThemeStyle>(
      valueListenable: _store,
      builder: (context, selected, _) => _ThemeBody(
        selected: selected,
        onSelect: (style) => unawaited(_select(style)),
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

/// Two miniature screens side by side, so both styles can be compared without
/// scrolling. Narrow or large-text layouts fall back to one column.
class _ThemeBody extends StatelessWidget {
  const _ThemeBody({required this.selected, required this.onSelect});

  final AppThemeStyle selected;
  final ValueChanged<AppThemeStyle> onSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = AppStyleTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final classic = tokens.isClassic;
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = classic ? 16.0 : tokens.pageGutter;
        final available = constraints.maxWidth - gutter * 2;
        // Below ~300dp of content, or with enlarged text, the two labels no
        // longer fit their cards; stack them instead of truncating.
        final twoUp =
            available >= 300 &&
            MediaQuery.textScalerOf(context).scale(14) <= 19;
        final cards = [
          for (final style in AppThemeStyle.values)
            _ThemeChoice(
              style: style,
              selected: selected == style,
              onTap: () => onSelect(style),
            ),
        ];
        return ListView(
          key: const PageStorageKey('theme-selection'),
          padding: EdgeInsets.fromLTRB(
            gutter,
            classic
                ? 12
                : MediaQuery.paddingOf(context).top +
                      FrostedHeader.toolbarHeight +
                      20,
            gutter,
            MediaQuery.paddingOf(context).bottom + 32,
          ),
          children: [
            Text(
              '选择界面风格',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '点选即生效，随时可以换回。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (twoUp)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 12),
                  Expanded(child: cards[1]),
                ],
              )
            else ...[
              cards[0],
              const SizedBox(height: 12),
              cards[1],
            ],
            const SizedBox(height: 20),
            _Footnote(tokens: tokens),
          ],
        );
      },
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
    final radius = BorderRadius.circular(tokens.isClassic ? 16 : 6);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: '${style.label}，${style.description}',
      child: Theme(
        data: theme,
        child: Material(
          color: theme.scaffoldBackgroundColor,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(
              color: selected ? outer.colorScheme.primary : outer.dividerColor,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('theme-choice-${style.name}'),
            onTap: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 200 / 276,
                  child: ExcludeSemantics(
                    child: _MiniScreen(style: style, scheme: scheme),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              style.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            key: ValueKey(
                              'theme-selected-${style.name}-$selected',
                            ),
                            size: 18,
                            color: selected
                                ? outer.colorScheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        style.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.35,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A 200×276 miniature of each home screen, scaled to the card. Drawn from
/// blocks rather than screenshots so it follows the live palette (light, dark,
/// OLED, e-ink) and never depends on network images or library data.
class _MiniScreen extends StatelessWidget {
  const _MiniScreen({required this.style, required this.scheme});

  final AppThemeStyle style;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) => MediaQuery.withNoTextScaling(
    child: FittedBox(
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: 200,
        height: 276,
        child: style == AppThemeStyle.classic
            ? _ClassicMini(scheme: scheme)
            : _ArchiveMini(scheme: scheme),
      ),
    ),
  );
}

class _ClassicMini extends StatelessWidget {
  const _ClassicMini({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final ink = scheme.onSurface;
    final muted = scheme.onSurfaceVariant;
    final accent = scheme.primary;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Search capsule, the first thing the old home screen showed.
                Container(
                  height: 24,
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Icon(Icons.search, size: 11, color: muted),
                      const SizedBox(width: 5),
                      _Bar(
                        width: 54,
                        height: 4,
                        color: muted.withValues(alpha: .45),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Bar(
                            width: i == 0 ? 20 : 16,
                            height: 5,
                            color: i == 0 ? ink : muted.withValues(alpha: .5),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            width: 12,
                            height: 2,
                            color: i == 0 ? accent : Colors.transparent,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                // Text-only continue row: no cover, exactly like the old build.
                _Bar(width: 92, height: 5, color: ink),
                const SizedBox(height: 5),
                _Bar(width: 60, height: 4, color: muted.withValues(alpha: .55)),
                const SizedBox(height: 12),
                Text(
                  '排行榜',
                  style: TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      _Cover(
                        width: 40,
                        height: 54,
                        radius: 8,
                        color: accent.withValues(alpha: .09 + i * .04),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      _Cover(
                        width: 46,
                        height: 58,
                        radius: 8,
                        color: scheme.surface,
                        border: scheme.outlineVariant,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        // The old dock: four flat destinations, orange selection.
        Container(
          height: 26,
          color: scheme.surface,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              for (var i = 0; i < 4; i++) ...[
                if (i > 0) const Spacer(),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: i == 0 ? accent : muted.withValues(alpha: .45),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 3),
                    _Bar(
                      width: 10,
                      height: 2.5,
                      color: i == 0 ? accent : muted.withValues(alpha: .35),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ArchiveMini extends StatelessWidget {
  const _ArchiveMini({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final ink = scheme.onSurface;
    final muted = scheme.onSurfaceVariant;
    final line = scheme.outlineVariant;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SHIJINPU',
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.2,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 5),
                Container(height: 1, color: ink),
                const SizedBox(height: 7),
                Text(
                  '01 / READING',
                  style: TextStyle(
                    fontSize: 5.5,
                    letterSpacing: 1.2,
                    color: muted,
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  height: 68,
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    border: Border.all(color: line),
                  ),
                  padding: const EdgeInsets.all(7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Cover(
                        width: 36,
                        height: 52,
                        radius: 2,
                        color: scheme.surfaceContainerHigh,
                      ),
                      const SizedBox(width: 7),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 4),
                          _Bar(width: 62, height: 5, color: ink),
                          const SizedBox(height: 6),
                          _Bar(width: 46, height: 3.5, color: muted),
                          const SizedBox(height: 5),
                          _Bar(width: 30, height: 3.5, color: muted),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Container(height: 1, color: line),
                const SizedBox(height: 7),
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(height: 7),
                  Row(
                    children: [
                      _Cover(
                        width: 20,
                        height: 28,
                        radius: 2,
                        color: scheme.surfaceContainerHigh,
                      ),
                      const SizedBox(width: 7),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Bar(width: 68, height: 4, color: ink),
                          const SizedBox(height: 5),
                          _Bar(width: 44, height: 3.5, color: muted),
                        ],
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        // The archive dock floats as a glass capsule above the page.
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: Container(
            height: 24,
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: line),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (var i = 0; i < 4; i++) ...[
                  if (i > 0) const Spacer(),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == 0 ? ink : muted.withValues(alpha: .35),
                      borderRadius: BorderRadius.circular(i == 0 ? 2 : 4),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.width, required this.height, required this.color});

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(height / 2),
    ),
  );
}

class _Cover extends StatelessWidget {
  const _Cover({
    required this.width,
    required this.height,
    required this.radius,
    required this.color,
    this.border,
  });

  final double width;
  final double height;
  final double radius;
  final Color color;
  final Color? border;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(radius),
      border: border == null ? null : Border.all(color: border!),
    ),
  );
}

class _Footnote extends StatelessWidget {
  const _Footnote({required this.tokens});

  final AppStyleTokens tokens;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(tokens.isClassic ? 12 : 4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '经典主题恢复老版首页、封面书架、阅读统计和设置列表。'
              '两套书架布局分别记忆；阅读配色、明暗、OLED 与墨水屏在「外观」中单独设置。',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
