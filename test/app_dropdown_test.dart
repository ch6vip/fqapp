import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/app_dropdown.dart';
import 'package:fqapp/widgets/home/home_design.dart';

void _noop(int? _) {}

void main() {
  testWidgets('the dropdown menu takes the app surface shape', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: AppDropdown<int>(
                  value: 1,
                  items: [
                    AppDropdownItem(value: 1, label: '1 章'),
                    AppDropdownItem(value: 2, label: '2 章'),
                  ],
                  onChanged: _noop,
                ),
              ),
            );
          },
        ),
      ),
    );

    // `DropdownButton` paints its own menu and reads no theme for it, so the
    // shape has to come from the widget's own arguments. This is the guard
    // that the wrapper keeps passing them.
    final dropdown = tester.widget<DropdownButton<int>>(
      find.byType(DropdownButton<int>),
    );
    expect(
      dropdown.borderRadius,
      BorderRadius.circular(AppDropdown.radius),
      reason: 'the menu must use the app corner radius, not Material default',
    );
    expect(
      dropdown.dropdownColor,
      HomePalette.of(tester.element(find.byType(AppDropdown<int>))).surface,
      reason: 'the menu must sit on the app surface, not the canvas',
    );
  });

  testWidgets('the open menu is drawn with the app shape', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: AppDropdown<int>(
              value: 1,
              items: [
                AppDropdownItem(value: 1, label: '1 章'),
                AppDropdownItem(value: 2, label: '2 章'),
              ],
              onChanged: _noop,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();

    // The menu route paints its background through a CustomPaint whose radius
    // comes from the widget's borderRadius.
    final painters = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter)
        .whereType<CustomPainter>()
        .toList();
    expect(painters, isNotEmpty, reason: 'the menu must paint a background');

    // The items are there and read as one menu. The closed button shows the
    // selected label too, so the open menu adds a second copy of it.
    expect(find.text('1 章'), findsNWidgets(2));
    expect(find.text('2 章'), findsOneWidget);
  });

  testWidgets('the popup menu takes the app shape from the theme', (
    tester,
  ) async {
    late ThemeData theme;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: Builder(
          builder: (context) {
            theme = Theme.of(context);
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );
    final shape = theme.popupMenuTheme.shape;
    expect(shape, isA<RoundedRectangleBorder>());
    expect(
      (shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(16),
    );
    expect(theme.popupMenuTheme.elevation, 0);
  });
}
