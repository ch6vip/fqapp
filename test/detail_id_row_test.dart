import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/widgets/detail/detail_id_row.dart';

import 'support/fakes.dart';

void main() {
  group('DetailIdRow', () {
    Future<void> pump(WidgetTester tester, {required String id}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DetailIdRow(id: id)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the id and hides itself when empty', (tester) async {
      await pump(tester, id: '7675233261169167422');
      expect(find.byKey(const Key('detail_id_row')), findsOneWidget);
      expect(find.text('7675233261169167422'), findsOneWidget);

      await pump(tester, id: '');
      expect(find.byKey(const Key('detail_id_row')), findsNothing);
    });

    testWidgets('the id is selectable', (tester) async {
      await pump(tester, id: '123');
      expect(find.byKey(const Key('detail_id_text')), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byKey(const Key('detail_id_text'))),
        isA<SelectableText>(),
      );
    });

    testWidgets('copying puts the id on the clipboard', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pump(tester, id: '7675233261169167422');
      await tester.tap(find.byKey(const Key('detail_id_copy')));
      await tester.pump();
      expect(copied, '7675233261169167422');
      expect(find.text('已复制 ID'), findsOneWidget);
    });
  });

  group('DetailPage id row', () {
    Future<void> pumpDetail(
      WidgetTester tester, {
      required MediaItem item,
    }) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            item: item,
            readerStore: MemoryReaderStore(),
            detailLoader: (id, {String tab = '小说'}) async => const {},
            directoryLoader: (id, {String tab = '小说'}) async => [
              [Chapter(itemId: 'c1', title: '第1章', volumeName: '正文')],
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a novel shows its own id', (tester) async {
      await pumpDetail(
        tester,
        item: MediaItem(
          id: '7491705400958405694',
          title: '一本书',
          cover: '',
          author: '',
          badge: '',
          ep: '',
          kind: 'book',
        ),
      );
      expect(find.text('7491705400958405694'), findsOneWidget);
    });

    testWidgets('a short drama shows the series id it loads with', (
      tester,
    ) async {
      // The row must show the same id the page uses for its requests, so that
      // pasting it back into the `id:` search reopens the same series.
      final requested = <String>[];
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            item: MediaItem(
              id: '7489902587913972766',
              seriesId: '7675233261169167422',
              episodeId: '7489902587913972766',
              title: '初次沦陷',
              cover: '',
              author: '',
              badge: '',
              ep: '',
              kind: 'video',
            ),
            readerStore: MemoryReaderStore(),
            detailLoader: (id, {String tab = '小说'}) async {
              requested.add(id);
              return const {};
            },
            directoryLoader: (id, {String tab = '小说'}) async {
              requested.add(id);
              return [
                [Chapter(itemId: 'e1', title: '第1集', volumeName: '剧集')],
              ];
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The series id is what the page requests and what the row shows; the
      // raw item id must not appear.
      expect(requested.toSet(), {'7675233261169167422'});
      expect(find.text('7675233261169167422'), findsOneWidget);
      expect(find.text('7489902587913972766'), findsNothing);
    });
  });
}
