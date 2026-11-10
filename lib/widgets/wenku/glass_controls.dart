// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/glass_controls.dart -> AppGlassSlider (AppGlassSwitch lives in
//                             wenku_segments.dart with the shelf port)
//   lib/app_ui.dart         -> AppControls.toggle / AppControls.slider
//                             (the two adapters and their private material
//                             recipe only; segments stays in
//                             wenku_segments.dart)
//   lib/app_ui.dart         -> AppControls.chip / GlassTextButton (the compact
//                             reader settings chip)
//
// This is the single shared copy of the upstream toggle/slider adapters. The
// reader and settings units originally vendored prefixed copies
// (`reader_glass_controls.dart`, `settings_glass_controls.dart`); they are
// merged here. Archive/settings surfaces use the default `WenkuTonalColors`
// palette; reader surfaces pass their paper palette explicitly and opt into
// the plain-switch fallback. The shelf port's `WenkuControls.toggle` is the
// archive-palette adapter over the same shared `AppGlassSwitch`.
//
// Mechanical substitutions for dependencies fqapp does not carry:
// - `app_haptics.dart` -> `src/app_haptics.dart` (same HapticCue/AppHaptics
//   API; the upstream persisted haptics settings service is absent).
// - `app_ui.dart` -> `wenku_glass.dart` / `wenku_archive.dart` for
//   GlassAppearance, ContentPanel-era geometry and ArchiveDesign;
//   `wenku_theme.dart` for WenkuTonalColors.
// - `AppTonalColors` / `GlassPalette` -> WenkuTonalColors `active`, `track`
//   and `thumb`, with the upstream lerp fallbacks and ArchiveDesign.milk thumb.
// - e-ink has no upstream counterpart: the archive track and thumb invert with
//   the value so both states stay distinguishable in pure black and white.
//   Reader surfaces instead fall back to a plain `Switch` (`plainFallback`),
//   matching the reader's previous prefixed adapter.
// - `MediaQuery.disableAnimationsOf(context)` supplies the reduce-motion flag,
//   exactly as the upstream call sites do.
// - `liquid_glass_easy` is the vendored third_party path package fqapp already
//   depends on, so the package API is used unchanged.
// - fqapp-only knobs on the adapter: `optimistic` lets confirmation /
//   permission flows keep the persisted value until the callback commits,
//   `semanticLabel` restores the accessible label the previous SettingsSwitch
//   carried, and `semanticFormatter` names the unit of a reader slider value.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' as easy;

import 'src/performance_preferences.dart';
import 'wenku_archive.dart';
import 'wenku_glass.dart';
import 'wenku_segments.dart';
import 'wenku_theme.dart';

/// Upstream `AppControls.toggle` / `AppControls.slider` with the archive
/// material and the settings palette, kept as the single entry point for the
/// ported settings and reader surfaces.
abstract final class GlassControls {
  static Color _accent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (MediaQuery.highContrastOf(context)) return const Color(0xFF747474);
    if (Theme.of(context).extension<WenkuTonalColors>() case final colors?) {
      return colors.active;
    }
    return Color.lerp(
      scheme.onSurface,
      scheme.surface,
      scheme.brightness == Brightness.dark ? .46 : .48,
    )!;
  }

  static Color _track(BuildContext context) {
    if (Theme.of(context).extension<WenkuTonalColors>() case final colors?) {
      return colors.track;
    }
    final scheme = Theme.of(context).colorScheme;
    return Color.lerp(
      scheme.surface,
      scheme.onSurface,
      scheme.brightness == Brightness.dark ? .16 : .10,
    )!;
  }

  static Color _thumb(BuildContext context) =>
      Theme.of(context).extension<WenkuTonalColors>()?.thumb ??
      ArchiveDesign.milk;

  /// Upstream `AppControls._material`. [tint] keeps a reader sheet on its own
  /// paper colour instead of the archive's neutral milk.
  static easy.LiquidGlassStyle material(
    BuildContext context, {
    Color? tint,
    bool plate = false,
    bool plain = false,
  }) {
    final appearance = GlassAppearance.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
    final color =
        tint ??
        GlassAppearance.tintOf(
          context,
          opacity: appearance.opacity,
        ).withValues(alpha: 1);
    return easy.LiquidGlassStyle(
      shape: const easy.LiquidGlassShape.continuousRoundedRectangle(
        cornerRadius: 100,
      ),
      specular: const easy.LiquidGlassLight.specular(
        intensity: 0,
        thickness: 0,
      ),
      glow: const easy.LiquidGlassLight.glow(intensity: 0, thickness: 0),
      refractionIndex: 1.03,
      refractionWidth: plate ? 16 : 8,
      dispersion: 0,
      blur: 0,
      color: color.withValues(
        alpha: highContrast
            ? 1
            : plate
            ? appearance.opacity
            : .10,
      ),
      shadow: plate
          ? null
          : const easy.LiquidGlassShadow(blur: 6, opacity: .12, inset: 3),
      liteGlass: !PerformanceScope.of(context).glass || plain || highContrast,
    );
  }

  /// E-ink / high-contrast / performance-lite hosts do not get a lens; a plain
  /// ink control is both cheaper and ghost-free. Only reader surfaces opt in.
  static bool _isPlain(BuildContext context) =>
      MediaQuery.highContrastOf(context) ||
      WenkuTheme.isEinkOf(context) ||
      !PerformanceScope.of(context).glass;

  /// Upstream `AppControls.toggle`.
  static Widget toggle(
    BuildContext context, {
    Key? key,
    required bool value,
    required FutureOr<void> Function(bool)? onChanged,
    bool haptics = true,
    bool optimistic = true,
    String? semanticLabel,
    Color? accentColor,
    Color? trackColor,
    Color? thumbColor,
    Color? tint,
    bool plainFallback = false,
  }) {
    if (plainFallback && _isPlain(context)) {
      // E-ink / high contrast: no lens, no translucent grey. A plain ink switch
      // keeps the current read, exactly like the archive's opaque endpoint.
      return Switch(
        key: key,
        value: value,
        onChanged: onChanged == null
            ? null
            : (next) {
                if (haptics) AppHaptics.play(context, HapticCue.selection);
                onChanged(next);
              },
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final eink = WenkuTheme.isEinkOf(context);
    final Color active;
    final Color inactive;
    final Color thumb;
    if (eink) {
      // Pure black/white: white track + black thumb when off, black track +
      // white thumb when on.
      active = scheme.onSurface;
      inactive = scheme.surface;
      thumb = value ? scheme.surface : scheme.onSurface;
    } else {
      active = accentColor ?? _accent(context);
      inactive = trackColor ?? _track(context);
      thumb = thumbColor ?? _thumb(context);
    }
    // The disabled dimming stays inside AppGlassSwitch, exactly as upstream
    // `AppControls.toggle` -> `AppGlassSwitch`: pre-dimming here would apply
    // the alpha twice.
    return AppGlassSwitch(
      key: key,
      value: value,
      onChanged: onChanged,
      haptics: haptics,
      optimistic: optimistic,
      semanticLabel: semanticLabel,
      activeColor: active,
      inactiveColor: inactive,
      thumbColor: thumb,
      style: material(context, tint: tint),
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
  }

  /// Upstream `AppControls.slider`.
  static Widget slider(
    BuildContext context, {
    Key? key,
    required double value,
    required ValueChanged<double>? onChanged,
    double min = 0,
    double max = 1,
    int? divisions,
    bool haptics = true,
    bool compact = false,
    Color? accentColor,
    Color? trackColor,
    Color? thumbColor,
    Color? tint,
    ValueChanged<double>? onChangeStart,
    ValueChanged<double>? onChangeEnd,
    String Function(double value)? semanticFormatter,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // Reader surfaces pass their own palette; archive surfaces use the
    // inverted e-ink endpoints.
    final customPalette =
        accentColor != null || trackColor != null || thumbColor != null;
    final eink = !customPalette && WenkuTheme.isEinkOf(context);
    final active = eink ? scheme.onSurface : (accentColor ?? _accent(context));
    final inactive = eink
        ? scheme.outlineVariant
        : (trackColor ?? _track(context));
    final thumb = eink ? scheme.surface : (thumbColor ?? _thumb(context));
    // Disabled dimming belongs to AppGlassSlider, as in upstream
    // `AppControls.slider`; dimming the inputs here would double it.
    return AppGlassSlider(
      key: key,
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      haptics: haptics,
      compact: compact,
      onChanged: onChanged,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
      activeColor: active,
      inactiveColor: inactive,
      thumbColor: thumb,
      // Reader surfaces keep the previous prefixed adapter's lite lens on
      // e-ink; archive surfaces only drop the lens for high contrast.
      style: material(
        context,
        tint: tint,
        plain:
            customPalette &&
            (WenkuTheme.isEinkOf(context) ||
                MediaQuery.highContrastOf(context)),
      ),
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      semanticFormatter: semanticFormatter,
    );
  }

  /// A compact glass chip for dense reader settings rows. Same lens material as
  /// the upstream `GlassTextButton`, but sized for the sheet's one-screen
  /// layout (34 px minimum instead of the 48 px action target).
  static Widget chip(
    BuildContext context, {
    Key? key,
    required Widget child,
    required bool selected,
    required VoidCallback? onPressed,
    Color? tint,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final base =
        tint ??
        GlassAppearance.tintOf(
          context,
          opacity: GlassAppearance.of(context).opacity,
        );
    return Semantics(
      selected: selected,
      button: true,
      child: LiquidGlass(
        key: key,
        radius: 100,
        tintColor: selected ? Color.lerp(base, scheme.onSurface, .10) : base,
        onTap: onPressed,
        haptic: selected ? HapticCue.selection : HapticCue.action,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 34),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppGlassSlider extends StatefulWidget {
  const AppGlassSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.haptics = true,
    this.compact = false,
    required this.activeColor,
    required this.inactiveColor,
    required this.thumbColor,
    required this.style,
    required this.reduceMotion,
    this.semanticFormatter,
  });
  final double value, min, max;
  final int? divisions;
  final bool haptics;
  final bool compact;
  final ValueChanged<double>? onChanged, onChangeStart, onChangeEnd;
  final Color activeColor, inactiveColor, thumbColor;
  final easy.LiquidGlassStyle style;
  final bool reduceMotion;

  /// Accessibility text for the current value. Defaults to a percentage;
  /// callers with meaningful steps (e.g. a chapter index) can name the unit.
  final String Function(double value)? semanticFormatter;
  @override
  State<AppGlassSlider> createState() => _AppGlassSliderState();
}

class _AppGlassSliderState extends State<AppGlassSlider> {
  late double _draft = widget.value;
  bool _dragging = false;
  bool _changedInGesture = false;
  double _quantize(double value) {
    final span = widget.max - widget.min;
    final steps = widget.divisions;
    if (steps != null && steps > 0 && span > 0) {
      value =
          widget.min +
          ((value - widget.min) / span * steps).round() / steps * span;
    }
    return value.clamp(widget.min, widget.max);
  }

  void _change(double value) {
    final next = _quantize(value);
    if (next == _draft) return;
    final span = widget.max - widget.min;
    final steps = widget.divisions ?? 20;
    if (widget.haptics && span > 0) {
      final previousTick = ((_draft - widget.min) / span * steps).round();
      final nextTick = ((next - widget.min) / span * steps).round();
      if (next == widget.min || next == widget.max) {
        AppHaptics.play(context, HapticCue.boundary);
      } else if (!_changedInGesture || nextTick != previousTick) {
        AppHaptics.play(context, HapticCue.detent);
      }
    }
    _changedInGesture = true;
    setState(() => _draft = next);
    widget.onChanged?.call(next);
  }

  void _start(double _) {
    _dragging = true;
    _changedInGesture = false;
    widget.onChangeStart?.call(_draft);
  }

  void _end(double value) {
    final next = _quantize(value);
    _change(next);
    setState(() => _dragging = false);
    widget.onChangeEnd?.call(next);
  }

  void _adjust(double direction) {
    if (widget.onChanged == null) return;
    _start(_draft);
    _change(_adjusted(direction));
    _end(_draft);
  }

  double _adjusted(double direction) => _quantize(
    _draft + (widget.max - widget.min) / (widget.divisions ?? 20) * direction,
  );

  @override
  void didUpdateWidget(AppGlassSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging) _draft = _quantize(widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final span = widget.max - widget.min;
    String percent(double value) =>
        widget.semanticFormatter?.call(value) ??
        '${(span > 0 ? (value - widget.min) / span * 100 : 0).round()}%';
    return Semantics(
      slider: true,
      enabled: enabled,
      value: percent(_draft),
      increasedValue: enabled && _draft < widget.max
          ? percent(_adjusted(1))
          : null,
      decreasedValue: enabled && _draft > widget.min
          ? percent(_adjusted(-1))
          : null,
      onIncrease: enabled && _draft < widget.max ? () => _adjust(1) : null,
      onDecrease: enabled && _draft > widget.min ? () => _adjust(-1) : null,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _adjust(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _adjust(1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _adjust(-1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              _adjust(-1),
        },
        child: Focus(
          canRequestFocus: enabled,
          child: IgnorePointer(
            ignoring: !enabled,
            child: ExcludeSemantics(
              child: LayoutBuilder(
                builder: (context, constraints) => easy.LiquidGlassSlider(
                  value: _draft,
                  enableHaptics: false,
                  horizontalDragOnly: true,
                  minimumValue: widget.min,
                  maximumValue: widget.max,
                  onChanged: _change,
                  onChangeStart: _start,
                  onChangeEnd: _end,
                  width: constraints.maxWidth,
                  height: widget.compact ? 48 : 52,
                  minimumTouchHeight: 48,
                  layout: widget.compact
                      ? const easy.LiquidGlassSliderLayout(
                          thumbWidth: 24,
                          thumbHeight: 24,
                          liftedThumbWidth: 36,
                          liftedThumbHeight: 36,
                          horizontalInset: 8,
                        )
                      : const easy.LiquidGlassSliderLayout(),
                  motion: widget.compact
                      ? const easy.LiquidGlassLensMotionSpec(maxDeformation: 0)
                      : const easy.LiquidGlassLensMotionSpec(),
                  activeColor: enabled
                      ? widget.activeColor
                      : widget.activeColor.withValues(alpha: .4),
                  inactiveColor: widget.inactiveColor,
                  thumbColor: enabled
                      ? widget.thumbColor
                      : widget.thumbColor.withValues(alpha: .55),
                  style: widget.style,
                  reduceMotion: widget.reduceMotion,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
