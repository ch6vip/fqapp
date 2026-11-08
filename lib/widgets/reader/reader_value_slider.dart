// Ported from Wenku8_Flutter ebcd7f1, lib/reader_tools.dart:2245-end.
// The shared glass adapter is muted: this control owns semantic/detent haptics.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import '../wenku/wenku_ui.dart';
import 'reader_theme.dart';

class ReaderValueSlider extends StatefulWidget {
  const ReaderValueSlider({
    super.key,
    required this.sliderKey,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onCommitted,
    this.divisions,
    this.onPreview,
    this.onInteractionChanged,
    this.hapticSteps,
    this.inline = false,
    this.leading,
    this.reconcileValue = false,
    this.showLabels = true,
    this.preset,
  }) : assert(max > min),
       assert(divisions == null || divisions > 0),
       assert(hapticSteps == null || hapticSteps > 0);

  final Key sliderKey;
  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double) format;
  final ValueChanged<double>? onCommitted;
  final ValueChanged<double>? onPreview;
  final ValueChanged<bool>? onInteractionChanged;
  final int? hapticSteps;
  final bool inline;
  final Widget? leading;
  final bool reconcileValue;
  final bool showLabels;
  final ReaderThemePreset? preset;

  @override
  State<ReaderValueSlider> createState() => _ReaderValueSliderState();
}

class _ReaderValueSliderState extends State<ReaderValueSlider> {
  late double _draft = widget.value.clamp(widget.min, widget.max);
  bool _dragging = false;
  bool _pointerCancelled = false;
  bool _previewChanged = false;

  double get _unit => (widget.max - widget.min) / (widget.divisions ?? 20);
  int _notch(double value) =>
      ((value - widget.min) /
              (widget.max - widget.min) *
              (widget.hapticSteps ?? widget.divisions ?? 20))
          .round();

  void _change(double value) {
    if (!mounted || _pointerCancelled) return;
    final next = value.clamp(widget.min, widget.max);
    final previous = _draft;
    final firstDragChange = _dragging && !_previewChanged;
    if (_dragging && next != previous) _previewChanged = true;
    setState(() => _draft = next);
    if (next != previous &&
        (firstDragChange || !_dragging || _notch(next) != _notch(previous))) {
      AppHaptics.play(
        context,
        next == widget.min || next == widget.max
            ? HapticCue.boundary
            : HapticCue.detent,
      );
    }
    // Assistive increments do not have pointer start/end events.
    if (_dragging) {
      widget.onPreview?.call(next);
    } else if (next != previous) {
      widget.onCommitted?.call(next);
    }
  }

  void _adjust(double direction) {
    // A cancelled pointer cannot poison later assistive-technology actions.
    _pointerCancelled = false;
    _change((_draft + direction * _unit).clamp(widget.min, widget.max));
  }

  void _finish() {
    if (!_dragging) return;
    _dragging = false;
    final changed = _previewChanged;
    _previewChanged = false;
    if (changed) widget.onCommitted?.call(_draft);
    widget.onInteractionChanged?.call(false);
  }

  @override
  void didUpdateWidget(ReaderValueSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging &&
        (oldWidget.value != widget.value || widget.reconcileValue)) {
      _draft = widget.value.clamp(widget.min, widget.max);
    }
  }

  @override
  void dispose() {
    if (_dragging) {
      // Removal can precede pointer-up. Capture values, never use this State in
      // the deferred callback. Stateful owners guard their callbacks with mounted.
      final commit = _previewChanged ? widget.onCommitted : null;
      final interaction = widget.onInteractionChanged;
      final draft = _draft;
      _dragging = false;
      scheduleMicrotask(() {
        commit?.call(draft);
        interaction?.call(false);
      });
    }
    super.dispose();
  }

  Widget _slider(BuildContext context) => SizedBox(
    height: widget.inline ? 48 : 52,
    child: Semantics(
      key: ValueKey('reader-slider-semantics-${widget.label}'),
      label: widget.label,
      value: widget.format(_draft),
      increasedValue: widget.format(
        (_draft + _unit).clamp(widget.min, widget.max),
      ),
      decreasedValue: widget.format(
        (_draft - _unit).clamp(widget.min, widget.max),
      ),
      slider: true,
      enabled: widget.onCommitted != null,
      onIncrease: widget.onCommitted == null || _draft >= widget.max
          ? null
          : () => _adjust(1),
      onDecrease: widget.onCommitted == null || _draft <= widget.min
          ? null
          : () => _adjust(-1),
      child: ExcludeSemantics(
        child: Listener(
          onPointerCancel: (_) {
            _pointerCancelled = _dragging;
            _finish();
          },
          child: GlassControls.slider(
            context,
            key: widget.sliderKey,
            value: _draft.clamp(widget.min, widget.max),
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            haptics: false,
            compact: widget.inline,
            accentColor: widget.preset?.accentColor,
            trackColor: widget.preset?.borderColor,
            thumbColor: widget.preset?.panelColor,
            tint: widget.preset?.panelColor,
            onChanged: widget.onCommitted == null ? null : _change,
            onChangeStart: (_) {
              _pointerCancelled = false;
              _dragging = true;
              _previewChanged = false;
              widget.onInteractionChanged?.call(true);
            },
            onChangeEnd: (value) {
              if (_pointerCancelled || !_dragging) return;
              final next = value.clamp(widget.min, widget.max);
              if (next != _draft) _previewChanged = true;
              _draft = next;
              _finish();
            },
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.showLabels) return _slider(context);
    final value = Text(
      widget.format(_draft),
      maxLines: 1,
      style: TextStyle(
        fontSize: widget.inline ? 13 : 12,
        fontWeight: widget.inline ? FontWeight.w600 : null,
        color:
            widget.preset?.accentColor ?? Theme.of(context).colorScheme.primary,
      ),
    );
    if (widget.inline) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final leading = widget.leading ?? Text(widget.label);
          double textWidth(String text) {
            final painter = TextPainter(
              text: TextSpan(
                text: text,
                style: DefaultTextStyle.of(
                  context,
                ).style.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            final width = painter.width;
            painter.dispose();
            return width;
          }

          final label = leading is Text
              ? leading.data ?? widget.label
              : widget.label;
          final valueWidth = textWidth('100%');
          final trailing = widget.reconcileValue
              ? SizedBox(
                  width: valueWidth,
                  child: Align(alignment: Alignment.centerRight, child: value),
                )
              : value;
          final required = textWidth(label) + valueWidth + 8 + 140;
          if (constraints.maxWidth < required) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(child: leading),
                    trailing,
                  ],
                ),
                _slider(context),
              ],
            );
          }
          return Row(
            children: [
              leading,
              const SizedBox(width: 4),
              Expanded(child: _slider(context)),
              const SizedBox(width: 4),
              trailing,
            ],
          );
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(widget.label, style: const TextStyle(fontSize: 13)),
              ),
              value,
            ],
          ),
          const SizedBox(height: 4),
          _slider(context),
        ],
      ),
    );
  }
}
