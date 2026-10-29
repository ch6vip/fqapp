import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/audio/audio_floating_player.dart';

const _width = 162.0;
const _height = 50.0;
const _closeWidth = 74.0;
const _surface = Size(400, 800);

Finder get _pan => find.byWidgetPredicate(
  (widget) => widget is GestureDetector && widget.onPanStart != null,
);

AnimatedPositioned _positioned(WidgetTester tester) =>
    tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned));

Future<void> _pump(
  WidgetTester tester, {
  required List<int> closes,
  double bottomInset = 0,
  EdgeInsets viewPadding = EdgeInsets.zero,
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = _surface;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final position = ValueNotifier<Duration>(Duration.zero);
  addTearDown(position.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(viewPadding: viewPadding, disableAnimations: reduceMotion),
          child: Material(
            child: SizedBox.expand(
              child: AudioFloatingPlayer(
                title: 'test',
                cover: '',
                progress: position,
                readProgress: () => 0,
                playing: false,
                loading: false,
                canToggle: true,
                visible: true,
                bottomInset: bottomInset,
                onOpen: () {},
                onToggle: () {},
                onClose: () => closes[0]++,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('rests at the bottom-left with a 1dp inset', (tester) async {
    final closes = <int>[0];
    await _pump(tester, closes: closes, bottomInset: 20);

    final placed = _positioned(tester);
    expect(placed.left, 1);
    expect(placed.top, _surface.height - _height - 18 - 20);
    expect(placed.width, _width);
    expect(placed.height, _height);
  });

  testWidgets('releasing on the right half snaps to the right edge', (
    tester,
  ) async {
    final closes = <int>[0];
    await _pump(tester, closes: closes);
    expect(_positioned(tester).left, 1);

    await tester.drag(_pan, const Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 250));

    final placed = _positioned(tester);
    expect(placed.left, _surface.width - 1 - _width);
    expect(placed.top, _surface.height - _height - 18);
  });

  testWidgets('releasing above the rest rect snaps back to 142dp', (
    tester,
  ) async {
    final closes = <int>[0];
    await _pump(tester, closes: closes);

    await tester.drag(_pan, const Offset(0, -800));
    await tester.pump(const Duration(milliseconds: 250));

    final placed = _positioned(tester);
    expect(placed.top, 142);
    expect(placed.left, 1);
  });

  testWidgets('drag may reach -12dp but the rest position never does', (
    tester,
  ) async {
    final closes = <int>[0];
    await _pump(tester, closes: closes);

    final gesture = await tester.startGesture(tester.getCenter(_pan));
    // The first move only crosses the drag threshold (onPanStart), so a
    // second move is what feeds the actual drag update.
    await gesture.moveBy(const Offset(-20, 0));
    await gesture.moveBy(const Offset(-400, 0));
    await tester.pump();
    expect(_positioned(tester).left, -12);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 250));
    expect(_positioned(tester).left, 1);
  });

  testWidgets('close shrinks anchored left and reports after 300ms', (
    tester,
  ) async {
    final closes = <int>[0];
    await _pump(tester, closes: closes);

    // Snap right first: a right-anchored shrink would be visible from here.
    await tester.drag(_pan, const Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_positioned(tester).left, _surface.width - 1 - _width);

    await tester.tap(find.byKey(const ValueKey('audio-floating-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(closes[0], 0);

    final shrinking = tester.widget<Align>(
      find
          .descendant(of: find.byType(ClipRect), matching: find.byType(Align))
          .first,
    );
    expect(shrinking.alignment, Alignment.centerLeft);

    await tester.pump(const Duration(milliseconds: 200));
    expect(closes[0], 1);
    final shrunk = tester.widget<Align>(
      find
          .descendant(of: find.byType(ClipRect), matching: find.byType(Align))
          .first,
    );
    expect(shrunk.widthFactor, closeTo(_closeWidth / _width, 0.001));
  });

  testWidgets('reduced motion closes immediately and snaps without animation', (
    tester,
  ) async {
    final closes = <int>[0];
    await _pump(tester, closes: closes, reduceMotion: true);
    expect(_positioned(tester).duration, Duration.zero);

    await tester.drag(_pan, const Offset(200, 0));
    await tester.pump();
    final placed = _positioned(tester);
    expect(placed.duration, Duration.zero);
    expect(placed.left, _surface.width - 1 - _width);

    await tester.tap(find.byKey(const ValueKey('audio-floating-close')));
    await tester.pump();
    expect(closes[0], 1);
  });
}
