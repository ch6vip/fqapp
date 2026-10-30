import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/search_discovery.dart';
import 'package:fqapp/widgets/search/search_discovery.dart';

void main() {
  group('HotSearchBoard', () {
    testWidgets('renders words and reports selection', (tester) async {
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HotSearchBoard(
              hot: const HotSearch(
                entries: [
                  HotSearchEntry(
                    title: '洞房夜，摸到了老婆的狐狸耳朵',
                    hotValue: '183.8万',
                    badge: '巅峰榜',
                  ),
                  HotSearchEntry(title: '看过的书'),
                ],
              ),
              onSelect: (value) => picked = value,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('search_hot_words')), findsOneWidget);
      expect(find.text('183.8万'), findsOneWidget);
      expect(find.text('巅峰榜'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('search_hot_看过的书')));
      await tester.pump();
      expect(picked, '看过的书');
    });

    testWidgets('shows only the top ten rows of a long board', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HotSearchBoard(
              hot: HotSearch(
                entries: [
                  for (var i = 0; i < 50; i++)
                    HotSearchEntry(title: '词$i', hotValue: '${50 - i}.0万'),
                ],
              ),
              onSelect: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('词9'), findsOneWidget);
      expect(find.text('词10', skipOffstage: false), findsNothing);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('an empty board renders nothing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HotSearchBoard(hot: HotSearch.empty, onSelect: (_) {}),
          ),
        ),
      );
      expect(find.byKey(const Key('search_hot_words')), findsNothing);
    });
  });
}
