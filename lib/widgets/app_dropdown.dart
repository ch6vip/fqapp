import 'package:flutter/material.dart';

import 'home/home_design.dart';

/// The app's dropdown, in one shape.
///
/// `DropdownButton` draws its own menu: a `CustomPaint` over a 2dp radius and
/// the theme's `canvasColor`, with no theme lookup anywhere. So a dropdown
/// built straight from it looks different from every other surface in the
/// app - a small square menu on the canvas colour, next to cards with a 16dp
/// radius, a hairline and a `surface` fill. Two dropdowns in different
/// settings pages also ended up different from each other, because each one
/// passed its own arguments.
///
/// This wrapper is the single place where that is decided. The menu takes the
/// app's surface, hairline and corner radius, so it reads as one object with
/// the cards around it.
///
/// `PopupMenuButton` gets its shape from `ThemeData.popupMenuTheme` and
/// needs no wrapper.
class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
    this.disabledHint,
    this.isDense = false,
    this.isExpanded = false,
    this.style,
    this.menuMaxHeight,
  });

  /// The menu's corner radius; the same token the cards use.
  static const double radius = 16;

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final Widget? hint;
  final Widget? disabledHint;
  final bool isDense;
  final bool isExpanded;
  final TextStyle? style;
  final double? menuMaxHeight;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        items: items,
        onChanged: onChanged,
        hint: hint,
        disabledHint: disabledHint,
        isDense: isDense,
        isExpanded: isExpanded,
        style: style,
        // The menu is drawn by the widget itself, so both of these have to be
        // passed explicitly: the radius is otherwise 2dp and the fill is the
        // canvas colour.
        borderRadius: BorderRadius.circular(radius),
        dropdownColor: palette.surface,
        menuMaxHeight: menuMaxHeight,
      ),
    );
  }
}

/// A dropdown item with the app's menu shape.
///
/// The label carries no style of its own: `DropdownButton` applies its
/// `style` to the selected row *and* to every row in the open menu, so a
/// label that set its own colour would silently override what the caller
/// asked for. The row is not `const` only because the child is built here.
class AppDropdownItem<T> extends DropdownMenuItem<T> {
  AppDropdownItem({super.key, required super.value, required String label})
    : super(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis));
}
