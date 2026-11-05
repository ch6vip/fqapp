import 'package:flutter/material.dart';

/// fqapp ships a single Chinese locale. The upstream widget API stays in
/// place, while locale conversion and its persisted dictionaries do not.
String appText(BuildContext context, String value) => value;

class AppText extends Text {
  const AppText(
    super.data, {
    super.key,
    super.style,
    super.strutStyle,
    super.textAlign,
    super.textDirection,
    super.locale,
    super.softWrap,
    super.overflow,
    super.textScaler,
    super.maxLines,
    super.semanticsLabel,
    super.textWidthBasis,
    super.textHeightBehavior,
    super.selectionColor,
  });
}
