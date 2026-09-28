import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/widgets/player/playlet_more_panel.dart';

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
      expect(source.withVariant(source.variants[1]).url, 'https://cdn.example/540.mp4');
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

  group('PlayletMorePanel quality row', () {
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
      required List<EpisodeVariant> qualityVariants,
      String? currentQualityUrl,
      ValueChanged<EpisodeVariant>? onQualitySelected,
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
                      rate: 1.0,
                      fillScreen: false,
                      defaultMute: true,
                      danmakuEnabled: false,
                      qualityVariants: qualityVariants,
                      currentQualityUrl: currentQualityUrl,
                      onQualitySelected: onQualitySelected,
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
      await openPanel(
        tester,
        qualityVariants: const [],
        onQualitySelected: (_) {},
      );
      expect(find.text('清晰度'), findsNothing);
    });

    testWidgets('shows the row with the current rendition and selects another',
        (tester) async {
      EpisodeVariant? picked;
      await openPanel(
        tester,
        qualityVariants: variants,
        currentQualityUrl: 'https://cdn.example/720.mp4',
        onQualitySelected: (v) => picked = v,
      );
      expect(find.text('清晰度'), findsOneWidget);
      // 档位列表默认收起，行尾显示当前档名。
      expect(find.text('720P'), findsOneWidget);
      await tester.tap(find.text('清晰度'));
      await tester.pumpAndSettle();
      // 展开后两档都可见，当前档仅一行（行尾名收起后才出现）。
      expect(find.text('540P'), findsOneWidget);
      expect(find.byKey(const ValueKey('player-more-quality-1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-more-quality-1')));
      await tester.pumpAndSettle();
      expect(picked?.name, '540P');
      expect(picked?.keyHex, 'bb');
    });
  });
}
