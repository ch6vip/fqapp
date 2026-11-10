// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/setting_menu.dart -> GlassSettingMenu
//
// The upstream `GlassMenuAnchor` / `showGlassMenu` / `GlassMenuItem` /
// `_GlassMenuPlacement` copies that this file used to vendor now live in the
// single shared `wenku_overlay.dart`; this file keeps only the settings row
// adapter and imports those classes from there.
//
// Mechanical substitutions for dependencies fqapp does not carry:
// - `NovelMotion` -> `WenkuMotion` (same contact/enter/exit durations).
// - `app_ui.dart` AppText/ArchivePart/ArchiveIcon/GlassForeground ->
//   the shared `wenku_ui.dart` exports.
// - The upstream persisted haptics service is absent; menu taps keep
//   HapticCue.selection through JellyTapSurface.
// - `MediaQuery.disableAnimationsOf(context)` supplies the reduce-motion flag,
//   exactly as the upstream call sites do.
// - fqapp-only `valueLabel`: the inline trigger may show a short label while
//   the menu still lists the full option labels.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../services/app_style_tokens.dart';
import '../settings/classic_settings_icons.dart';
import '../settings/settings_widgets.dart';

import 'src/app_text.dart';
import 'wenku_archive.dart';
import 'wenku_glass.dart';
import 'wenku_icons.dart';
import 'wenku_overlay.dart';

/// The whole settings row is tappable; its actual glass selector is the menu's
/// source. Labels and controls share the same responsive layout in the reader.
class GlassSettingMenu<T> extends StatefulWidget {
  const GlassSettingMenu({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.reduceMotion,
    this.semanticLabel,
    this.valueLabel,
  });
  final IconData icon;
  final String label;
  final String? semanticLabel;

  /// Optional inline value text. Upstream derives the trigger from the
  /// selected option's label; fqapp keeps short labels for values whose full
  /// label would wrap the settings row.
  final String? valueLabel;
  final T value;
  final Map<T, String> options;
  final FutureOr<void> Function(T) onChanged;
  final bool reduceMotion;
  @override
  State<GlassSettingMenu<T>> createState() => _GlassSettingMenuState<T>();
}

class _GlassSettingMenuState<T> extends State<GlassSettingMenu<T>> {
  final _anchor = GlobalKey();
  bool _saving = false;
  Future<void> _open() async {
    if (_saving) return;
    final source = _anchor.currentContext;
    if (source == null) return;
    final selected = await showGlassMenu<T>(
      context: source,
      reduceMotion: widget.reduceMotion,
      // The row already owns the visible trigger; do not paint a second copy
      // of its foreground inside the route.
      captureSource: false,
      builder: (menu) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, entry) in widget.options.entries.indexed)
              GlassMenuItem(
                order: index,
                label: entry.value,
                selected: entry.key == widget.value,
                onPressed: () => Navigator.pop(menu, entry.key),
              ),
          ],
        ),
      ),
    );
    if (mounted && selected != null && selected != widget.value) {
      setState(() => _saving = true);
      try {
        await widget.onChanged(selected);
      } finally {
        if (mounted) setState(() => _saving = false);
      }
    }
  }

  Future<void> _openClassic() async {
    if (_saving) return;
    final scheme = Theme.of(context).colorScheme;
    final selected = await showDialog<T>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        // The fill comes from `dialogTheme`; the row style matches
        // `showAiChoiceDialog` so both classic pickers read as one control.
        title: Text(widget.label),
        children: [
          for (final option in widget.options.entries)
            ListTile(
              title: Text(option.value),
              trailing: option.key == widget.value
                  ? Icon(Icons.check, size: 18, color: scheme.onSurface)
                  : null,
              onTap: () => Navigator.pop(dialogContext, option.key),
            ),
        ],
      ),
    );
    if (!mounted || selected == null || selected == widget.value) return;
    setState(() => _saving = true);
    try {
      await widget.onChanged(selected);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (AppStyleTokens.of(context).isClassic) {
      return SettingsRow(
        icon: classicSettingsIcon(widget.label, widget.icon),
        iconTile: true,
        title: widget.label,
        value: widget.valueLabel ?? widget.options[widget.value] ?? '',
        onTap: _saving ? null : _openClassic,
      );
    }
    final label = ArchivePart(
      start: .18,
      end: .84,
      child: Row(
        children: [
          ArchiveIcon(widget.icon, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: AppText(
              widget.label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    final selector = GlassMenuAnchor(
      child: Builder(
        key: _anchor,
        builder: (context) => LiquidGlass(
          radius: 20,
          elevated: false,
          semanticLabel: widget.semanticLabel ?? '选择${widget.label}',
          onTap: _saving ? null : _open,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: ArchivePart(
            start: .24,
            end: .88,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: AppText(
                    widget.valueLabel ?? widget.options[widget.value] ?? '',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 7),
                const ArchiveIcon(CupertinoIcons.chevron_down, size: 14),
              ],
            ),
          ),
        ),
      ),
    );
    return JellyTapSurface(
      onTap: _saving ? null : _open,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          return constraints.maxWidth < 160 * scale + 70
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    label,
                    const SizedBox(height: 12),
                    Align(alignment: Alignment.centerRight, child: selector),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: label),
                    const SizedBox(width: 12),
                    // Short values use only their natural width instead of
                    // reserving two thirds of the row and wrapping its label.
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * .55,
                      ),
                      child: selector,
                    ),
                  ],
                );
        },
      ),
    );
  }
}
