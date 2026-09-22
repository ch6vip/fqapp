import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/widgets/detail/detail_sections.dart';

import 'support/fakes.dart';

/// Mirrors a live `/api/v1/series/{id}` payload: the cast sits under
/// `data.video_data.celebrities`, avatars are HEIC, and the counters are
/// numbers rather than strings (unlike the reading-API detail response).
Map<String, dynamic> _payload({List<Map<String, dynamic>>? cast}) => {
  'code': 0,
  'data': {
    'video_data': {
      'series_id': 7675233261169167000,
      'series_id_str': '7675233261169167422',
      'series_title': '初次沦陷',
      'series_intro': '一场救命恩情错位，灰姑娘林汐替嫁给霍家。',
      'series_cover': 'https://example.test/cover.jpg',
      'episode_cnt': 66,
      'episode_right_text': '全66集',
      'series_play_cnt': 19483737,
      'followed_cnt': 678975,
      'category_schema':
          '[{"category_id":5000,"name":"爱情","schema":"dragon8662://x"}]',
      'celebrities':
          cast ??
          [
            {
              'celebrity_id': '7478642830416549182',
              'nickname': '张楸梓',
              'role_name': '林汐',
              'avatar': 'https://example.test/a.heic',
              'intro': '中国内陆演员',
            },
            {
              'celebrity_id': '2',
              'nickname': '金佳遇',
              'role_name': '霍临川',
              'avatar': 'https://example.test/b.heic',
            },
          ],
    },
  },
};

void main() {
  group('SeriesDetail', () {
    test('reads the cast with roles and avatars', () {
      final series = SeriesDetail.fromPayload(_payload());
      expect(series.cast, hasLength(2));
      expect(series.cast.first.actor, '张楸梓');
      expect(series.cast.first.role, '林汐');
      expect(series.cast.first.avatar, 'https://example.test/a.heic');
      expect(series.cast.first.label, '张楸梓 饰 林汐');
    });

    test('reads the series level metadata', () {
      final series = SeriesDetail.fromPayload(_payload());
      expect(series.title, '初次沦陷');
      expect(series.seriesId, '7675233261169167422');
      expect(series.episodeCount, 66);
      expect(series.episodeLabel, '全66集');
      expect(series.playCount, 19483737);
      expect(series.playLabel, '1948.4万');
      expect(series.categories, ['爱情']);
      expect(series.originalBook, isNull);
    });

    test('reads the original book from video_relate_book', () {
      // 官方播放页原著卡（`BottomRelateBookView`）的数据源：
      // `data.video_relate_book.book_info`，真实值见对照文档 §29。
      final payload = _payload();
      (payload['data'] as Map)['video_relate_book'] = {
        'book_info': {
          'book_id': '7423976172309974040',
          'book_name': '从宿舍逃杀开始斩尽幽诡邪神',
          'book_type': 0,
          'creation_status': '1',
          'thumb_url': 'https://example.test/book.heic',
        },
      };
      final book = SeriesDetail.fromPayload(payload).originalBook;
      expect(book, isNotNull);
      expect(book!.id, '7423976172309974040');
      expect(book.title, '从宿舍逃杀开始斩尽幽诡邪神');
      expect(book.cover, 'https://example.test/book.heic');
      expect(book.status, '1');
    });

    test('original book is null without book_info', () {
      final payload = _payload();
      (payload['data'] as Map)['video_relate_book'] = {
        'ShowTag': 'not-a-book-info',
      };
      expect(SeriesDetail.fromPayload(payload).originalBook, isNull);
    });

    test(
      'falls back to the numeric series id when the string one is absent',
      () {
        final payload = _payload();
        (payload['data'] as Map)['video_data']['series_id_str'] = '';
        expect(
          SeriesDetail.fromPayload(payload).seriesId,
          '7675233261169167000',
        );
      },
    );

    test('drops cast entries without a name or role', () {
      final series = SeriesDetail.fromPayload(
        _payload(
          cast: [
            {'celebrity_id': '1', 'nickname': '', 'role_name': ''},
            {'celebrity_id': '2', 'nickname': '有名字', 'role_name': ''},
          ],
        ),
      );
      expect(series.cast, hasLength(1));
      expect(series.cast.single.actor, '有名字');
      // No role: the label is just the name.
      expect(series.cast.single.label, '有名字');
    });

    test('degrades to empty on business errors and odd payloads', () {
      expect(
        SeriesDetail.fromPayload(const {'code': 100001, 'data': {}}).isEmpty,
        isTrue,
      );
      expect(SeriesDetail.fromPayload(const {}).isEmpty, isTrue);
      expect(
        SeriesDetail.fromPayload(const {'code': 0, 'data': {}}).isEmpty,
        isTrue,
      );
      expect(
        SeriesDetail.fromPayload(const {'code': 0, 'data': 'x'}).isEmpty,
        isTrue,
      );
      expect(
        SeriesDetail.fromPayload(const {'code': 0, 'data': {}}).cast,
        isEmpty,
      );
    });

    test('an initial stands in for a missing avatar', () {
      expect(const CastMember(actor: '张楸梓').initial, '张');
      expect(const CastMember(actor: '').initial, '?');
      expect(const CastMember(actor: 'Alice').initial, 'A');
    });
  });

  group('DetailCastRow', () {
    Future<void> pump(WidgetTester tester, List<CastMember> cast) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DetailCastRow(cast: cast)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('renders the heading, actors and roles', (tester) async {
      await pump(tester, SeriesDetail.fromPayload(_payload()).cast);
      expect(find.text('演员表'), findsOneWidget);
      expect(find.text('2 位'), findsOneWidget);
      expect(find.text('张楸梓'), findsOneWidget);
      expect(find.text('饰 林汐'), findsOneWidget);
      expect(find.text('金佳遇'), findsOneWidget);
      expect(find.text('饰 霍临川'), findsOneWidget);
    });

    testWidgets('collapses to nothing without a cast', (tester) async {
      await pump(tester, const []);
      expect(find.text('演员表'), findsNothing);
      expect(find.byKey(const Key('detail_cast_row')), findsNothing);
    });

    testWidgets('a broken avatar falls back to the initial', (tester) async {
      // The test harness has no network, so a non-empty avatar URL always
      // fails to load; the tile must still show something readable.
      await pump(tester, const [
        CastMember(actor: '张楸梓', role: '林汐', avatar: 'https://x.test/a.heic'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('张'), findsWidgets);
      expect(find.text('张楸梓'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('DetailPage cast wiring', () {
    Future<void> pumpDetail(
      WidgetTester tester, {
      required String kind,
      required Future<SeriesDetail> Function(String) seriesLoader,
    }) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            item: MediaItem(
              id: 'series-1',
              title: '初次沦陷',
              cover: '',
              author: '',
              badge: '',
              ep: '',
              kind: kind,
            ),
            readerStore: MemoryReaderStore(),
            detailLoader: (id, {String tab = '小说'}) async => const {},
            directoryLoader: (id, {String tab = '小说'}) async => [
              [Chapter(itemId: 'e1', title: '第1集', volumeName: '剧集')],
            ],
            seriesLoader: seriesLoader,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a short drama shows its cast', (tester) async {
      final requested = <String>[];
      await pumpDetail(
        tester,
        kind: 'video',
        seriesLoader: (id) async {
          requested.add(id);
          return SeriesDetail.fromPayload(_payload());
        },
      );
      expect(requested, ['series-1']);
      expect(find.text('演员表'), findsOneWidget);
      expect(find.text('张楸梓'), findsOneWidget);
    });

    testWidgets('a novel never asks for a cast', (tester) async {
      final requested = <String>[];
      await pumpDetail(
        tester,
        kind: 'book',
        seriesLoader: (id) async {
          requested.add(id);
          return SeriesDetail.fromPayload(_payload());
        },
      );
      expect(requested, isEmpty);
      expect(find.text('演员表'), findsNothing);
    });

    testWidgets('a failed cast load leaves the page usable', (tester) async {
      await pumpDetail(
        tester,
        kind: 'video',
        seriesLoader: (_) async => throw StateError('offline'),
      );
      expect(find.text('演员表'), findsNothing);
      expect(tester.takeException(), isNull);
      // The page still renders its playable parts.
      expect(find.byKey(const Key('detail_read_button')), findsOneWidget);
    });

    testWidgets('a series without cast hides the section', (tester) async {
      await pumpDetail(
        tester,
        kind: 'video',
        seriesLoader: (_) async => SeriesDetail.empty,
      );
      expect(find.text('演员表'), findsNothing);
    });
  });
}
