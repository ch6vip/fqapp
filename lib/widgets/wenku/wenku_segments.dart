// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/glass_controls.dart -> AppGlassSegments, AppGlassSwitch
//   lib/glass_choices.dart  -> GlassChoiceGroup
//
// Mechanical substitutions for dependencies fqapp does not carry:
// - `app_haptics.dart` -> the HapticCue/AppHaptics API re-exported by
//   `wenku_glass.dart` from `src/app_haptics.dart` (same names; the upstream
//   persisted haptics settings service is already absent).
// - `app_ui.dart`'s AppText -> `src/app_text.dart`.
// - `app_ui.dart`'s GlassTextButton -> `wenku_glass.dart` (same
//   compact/selected/onPressed API; the shared control owns the glass face).
// - `package:flutter/cupertino.dart` -> `package:flutter/material.dart`; these
//   widgets only used members both libraries expose.
// - `liquid_glass_easy` is the vendored third_party path package fqapp already
//   depends on, so the package API is used unchanged.
//
// AppGlassSwitch is carried here because the shelf options sheet's repeat-fill
// row uses the upstream toggle; the settings line's `glass_controls.dart`
// duplicate is unified onto this copy.
//
// fqapp additions:
// - `GlassChoiceGroup.showLabel` / `disabledOptions` (the shelf filter sheet
//   hides section labels and disables the cached source until the scan ends).
// - `WenkuControls.toggle` maps the upstream `AppControls.toggle` recipe onto
//   fqapp's `WenkuTonalColors` active/track/thumb tokens.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' as easy;

import 'src/app_text.dart';
import 'src/performance_preferences.dart';
import 'wenku_archive.dart';
import 'wenku_glass.dart';
import 'wenku_theme.dart';

class AppGlassSegments<T extends Object> extends StatelessWidget {
  const AppGlassSegments({
    super.key,
    required this.groupValue,
    required this.children,
    required this.onValueChanged,
    required this.style,
    required this.pillStyle,
    required this.foregroundColor,
    this.selectedForegroundColor,
    this.disabledChildren = const {},
    this.haptics = true,
  });

  /// fqapp addition: e-ink draws a solid ink pill, so its label inverts.
  final Color? selectedForegroundColor;
  final T? groupValue;
  final bool haptics;
  final Map<T, Widget> children;
  final ValueChanged<T?> onValueChanged;
  final Set<T> disabledChildren;
  final easy.LiquidGlassStyle style;
  final easy.LiquidGlassSegmentedPillStyle pillStyle;
  final Color foregroundColor;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final keys = children.keys.toList();
      final labels = [
        for (final child in children.values)
          child is Text ? child.data ?? '' : '',
      ];
      final textOnly = children.values.every((child) => child is Text);
      final textStyle = DefaultTextStyle.of(
        context,
      ).style.copyWith(fontSize: 14, height: 1.4, color: foregroundColor);
      // Reserve the package pill's complete bulge, including two-item selectors.
      final growth = pillStyle.growHeight;
      final gutter = math
          .max(
            4.0,
            (growth * (constraints.maxWidth - 8) / (2 * keys.length * 40) - 4) /
                (1 + growth / (keys.length * 40)),
          )
          .ceilToDouble();
      final width = math.max(1.0, constraints.maxWidth - gutter * 2);
      final cellWidth = math.max(1.0, (width - 8) / keys.length);
      var height = 48.0;
      for (final label in labels) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: textStyle),
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
        )..layout(maxWidth: cellWidth);
        height = math.max(height, painter.height + 12);
        painter.dispose();
      }
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 4),
        child: easy.LiquidGlassSegmented(
          segments: labels,
          selectedIndex: math.max(
            0,
            keys.indexWhere((key) => key == groupValue),
          ),
          disabledIndices: {
            for (var index = 0; index < keys.length; index++)
              if (disabledChildren.contains(keys[index])) index,
          },
          onChanged: (index) {
            if (!disabledChildren.contains(keys[index])) {
              if (haptics && keys[index] != groupValue) {
                AppHaptics.play(context, HapticCue.selection);
              }
              onValueChanged(keys[index]);
            }
          },
          width: width,
          height: height,
          style: style,
          pillStyle: pillStyle,
          labelStyle: easy.LiquidGlassSegmentedLabelStyle(
            selectedColor: selectedForegroundColor ?? foregroundColor,
            unselectedColor: foregroundColor.withValues(alpha: .72),
            fontSize: 14,
          ),
          segmentBuilder: textOnly
              ? null
              : (context, index, selected, color) => children[keys[index]]!,
        ),
      );
    },
  );
}

/// Small, visible sets of choices share the app's control surface and hit area.
class GlassChoiceGroup<T> extends StatelessWidget {
  const GlassChoiceGroup({
    super.key,
    required this.name,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.leading,
    this.optionName,
    this.labelSize = 14,
    this.optionSize = 13,
    this.enabled = true,
    this.columns,
    this.showLabel = true,
    this.disabledOptions = const {},
  });
  final String name, label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  final Widget Function(T)? leading;
  final String Function(T)? optionName;
  final double labelSize, optionSize;
  final bool enabled;
  final int? columns;

  /// fqapp addition: a caller that already renders its own section heading can
  /// hide the small inline label.
  final bool showLabel;

  /// fqapp addition: options that stay visible but cannot be chosen.
  final Set<T> disabledOptions;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (showLabel)
        Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 4),
          child: AppText(
            label,
            style: TextStyle(fontSize: labelSize, fontWeight: FontWeight.w600),
          ),
        ),
      if (columns == null)
        _choices()
      else
        LayoutBuilder(
          builder: (context, constraints) {
            final count =
                constraints.maxWidth < 280 ||
                    MediaQuery.textScalerOf(context).scale(optionSize) >
                        optionSize * 1.3
                ? 1
                : columns!;
            return _choices(
              width: (constraints.maxWidth - 8 * (count - 1)) / count,
            );
          },
        ),
    ],
  );

  Widget _choices({double? width}) => Wrap(
    spacing: 8,
    children: [
      for (final entry in options.entries)
        SizedBox(
          width: width,
          child: Semantics(
            selected: entry.key == value,
            enabled: enabled && !disabledOptions.contains(entry.key),
            inMutuallyExclusiveGroup: true,
            child: GlassTextButton(
              compact: true,
              selected: entry.key == value,
              key: ValueKey(
                '$name-${optionName?.call(entry.key) ?? entry.key}',
              ),
              onPressed: enabled && !disabledOptions.contains(entry.key)
                  ? () => onChanged(entry.key)
                  : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (leading != null) ...[
                    leading!(entry.key),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: AppText(
                      entry.value,
                      style: TextStyle(
                        fontSize: optionSize,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

/// App adapter for the package's own glass switch: controlled value, disabled
/// state, keyboard activation and a 48dp minimum target.
///
/// Ported from Wenku8_Flutter `lib/glass_controls.dart` (`AppGlassSwitch`).
/// Mechanical substitutions: `app_haptics.dart` -> the re-exported
/// `AppHaptics`/`HapticCue`; the package API is unchanged.
class AppGlassSwitch extends StatefulWidget {
  const AppGlassSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.activeColor,
    required this.inactiveColor,
    required this.thumbColor,
    required this.style,
    required this.reduceMotion,
    this.haptics = true,
    this.optimistic = true,
    this.semanticLabel,
  });
  final bool value, reduceMotion, haptics;

  /// Whether the thumb may move before an asynchronous [onChanged] settles.
  /// Confirmation / permission flows pass false so the control keeps showing
  /// the persisted value until the callback actually commits it.
  final bool optimistic;
  final String? semanticLabel;
  final FutureOr<void> Function(bool)? onChanged;
  final Color activeColor, inactiveColor, thumbColor;
  final easy.LiquidGlassStyle style;
  @override
  State<AppGlassSwitch> createState() => _AppGlassSwitchState();
}

class _AppGlassSwitchState extends State<AppGlassSwitch> {
  bool? _pending;
  int _request = 0;
  bool get _value => _pending ?? widget.value;
  Future<void> _change(bool value) async {
    final action = widget.onChanged;
    if (action == null || value == _value) return;
    if (widget.haptics) AppHaptics.play(context, HapticCue.selection);
    final request = ++_request;
    // Non-optimistic controls keep the controlled value on screen until the
    // callback commits (or rejects) the change.
    if (widget.optimistic) setState(() => _pending = value);
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
      label: widget.semanticLabel,
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

/// Upstream `AppControls.segments` and its `_material` glass recipe
/// (`app_ui.dart`), kept as the single entry point for archive segments.
abstract final class WenkuControls {
  static easy.LiquidGlassStyle _material(
    BuildContext context, {
    bool plate = false,
  }) {
    final appearance = GlassAppearance.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
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
      color: GlassAppearance.tintOf(context, opacity: appearance.opacity)
          .withValues(
            alpha: highContrast
                ? 1
                : plate
                ? appearance.opacity
                : .10,
          ),
      shadow: plate
          ? null
          : const easy.LiquidGlassShadow(blur: 6, opacity: .12, inset: 3),
      liteGlass: !PerformanceScope.of(context).glass || highContrast,
    );
  }

  /// Upstream `AppControls.toggle`: the package switch plus the archive's
  /// active/track/thumb tokens. fqapp maps `AppTonalColors` to
  /// `WenkuTonalColors`; both carry the same three roles.
  static Widget toggle(
    BuildContext context, {
    Key? key,
    required bool value,
    required FutureOr<void> Function(bool)? onChanged,
    bool haptics = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tonal = Theme.of(context).extension<WenkuTonalColors>();
    final highContrast = MediaQuery.highContrastOf(context);
    return AppGlassSwitch(
      key: key,
      value: value,
      onChanged: onChanged,
      haptics: haptics,
      activeColor: highContrast
          ? const Color(0xFF747474)
          : tonal?.active ??
                Color.lerp(
                  scheme.onSurface,
                  scheme.surface,
                  scheme.brightness == Brightness.dark ? .46 : .48,
                )!,
      inactiveColor:
          tonal?.track ??
          Color.lerp(
            scheme.surface,
            scheme.onSurface,
            scheme.brightness == Brightness.dark ? .16 : .10,
          )!,
      thumbColor: tonal?.thumb ?? ArchiveDesign.milk,
      style: _material(context),
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
  }

  static Widget segments<T extends Object>(
    BuildContext context, {
    Key? key,
    required T? groupValue,
    required Map<T, Widget> children,
    required ValueChanged<T?> onValueChanged,
    Set<T> disabledChildren = const {},
    bool haptics = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // fqapp e-ink / high contrast: no grey shadow halo or translucent pill;
    // the selection is a solid ink capsule with inverted text.
    final plain =
        WenkuTheme.isEinkOf(context) || MediaQuery.highContrastOf(context);
    return DefaultTextStyle.merge(
      style: TextStyle(
        color: scheme.onSurface,
        fontSize: 14,
        height: 1.4,
        fontWeight: FontWeight.w500,
      ),
      child: AppGlassSegments<T>(
        key: key,
        groupValue: groupValue,
        children: children,
        disabledChildren: disabledChildren,
        haptics: haptics,
        onValueChanged: onValueChanged,
        foregroundColor: scheme.onSurface,
        selectedForegroundColor: plain ? scheme.surface : null,
        style: _material(context, plate: true),
        pillStyle: easy.LiquidGlassSegmentedPillStyle(
          animated: !MediaQuery.disableAnimationsOf(context),
          glass: !plain && PerformanceScope.of(context).glass,
          duration: WenkuMotion.enter,
          glassStyle: _material(context),
          restStyle: easy.LiquidGlassStyle(
            color: plain
                ? scheme.onSurface
                : scheme.onSurface.withValues(alpha: .065),
          ),
        ),
      ),
    );
  }
}
