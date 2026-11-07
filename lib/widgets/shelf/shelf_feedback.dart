// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/app_interactions.dart:128-330 -> showNovelFeedback / NovelFeedbackNotice
//
// Mechanical substitutions for dependencies fqapp does not carry:
// - `app_ui.dart` AppText -> `src/app_text.dart`.
// - The full glass notice (LiquidGlass surface, NovelMotion entrance,
//   header-visibility tracking and an inline action button) is reduced to the
//   text-only notice the shelf sheets need. The important upstream property is
//   kept: the notice is inserted into the *root* Overlay, so feedback raised
//   from a pushed jelly sheet stays visible above that sheet instead of hiding
//   behind it.
//
// fqapp additions:
// - One notice per root Overlay, auto-dismissed by a Timer (the same pattern
//   as `PlayerToast`) so widget tests can pump it away deterministically.
// - `showShelfFeedback` is the single seam for the shelf sheets' validation
//   and save errors.

import 'dart:async';

import 'package:flutter/material.dart';

import '../wenku/src/app_text.dart';

/// Shows a transient notice above every route, including a pushed jelly sheet.
void showShelfFeedback(BuildContext context, String message) {
  if (!context.mounted || message.isEmpty) return;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _ShelfFeedback.show(overlay, context, message);
}

class _ShelfFeedback {
  _ShelfFeedback._();

  static const Duration _visibleFor = Duration(milliseconds: 2400);
  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(OverlayState overlay, BuildContext context, String message) {
    _remove();
    final themes = InheritedTheme.capture(from: context, to: overlay.context);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => themes.wrap(_ShelfFeedbackNotice(message: message)),
    );
    _entry = entry;
    overlay.insert(entry);
    _timer = Timer(_visibleFor, () {
      if (!identical(_entry, entry)) return;
      _remove();
    });
  }

  static void _remove() {
    _timer?.cancel();
    _timer = null;
    final entry = _entry;
    _entry = null;
    if (entry != null && entry.mounted) entry.remove();
  }
}

class _ShelfFeedbackNotice extends StatelessWidget {
  const _ShelfFeedbackNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: media.viewPadding.top + 16,
      left: media.viewPadding.left + 16,
      right: media.viewPadding.right + 16,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Material(
            key: const ValueKey('shelf-feedback'),
            color: scheme.inverseSurface,
            elevation: 6,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Semantics(
                liveRegion: true,
                container: true,
                child: AppText(
                  message,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: scheme.onInverseSurface,
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
