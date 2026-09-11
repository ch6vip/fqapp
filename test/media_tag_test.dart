import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';

/// Card shapes mirror a live 漫剧 homepage payload: `tag_info` rides on the card
/// object beside title/cover and carries its own label plus both gradients.
Map<String, dynamic> _card({
  required String title,
  Map<String, dynamic>? tagInfo,
}) => {
  'video_data': [
    {
      'title': title,
      'cover': 'https://example.test/$title.jpg',
      'episode_cnt': '66',
      'vid': '7679385177390337048',
      'tag_info': ?tagInfo,
    },
  ],
};

/// Real upstream values: 上新 is green, 爆款 is red.
const _newTag = {
  'text': '上新',
  'bg_color': ['#00B876', '#15D791'],
  'dark_bg_color': ['#009962', '#11B279'],
};
const _hotTag = {
  'text': '爆款',
  'bg_color': ['#F44018', '#FF6459'],
  'dark_bg_color': ['#F44018', '#FF6459'],
};

void main() {
  group('MediaTag parsing', () {
    test('reads the label and both gradients from a card', () {
      final items = parseMediaItems(_card(title: 'a', tagInfo: _newTag));
      expect(items, hasLength(1));
      final tag = items.single.tag;
      expect(tag, isNotNull);
      expect(tag!.text, '上新');
      expect(tag.lightColors, ['#00B876', '#15D791']);
      expect(tag.darkColors, ['#009962', '#11B279']);
    });

    test('keeps each label its own colours', () {
      // 爆款 is red, so colours must come from the payload, not the label.
      final items = parseMediaItems(_card(title: 'b', tagInfo: _hotTag));
      final tag = items.single.tag!;
      expect(tag.text, '爆款');
      expect(tag.lightColors, ['#F44018', '#FF6459']);
    });

    test('a card without a tag has none', () {
      expect(parseMediaItems(_card(title: 'c')).single.tag, isNull);
    });

    test('an empty or missing label yields no tag', () {
      expect(
        parseMediaItems(
          _card(
            title: 'd',
            tagInfo: {
              'text': '  ',
              'bg_color': ['#00B876'],
            },
          ),
        ).single.tag,
        isNull,
      );
      expect(
        parseMediaItems(
          _card(
            title: 'e',
            tagInfo: {
              'bg_color': ['#00B876'],
            },
          ),
        ).single.tag,
        isNull,
      );
    });

    test('malformed colours are dropped, the label survives', () {
      final items = parseMediaItems(
        _card(
          title: 'f',
          tagInfo: {
            'text': '上新',
            'bg_color': ['#00B876', 'red', '#GGGGGG', 42, ''],
          },
        ),
      );
      final tag = items.single.tag!;
      expect(tag.text, '上新');
      expect(tag.lightColors, ['#00B876']);
      expect(tag.darkColors, isEmpty);
    });

    test('colorsFor prefers the theme set and falls back to the other', () {
      const both = MediaTag(
        text: 'x',
        lightColors: ['#111111'],
        darkColors: ['#222222'],
      );
      expect(both.colorsFor(dark: false), ['#111111']);
      expect(both.colorsFor(dark: true), ['#222222']);

      const lightOnly = MediaTag(text: 'x', lightColors: ['#111111']);
      expect(lightOnly.colorsFor(dark: true), ['#111111']);

      const darkOnly = MediaTag(text: 'x', darkColors: ['#222222']);
      expect(darkOnly.colorsFor(dark: false), ['#222222']);

      expect(const MediaTag(text: 'x').colorsFor(dark: true), isEmpty);
    });

    test('hasColors separates badges from plain labels', () {
      // Search results carry the kind label in the same field with no colours.
      expect(const MediaTag(text: '漫剧').hasColors, isFalse);
      expect(
        const MediaTag(text: '上新', lightColors: ['#00B876']).hasColors,
        isTrue,
      );
      // Either variant alone is enough.
      expect(
        const MediaTag(text: '上新', darkColors: ['#009962']).hasColors,
        isTrue,
      );
    });
  });

  group('HomeMediaCard tag chip', () {
    Future<void> pump(
      WidgetTester tester,
      MediaItem item, {
      bool dark = false,
    }) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          home: Scaffold(
            body: SizedBox(
              width: 160,
              child: HomeMediaCard(item: item, onTap: () {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // Built through parseMediaItems, which is the real path: it merges each
    // `video_data` child into its parent card before parsing.
    MediaItem itemWith(Map<String, dynamic>? tagInfo) =>
        parseMediaItems(_card(title: '测试', tagInfo: tagInfo)).single;

    testWidgets('renders the tag next to the kind label', (tester) async {
      final item = itemWith(_newTag);
      await pump(tester, item);
      expect(find.text('上新'), findsOneWidget);
      // The kind chip is always present alongside.
      expect(find.text(homeKindLabel(item.kind)), findsWidgets);
      expect(find.byKey(const Key('home_card_tag')), findsOneWidget);
    });

    testWidgets('paints the upstream gradient', (tester) async {
      await pump(tester, itemWith(_newTag));
      final chip = tester.widget<Container>(
        find
            .descendant(
              of: find.byKey(const Key('home_card_tag')),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = chip.decoration! as BoxDecoration;
      expect(decoration.gradient, isA<LinearGradient>());
      final colors = (decoration.gradient! as LinearGradient).colors;
      expect(colors.first, const Color(0xFF00B876));
      expect(colors.last, const Color(0xFF15D791));
    });

    testWidgets('uses the dark gradient in dark mode', (tester) async {
      await pump(tester, itemWith(_newTag), dark: true);
      final chip = tester.widget<Container>(
        find
            .descendant(
              of: find.byKey(const Key('home_card_tag')),
              matching: find.byType(Container),
            )
            .first,
      );
      final colors =
          ((chip.decoration! as BoxDecoration).gradient! as LinearGradient)
              .colors;
      expect(colors.first, const Color(0xFF009962));
    });

    testWidgets('draws no tag chip without a tag', (tester) async {
      final item = itemWith(null);
      await pump(tester, item);
      expect(find.byKey(const Key('home_card_tag')), findsNothing);
      // The kind chip is still rendered.
      expect(find.text(homeKindLabel(item.kind)), findsWidgets);
    });

    testWidgets('a tag without colours is a label, not a badge', (
      tester,
    ) async {
      // Search results put a plain genre label in the same field. Colours are
      // what mark a promotional badge, so an uncoloured tag renders nothing —
      // the card's own kind chip already covers the label case.
      final item = itemWith({'text': '小说改编'});
      await pump(tester, item);
      expect(find.byKey(const Key('home_card_tag')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long label does not overflow the cover', (tester) async {
      await pump(tester, itemWith({'text': '超级无敌长的新标签文案测试'}));
      expect(tester.takeException(), isNull);
    });
  });

  group('real feed shapes', () {
    // Recorded from a live 漫剧 homepage response: tag_info rides beside
    // title/cover and only ever carries coloured badges there.
    test('home feed tags are all coloured badges', () {
      final items = parseMediaItems({
        'data': {
          'tab_item': [
            {
              'cell_data': [
                {
                  'video_data': [
                    {
                      'title': '三天后穿越古代，我贷款搬空商城！',
                      'cover': 'https://example.test/a.jpg',
                      'vid': '7679385177390337048',
                      'tag_info': {
                        'text': '上新',
                        'bg_color': ['#00B876', '#15D791'],
                        'dark_bg_color': ['#009962', '#11B279'],
                      },
                    },
                  ],
                },
                {
                  'video_data': [
                    {
                      'title': '糯糯下山，师兄们都慌了',
                      'cover': 'https://example.test/b.jpg',
                      'vid': '7678549304226614297',
                      'tag_info': {
                        'text': '爆款',
                        'bg_color': ['#F44018', '#FF6459'],
                        'dark_bg_color': ['#F44018', '#FF6459'],
                      },
                    },
                  ],
                },
              ],
            },
          ],
        },
      });
      final tags = items.map((i) => i.tag).whereType<MediaTag>().toList();
      expect(tags.map((t) => t.text), containsAll(['上新', '爆款']));
      expect(tags.every((t) => t.hasColors), isTrue);
    });

    test('search feed mixes coloured badges with plain labels', () {
      // The same field carries the genre on search cards, without colours.
      final items = parseMediaItems({
        'search_tabs': [
          {
            'data': [
              {
                'title': '作死系统，非要让我去闯祸',
                'cover': 'https://example.test/c.jpg',
                'vid': '1',
                'tag_info': {
                  'text': '上新',
                  'bg_color': ['#00B876', '#15D791'],
                },
                'cover_tag_info_list': [
                  {
                    'text': '上新',
                    'bg_color': ['#00B876', '#15D791'],
                  },
                ],
              },
              {
                'title': '九渊',
                'cover': 'https://example.test/d.jpg',
                'vid': '2',
                'tag_info': {'text': '小说改编'},
                'cover_tag_info_list': [
                  {'text': '小说改编'},
                ],
              },
            ],
          },
        ],
      });
      final badges = items
          .map((i) => i.tag)
          .whereType<MediaTag>()
          .where((t) => t.hasColors)
          .toList();
      final labels = items
          .map((i) => i.tag)
          .whereType<MediaTag>()
          .where((t) => !t.hasColors)
          .toList();
      expect(badges.map((t) => t.text), ['上新']);
      expect(labels.map((t) => t.text), ['小说改编']);
    });
  });
}
