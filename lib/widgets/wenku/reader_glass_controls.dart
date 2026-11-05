// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/glass_controls.dart -> ReaderGlassSwitch / ReaderGlassSlider
//   lib/app_ui.dart (AppControls.toggle/slider and their _material recipe)
//       -> ReaderGlassControls
//
// Mechanical substitutions for dependencies fqapp does not carry:
// - `app_haptics.dart` -> `src/app_haptics.dart` (the same HapticCue /
//   AppHaptics API re-exported by `wenku_glass.dart`; the upstream persisted
//   haptics service is already absent from this tree).
// - `GlassPalette` / `AppTonalColors` thumb and accent lookups -> colours the
//   caller derives from the reader palette. The reader keeps its own paper
//   accent; the archive's mono palette is not imported here.
// - `NovelMotion` -> `WenkuMotion`.
// - `package:flutter/services.dart` stays only for the keyboard shortcuts the
//   upstream adapters install.
//
// The package (`liquid_glass_easy`) still owns touch, lens motion and paint;
// this file only adds controlled values, disabled semantics and accessibility
// exactly like the upstream adapters.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' as easy;

import 'src/performance_preferences.dart';
import 'wenku_glass.dart';
import 'wenku_theme.dart';

class ReaderGlassSwitch extends StatefulWidget {
  const ReaderGlassSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.activeColor,
    required this.inactiveColor,
    required this.thumbColor,
    required this.style,
    required this.reduceMotion,
    this.haptics = true,
  });

  final bool value, reduceMotion, haptics;
  final FutureOr<void> Function(bool)? onChanged;
  final Color activeColor, inactiveColor, thumbColor;
  final easy.LiquidGlassStyle style;

  @override
  State<ReaderGlassSwitch> createState() => _ReaderGlassSwitchState();
}

class _ReaderGlassSwitchState extends State<ReaderGlassSwitch> {
  bool? _pending;
  int _request = 0;
  bool get _value => _pending ?? widget.value;

  Future<void> _change(bool value) async {
    final action = widget.onChanged;
    if (action == null || value == _value) return;
    if (widget.haptics) AppHaptics.play(context, HapticCue.selection);
    final request = ++_request;
    setState(() => _pending = value);
    try {
      await action(value);
    } finally {
      if (mounted && request == _request) setState(() => _pending = null);
    }
  }

  void _released(PointerEvent _) {
    // A cancelled save can finish while the package still lets the finger own
    // the thumb. Reconcile the controlled value after it releases that ownership.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    return Semantics(
      toggled: _value,
      enabled: enabled,
      onTap: enabled ? () => _change(!_value) : null,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): () {
            if (enabled) _change(!_value);
          },
          const SingleActivator(LogicalKeyboardKey.enter): () {
            if (enabled) _change(!_value);
          },
        },
        child: Focus(
          canRequestFocus: enabled,
          child: IgnorePointer(
            ignoring: !enabled,
            child: ExcludeSemantics(
              child: Listener(
                onPointerUp: _released,
                onPointerCancel: _released,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: easy.LiquidGlassSwitch(
                    value: _value,
                    enableHaptics: false,
                    horizontalDragOnly: true,
                    onChanged: _change,
                    activeColor: enabled
                        ? widget.activeColor
                        : widget.activeColor.withValues(alpha: .4),
                    inactiveColor: enabled
                        ? widget.inactiveColor
                        : widget.inactiveColor.withValues(alpha: .5),
                    thumbColor: enabled
                        ? widget.thumbColor
                        : widget.thumbColor.withValues(alpha: .55),
                    style: widget.style,
                    layout: const easy.LiquidGlassSwitchLayout().scaled(.9),
                    reserveSwellRoom: true,
                    reduceMotion: widget.reduceMotion,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ReaderGlassSlider extends StatefulWidget {
  const ReaderGlassSlider({
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
  });

  final double value, min, max;
  final int? divisions;
  final bool haptics;
  final bool compact;
  final ValueChanged<double>? onChanged, onChangeStart, onChangeEnd;
  final Color activeColor, inactiveColor, thumbColor;
  final easy.LiquidGlassStyle style;
  final bool reduceMotion;

  @override
  State<ReaderGlassSlider> createState() => _ReaderGlassSliderState();
}

class _ReaderGlassSliderState extends State<ReaderGlassSlider> {
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
  void didUpdateWidget(ReaderGlassSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging) _draft = _quantize(widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final span = widget.max - widget.min;
    String percent(double value) =>
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

/// Upstream `AppControls.toggle` / `AppControls.slider` with the reader's own
/// paper palette in place of the archive mono colours.
abstract final class ReaderGlassControls {
  static const _defaultThumb = Color(0xFFFEFDF8);

  static Color accentOf(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  static Color trackOf(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Color.lerp(
      scheme.surface,
      scheme.onSurface,
      scheme.brightness == Brightness.dark ? .22 : .14,
    )!;
  }

  static Color thumbOf(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return scheme.brightness == Brightness.dark
        ? Color.lerp(scheme.surface, Colors.white, .72)!
        : _defaultThumb;
  }

  /// The shared pill material. [tint] keeps the sheet on the reader's paper
  /// colour instead of the archive's neutral milk.
  static easy.LiquidGlassStyle material(
    BuildContext context, {
    Color? tint,
    bool plate = false,
  }) {
    final appearance = GlassAppearance.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
    final plain = WenkuTheme.isEinkOf(context) || highContrast;
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
      liteGlass: !PerformanceScope.of(context).glass || plain,
    );
  }

  /// E-ink / performance-lite hosts do not get a lens; a plain ink control is
  /// both cheaper and ghost-free.
  static bool isPlain(BuildContext context) =>
      MediaQuery.highContrastOf(context) ||
      WenkuTheme.isEinkOf(context) ||
      !PerformanceScope.of(context).glass;

  static Widget toggle(
    BuildContext context, {
    Key? key,
    required bool value,
    required FutureOr<void> Function(bool)? onChanged,
    Color? accentColor,
    Color? trackColor,
    Color? thumbColor,
    Color? tint,
    bool haptics = true,
  }) {
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        !PerformanceScope.of(context).motion;
    if (isPlain(context)) {
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
    return ReaderGlassSwitch(
      key: key,
      value: value,
      onChanged: onChanged,
      haptics: haptics,
      activeColor: accentColor ?? accentOf(context),
      inactiveColor: trackColor ?? trackOf(context),
      thumbColor: thumbColor ?? thumbOf(context),
      style: material(context, tint: tint),
      reduceMotion: reduceMotion,
    );
  }

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
  }) {
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        !PerformanceScope.of(context).motion;
    return ReaderGlassSlider(
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
      activeColor: accentColor ?? accentOf(context),
      inactiveColor: trackColor ?? trackOf(context),
      thumbColor: thumbColor ?? thumbOf(context),
      style: material(context, tint: tint),
      reduceMotion: reduceMotion,
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

  /// A compact value row: label + formatted value above the glass track.
  static Widget valueSlider(
    BuildContext context, {
    required Key sliderKey,
    required String label,
    required double value,
    required double min,
    required double max,
    required String Function(double) format,
    required ValueChanged<double>? onCommitted,
    ValueChanged<double>? onPreview,
    int? divisions,
    Color? tint,
    TextStyle? labelStyle,
  }) => _ReaderValueSlider(
    sliderKey: sliderKey,
    label: label,
    value: value,
    min: min,
    max: max,
    format: format,
    onCommitted: onCommitted,
    onPreview: onPreview,
    divisions: divisions,
    tint: tint,
    labelStyle: labelStyle,
  );
}

class _ReaderValueSlider extends StatefulWidget {
  const _ReaderValueSlider({
    required this.sliderKey,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onCommitted,
    this.onPreview,
    this.divisions,
    this.tint,
    this.labelStyle,
  });

  final Key sliderKey;
  final String label;
  final double value;
  final double min;
  final double max;
  final String Function(double) format;
  final ValueChanged<double>? onCommitted;
  final ValueChanged<double>? onPreview;
  final int? divisions;
  final Color? tint;
  final TextStyle? labelStyle;

  @override
  State<_ReaderValueSlider> createState() => _ReaderValueSliderState();
}

class _ReaderValueSliderState extends State<_ReaderValueSlider> {
  late double _draft = widget.value;

  @override
  void didUpdateWidget(_ReaderValueSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _draft = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style:
                      widget.labelStyle ??
                      TextStyle(fontSize: 13, color: scheme.onSurface),
                ),
              ),
              Text(
                widget.format(_draft),
                style: TextStyle(fontSize: 12, color: scheme.primary),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ReaderGlassControls.slider(
            context,
            key: widget.sliderKey,
            value: _draft,
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            tint: widget.tint,
            onChanged: widget.onCommitted == null
                ? null
                : (value) {
                    setState(() => _draft = value);
                    (widget.onPreview ?? widget.onCommitted)?.call(value);
                  },
            onChangeEnd: widget.onCommitted == null
                ? null
                : (value) {
                    setState(() => _draft = value);
                    widget.onCommitted!(value);
                  },
          ),
        ],
      ),
    );
  }
}
