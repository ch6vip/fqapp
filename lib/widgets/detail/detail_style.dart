import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// The one accent fill the detail page uses for primary actions.
///
/// E-ink has no brand orange; the primary pill becomes solid black there.
Color detailAccentFill(HomePalette palette) =>
    palette.eink ? palette.ink : HomePalette.accent;

/// Text/icon colour that sits on [detailAccentFill].
Color detailOnAccent(HomePalette palette) =>
    palette.eink ? palette.surface : Colors.white;

/// Mockup star gold (`--m-star`), which e-ink replaces with ink.
Color detailStarColor(HomePalette palette) =>
    palette.eink ? palette.ink : const Color(0xFFF2A93B);

/// Tabular figures for the score, ID and progress (`font-variant-numeric`).
/// No font family is set: the detail page keeps the app's own font.
const List<FontFeature> detailNumericFeatures = [
  FontFeature.tabularFigures(),
];

/// Rank pill fill (`--m-cur`): the current-chapter tint, black/white on e-ink.
Color detailRankFill(HomePalette palette) {
  if (palette.eink) return palette.surface;
  return palette.dark ? const Color(0xFF3A2420) : const Color(0xFFFDECE8);
}

/// Progress track fill (`--m-soft`).
Color detailProgressTrack(HomePalette palette) => palette.soft;

/// Progress bar fill: brand accent, solid black on e-ink.
Color detailProgressFill(HomePalette palette) =>
    palette.eink ? palette.ink : HomePalette.accent;

/// Primary action: a solid accent pill. This is the only filled style on the
/// detail page.
ButtonStyle detailPrimaryButtonStyle(
  HomePalette palette, {
  Size minimumSize = const Size(110, 46),
}) => FilledButton.styleFrom(
  backgroundColor: detailAccentFill(palette),
  foregroundColor: detailOnAccent(palette),
  disabledBackgroundColor: palette.soft,
  disabledForegroundColor: palette.muted,
  minimumSize: minimumSize,
  visualDensity: VisualDensity.standard,
  shape: const StadiumBorder(),
);

/// Secondary action: a hairline outline on the page surface.
ButtonStyle detailOutlineButtonStyle(
  HomePalette palette, {
  Size minimumSize = const Size(110, 46),
}) => OutlinedButton.styleFrom(
  foregroundColor: palette.ink,
  side: BorderSide(color: palette.line),
  minimumSize: minimumSize,
  visualDensity: VisualDensity.standard,
  shape: const StadiumBorder(),
);
