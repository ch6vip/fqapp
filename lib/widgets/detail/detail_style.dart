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
