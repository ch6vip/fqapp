import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';
import 'package:fqapp/widgets/reader/reader_value_slider.dart';
import 'package:fqapp/widgets/reader/settings/reader_more_settings_sheet.dart';
import 'package:fqapp/widgets/reader/settings/reader_settings_widgets.dart';

void main() {
  for (final layout in const [
    (size: Size(320, 700), scale: 2.0, preset: ReaderThemePreset.light),
    (size: Size(320, 700), scale: 2.0, preset: ReaderThemePreset.dark),
    (size: Size(780, 360), scale: 2.0, preset: ReaderThemePreset.dark),
  ]) {
    testWidgets('slider labels and values keep gutters at ${layout.size}, '
        '${layout.scale}x, ${layout.preset.name}', (tester) async {
      await _pumpForm(
        tester,
        size: layout.size,
        scale: layout.scale,
        initial: ReaderPreferences(themePreset: layout.preset),
      );
      final gutter = layout.size.width <= 360 ? 16.0 : 20.0;
      for (final label in const [
        '字号',
        '字距',
        '标题字号',
        '行距',
        '段距',
        '左右边距',
        '上下边距',
      ]) {
        final control = _slider(label);
        await tester.ensureVisible(control);
        await tester.pumpAndSettle();
        final widget = tester.widget<ReaderValueSlider>(control);
        final labelFinder = find.descendant(
          of: control,
          matching: find.text(label),
        );
        final valueFinder = find.descendant(
          of: control,
          matching: find.text(widget.format(widget.value)),
        );
        final labelRect = tester.getRect(labelFinder);
        final valueRect = tester.getRect(valueFinder);
        expect(labelRect.left, closeTo(gutter, 0.01), reason: label);
        expect(
          valueRect.right,
          closeTo(layout.size.width - gutter, 0.01),
          reason: label,
        );
        expect(
          labelRect.right,
          lessThanOrEqualTo(valueRect.left),
          reason: label,
        );
        for (final text in [labelFinder, valueFinder]) {
          expect(
            tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
            isFalse,
            reason: label,
          );
        }
        expect(tester.takeException(), isNull, reason: label);
      }
      final finalAction = find.text('正文替换');
      await tester.ensureVisible(finalAction);
      await tester.pumpAndSettle();
      expect(finalAction.hitTestable(), findsOneWidget);
    });
  }

  testWidgets('normal form is dense while chip touch targets remain 48dp', (
    tester,
  ) async {
    await _pumpForm(tester);
    final font = _slider('字号');
    expect(tester.getSize(font).height, 48);
    final labelRect = tester.getRect(
      find.descendant(of: font, matching: find.text('字号')),
    );
    final valueRect = tester.getRect(
      find.descendant(of: font, matching: find.text('18 pt')),
    );
    expect(labelRect.center.dy, closeTo(valueRect.center.dy, 0.01));
    for (final key in const [
      'reader-font-weight-300',
      'reader-font-weight-400',
      'reader-font-weight-500',
      'reader-font-weight-600',
      'reader-font-weight-700',
      'reader-title-alignment-start',
      'reader-title-alignment-center',
      'reader-auto-turn-3',
      'reader-info-detailed',
      'reader-narration-style-auto',
      'reader-narration-color-auto',
    ]) {
      final target = find.byKey(ValueKey(key));
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      final size = tester.getSize(target);
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }
    // Weight choices fit one compact row instead of one choice per line.
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('reader-font-weight-300')))
          .dy,
      tester
          .getTopLeft(find.byKey(const ValueKey('reader-font-weight-700')))
          .dy,
    );
    final alignment = find.text('标题对齐');
    await tester.ensureVisible(alignment);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(alignment).height,
      lessThan(28),
      reason: '四字标签不应被窄标签列挤成两行',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag previews and changed options reach preference callbacks', (
    tester,
  ) async {
    final changes = <ReaderPreferences>[];
    await _pumpForm(tester, onChanged: changes.add);
    final track = find.byKey(const ValueKey('reader-font-size'));
    final gesture = await tester.startGesture(tester.getCenter(track));
    await gesture.moveBy(const Offset(42, 0));
    await tester.pump(const Duration(milliseconds: 150));
    expect(changes, isNotEmpty, reason: 'preview arrives before pointer up');
    expect(changes.last.fontSize, greaterThan(18));
    final preview = changes.last.fontSize;
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 150));
    expect(changes.last.fontSize, preview);
    expect(
      find.descendant(
        of: _slider('字号'),
        matching: find.text('${preview.round()} pt'),
      ),
      findsOneWidget,
    );

    for (final (key, verify) in <(String, bool Function(ReaderPreferences))>[
      ('reader-font-weight-700', (p) => p.fontWeight == 700),
      (
        'reader-title-alignment-center',
        (p) => p.titleAlignment == ReaderTitleAlignment.center,
      ),
      ('reader-auto-turn-20', (p) => p.autoTurnSeconds == 20),
      (
        'reader-info-detailed',
        (p) => p.readingInfoMode == ReaderInfoMode.detailed,
      ),
      (
        'reader-narration-style-${ReaderPreferences.narrationHighlightStyleUnderline}',
        (p) =>
            p.narrationHighlightStyle ==
            ReaderPreferences.narrationHighlightStyleUnderline,
      ),
    ]) {
      final target = find.byKey(ValueKey(key));
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 150));
      expect(verify(changes.last), isTrue, reason: key);
      expect(changes.last.fontSize, preview, reason: 'prior values survive');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('archive and embedded listening keep their existing layout', (
    tester,
  ) async {
    await _pumpForm(tester, style: AppThemeStyle.archive);
    expect(tester.widget<ReaderValueSlider>(_slider('字号')).inline, isFalse);
    expect(find.text('文字与标题'), findsNothing);
    expect(find.text('排版'), findsOneWidget);

    await _pumpForm(tester, embeddedListening: true);
    expect(find.byType(ReaderSettingsFormLayout), findsNothing);
    expect(find.byType(ReaderValueSlider), findsNothing);
    expect(find.text('跟随翻页'), findsOneWidget);
    expect(find.text('朗读句高亮'), findsOneWidget);
    final style = find.byKey(const ValueKey('reader-narration-style-auto'));
    expect(tester.getSize(style).height, lessThan(48));
    expect(tester.takeException(), isNull);
  });
}

Finder _slider(String label) => find.byWidgetPredicate(
  (widget) => widget is ReaderValueSlider && widget.label == label,
);

Future<void> _pumpForm(
  WidgetTester tester, {
  Size size = const Size(375, 700),
  double scale = 1,
  ReaderPreferences initial = const ReaderPreferences(),
  AppThemeStyle style = AppThemeStyle.classic,
  ValueChanged<ReaderPreferences>? onChanged,
  bool embeddedListening = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final store = AppThemeStyleStore()..value = style;
  addTearDown(store.dispose);
  final sheet = ReaderMoreSettingsSheet(
    initialValue: initial,
    onChanged: onChanged ?? (_) {},
    embedded: embeddedListening,
    category: embeddedListening
        ? ReaderBehaviorCategory.listening
        : ReaderBehaviorCategory.all,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        brightness: initial.themePreset.isDark
            ? Brightness.dark
            : Brightness.light,
      ),
      builder: (context, child) => AppUiScope(
        store: store,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: embeddedListening
              ? SingleChildScrollView(child: sheet)
              : sheet,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
