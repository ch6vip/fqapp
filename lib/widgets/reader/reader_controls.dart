// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/reader_tools.dart        -> ReaderChapterProgress (compact capsule)
//   lib/pages.dart               -> _readerBottomControls / _readerAction
//                                   (the reader glass dock)
//   lib/reader_chrome.dart       -> readerDockPaintPadding geometry
//
// Mechanical substitutions:
// - `app_ui.dart` AppText/GlassIconButton/LiquidGlass/JellyTapSurface ->
//   the shared `lib/widgets/wenku` exports.
// - `app_ui.dart` AppControls.slider -> ReaderGlassControls.slider
//   (`lib/widgets/wenku/reader_glass_controls.dart`).
// - `NovelMotion` -> `WenkuMotion`; `DockLayout` is the already-ported shared
//   geometry file.
// - The upstream ProgressCapsule scrubs *within a chapter* through
//   ReaderChapterProgress; fqapp's bottom bar seeks *across chapters*, so the
//   slider keeps the existing chapter-index semantics and callback contract.
// - Upstream's six dock entries (目录/书签/外观/操作/查找/夜读) narrow to the
//   three fqapp reader actions that exist today (目录/夜间/设置). No entry is
//   invented for a feature the reader does not have.
// - The listening and video capsules stay in reader_page_menu_players.dart and
//   are not part of this dock.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import '../wenku/reader_glass_controls.dart';
import '../wenku/wenku_ui.dart';
import 'reader_theme.dart';

/// Reading menu. Listening starts from the separate round entry above this bar.
class ReaderControls extends StatelessWidget {
  final ReaderPreferences preferences;
  final int chapterIndex;
  final int chapterCount;
  final String chapterTitle;
  final double seekValue;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final ValueChanged<double> onSeek;
  final ValueChanged<double> onSeekEnd;
  final VoidCallback onDirectory;
  final VoidCallback onNight;
  final VoidCallback onAppearance;

  const ReaderControls({
    super.key,
    required this.preferences,
    required this.chapterIndex,
    required this.chapterCount,
    required this.chapterTitle,
    required this.seekValue,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onSeekEnd,
    required this.onDirectory,
    required this.onNight,
    required this.onAppearance,
  });

  @override
  Widget build(BuildContext context) {
    final preset = preferences.themePreset;
    final max = (chapterCount - 1).toDouble();
    final upper = max < 0 ? 0.0 : max;
    final tint = preset.panelColor;
    final night = preset.isDark;
    Widget content(BuildContext context) => Theme(
      data: preset.theme(Theme.of(context)),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: 6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _chapterLine(preset),
                  const SizedBox(height: 6),
                  // Upstream narrows the capsule and dock to their action
                  // count: `DockLayout.widthFor(5) - 32` and
                  // `DockLayout.widthFor(n)` (pages.dart). Centering keeps the
                  // glass compact on phones and tablets alike.
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: DockLayout.widthFor(5) - 32,
                      ),
                      child: _progressCapsule(context, preset, tint, upper),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: DockLayout.widthFor(3),
                      ),
                      child: _dock(context, preset, tint, night),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // 墨水屏：实时折射会在 EPD 上留下灰阶残影，坞与胶囊退回轻量底板。
    // Builder 让内容（包括玻璃滑条）真正位于这个 PerformanceScope 之下。
    return preset.isEink
        ? PerformanceScope(
            preferences: const PerformancePreferences(enabled: true),
            explicitReduceMotion: true,
            child: Builder(builder: content),
          )
        : Builder(builder: content);
  }

  /// Chapter title and ordinal stay visible above the capsule; upstream only
  /// shows them in the drag hint, but fqapp readers rely on the chapter name.
  Widget _chapterLine(ReaderThemePreset preset) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            chapterTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: preset.textColor,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${chapterIndex + 1} / $chapterCount',
          style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
        ),
      ],
    ),
  );

  /// Upstream `ReaderChapterProgress(compact: true)`: one glass capsule with
  /// chapter-step icon actions on both ends and the shared glass slider inside.
  Widget _progressCapsule(
    BuildContext context,
    ReaderThemePreset preset,
    Color tint,
    double upper,
  ) {
    final value = seekValue.clamp(0, upper).toDouble();
    return LiquidGlass(
      key: const ValueKey('reader-progress-capsule'),
      radius: 24,
      tintColor: tint,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            GlassIconButton(
              key: const ValueKey('reader-previous-chapter'),
              icon: CupertinoIcons.backward_end,
              label: '上一章',
              liveGlass: false,
              transparent: true,
              haptic: HapticCue.pageTurn,
              onPressed: onPrevious,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: ReaderGlassControls.slider(
                context,
                key: const ValueKey('reader-chapter-seek'),
                value: value,
                min: 0,
                max: upper,
                divisions: chapterCount > 1 ? chapterCount - 1 : null,
                compact: true,
                haptics: false,
                accentColor: preset.accentColor,
                trackColor: preset.borderColor,
                thumbColor: preset.isDark ? preset.textColor : Colors.white,
                tint: tint,
                semanticFormatter: (value) => '第 ${value.round() + 1} 章',
                onChanged: chapterCount > 1 ? onSeek : null,
                onChangeEnd: chapterCount > 1 ? onSeekEnd : null,
              ),
            ),
            const SizedBox(width: 4),
            GlassIconButton(
              key: const ValueKey('reader-next-chapter'),
              icon: CupertinoIcons.forward_end,
              label: '下一章',
              liveGlass: false,
              transparent: true,
              haptic: HapticCue.pageTurn,
              onPressed: onNext,
            ),
          ],
        ),
      ),
    );
  }

  /// Upstream `_readerBottomControls` dock: one live glass capsule, icon over
  /// label, shared `DockLayout` geometry.
  Widget _dock(
    BuildContext context,
    ReaderThemePreset preset,
    Color tint,
    bool night,
  ) => LiquidGlass(
    key: const ValueKey('reader-liquid-dock'),
    radius: DockLayout.heightOf(context) / 2,
    thickness: 16,
    tintColor: tint,
    padding: const EdgeInsets.symmetric(horizontal: DockLayout.horizontalInset),
    child: Row(
      children: [
        _DockAction(
          key: const ValueKey('reader-catalogue-entry'),
          icon: CupertinoIcons.list_bullet,
          label: '目录',
          onPressed: onDirectory,
        ),
        _DockAction(
          key: const ValueKey('reader-night-entry'),
          icon: night ? CupertinoIcons.sun_max : CupertinoIcons.moon,
          label: night ? '日间' : '夜间',
          onPressed: onNight,
        ),
        _DockAction(
          key: const ValueKey('reader-settings'),
          icon: CupertinoIcons.textformat,
          label: '设置',
          onPressed: onAppearance,
        ),
      ],
    ),
  );
}

/// One dock item; geometry from upstream `_readerAction` / `DockLayout`.
class _DockAction extends StatelessWidget {
  const _DockAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      child: JellyTapSurface(
        onTap: onPressed,
        child: SizedBox(
          height: DockLayout.heightOf(context),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ArchiveIcon(
                  icon,
                  size: DockLayout.iconSize,
                  color: onPressed == null
                      ? Theme.of(context).disabledColor
                      : null,
                ),
                const SizedBox(height: DockLayout.labelGap),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: DockLayout.labelFontSize,
                        color: onPressed == null
                            ? Theme.of(context).disabledColor
                            : null,
                      ),
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

/// 阅读页顶栏的缓存入口：分成阅读菜单后，缓存不再占底部一行。
class ReaderCacheButton extends StatelessWidget {
  const ReaderCacheButton({
    super.key,
    required this.preset,
    required this.onTap,
  });

  final ReaderThemePreset preset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GlassIconButton(
    key: const ValueKey('reader-cache'),
    icon: CupertinoIcons.tray_arrow_down,
    label: '缓存',
    color: preset.textColor,
    onPressed: onTap,
  );
}
