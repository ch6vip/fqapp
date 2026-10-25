import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/widgets/player/playlet_more_panel.dart';
import 'package:fqapp/widgets/player/playlet_option_sheet.dart';

void main() {
  group('EpisodeSource variants parsing', () {
    test('parses the rendition list and keeps the selected stream first', () {
      final source = EpisodeSource.fromResponse({
        'data': {
          'video_url': 'https://cdn.example/720.mp4',
          'key_hex': 'aa',
          'variants': [
            {
              'name': '720P',
              'width': 720,
              'height': 1280,
              'url': 'https://cdn.example/720.mp4',
              'key_hex': 'aa',
            },
            {
              'name': '540P',
              'width': 540,
              'height': 960,
              'url': 'https://cdn.example/540.mp4',
              'key_hex': 'bb',
            },
            // 非法条目（非 http）必须被剔除。
            {'name': 'bad', 'url': 'file:///x.mp4', 'key_hex': 'cc'},
          ],
        },
      });
      expect(source.variants.map((v) => v.name).toList(), ['720P', '540P']);
      expect(source.variants[1].keyHex, 'bb');
      expect(
        source.withVariant(source.variants[1]).url,
        'https://cdn.example/540.mp4',
      );
      expect(source.withVariant(source.variants[1]).keyHex, 'bb');
      // 档位列表跟随副本，切档后面板仍能再切回。
      expect(source.withVariant(source.variants[1]).variants.length, 2);
    });

    test('keeps an empty variant list for single-stream responses', () {
      final source = EpisodeSource.fromResponse({
        'data': {'video_url': 'https://cdn.example/only.mp4'},
      });
      expect(source.variants, isEmpty);
    });
  });

  group('PlayletMorePanel quality entry row', () {
    final variants = [
      const EpisodeVariant(
        name: '720P',
        url: 'https://cdn.example/720.mp4',
        keyHex: 'aa',
        height: 1280,
      ),
      const EpisodeVariant(
        name: '540P',
        url: 'https://cdn.example/540.mp4',
        keyHex: 'bb',
        height: 960,
      ),
    ];

    Future<void> openPanel(
      WidgetTester tester, {
      String? qualityLabel,
      VoidCallback? onOpenQuality,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => PlayletMorePanel(
                      fillScreen: false,
                      defaultMute: true,
                      danmakuEnabled: false,
                      qualityLabel: qualityLabel,
                      onOpenQuality: onOpenQuality,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('hides the row for a single-stream episode', (tester) async {
      // 官方 `oi3/k.P()` 门在宿主侧：单流不传回调，整行不出现。
      await openPanel(tester);
      expect(find.text('清晰度'), findsNothing);
    });

    testWidgets('shows the current rendition and hands the tap to the host', (
      tester,
    ) async {
      var opened = 0;
      await openPanel(
        tester,
        qualityLabel: '720P',
        onOpenQuality: () => opened++,
      );
      expect(find.text('清晰度'), findsOneWidget);
      // 档位不再内联铺开：行尾只写当前档，点开交给宿主（档位弹层）。
      expect(find.text('540P'), findsNothing);
      expect(
        find.byKey(const ValueKey('player-more-quality-value')),
        findsOneWidget,
      );
      await tester.tap(find.text('清晰度'));
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the picker lists every rendition and returns the pick', (
      tester,
    ) async {
      EpisodeVariant? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () async {
                    picked = await showPlayletQualitySheet(
                      context,
                      variants: variants,
                      currentUrl: 'https://cdn.example/720.mp4',
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('player-quality-sheet')),
        findsOneWidget,
      );
      expect(find.text('720P'), findsOneWidget);
      expect(find.text('540P'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-quality-sheet-1')));
      await tester.pumpAndSettle();
      expect(picked?.name, '540P');
      expect(picked?.keyHex, 'bb');
    });
  });
}
