import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'structured manju metadata keeps exact series and episode identities',
    () {
      for (final metadata in <Map<String, dynamic>>[
        {'genre': 205},
        {'genre': '205'},
        {
          'tag_info': {'text': '漫剧'},
        },
        {
          'cover_tag_info_list': [
            {'text': '漫剧'},
          ],
        },
        {'book_type_name': '动态漫画'},
        {
          'book_data': {'genre': '205'},
        },
      ]) {
        final item = MediaItem.fromRaw({..._video, ...metadata});
        expect(item.kind, 'manju', reason: '$metadata');
        expect(item.id, _seriesId);
        expect(item.seriesId, _seriesId);
        expect(item.episodeId, _episodeId);
        final saved = MediaItem.fromRaw(item.toJson());
        expect(saved.kind, 'manju');
        expect(saved.id, _seriesId);
        expect(saved.episodeId, _episodeId);
      }
    },
  );

  test(
    'mentions of manju do not turn novels, comics or live action into manju',
    () {
      for (final scenario in [
        (metadata: <String, dynamic>{}, kind: 'book'),
        (
          metadata: <String, dynamic>{'genre': 1, 'genre_type': 110},
          kind: 'manga',
        ),
        (metadata: <String, dynamic>{'vid': _episodeId}, kind: 'video'),
        (
          metadata: <String, dynamic>{
            'tag_info': {'text': '漫剧原著'},
          },
          kind: 'book',
        ),
      ]) {
        final item = MediaItem.fromRaw({
          'book_id': _seriesId,
          'title': '漫剧改编原著',
          'abstract': '已改编为动态漫画',
          'author': '漫剧工作室',
          ...scenario.metadata,
        });
        expect(item.kind, scenario.kind);
      }
    },
  );

  test(
    'mixed search separates manju and preserves the upstream video cursor',
    () {
      final cells = [
        {
          'book_id': _seriesId,
          'video_data': [
            {
              ..._video,
              'tag_info': {'text': '漫剧'},
            },
          ],
        },
        {'video_id': 'live-action', 'title': '普通短剧'},
      ];
      final tabs = parseSearchTabs({
        'search_tabs': [
          {'title': '综合', 'data': cells},
          {'title': '短剧', 'data': cells, 'has_more': true, 'next_offset': 17},
          {
            'title': '漫画',
            'data': [
              cells.first,
              {
                'book_id': 'comic',
                'book_name': '漫画作品',
                'genre': 1,
                'genre_type': 110,
              },
            ],
          },
        ],
      });
      expect(tabs.map((tab) => tab.title), ['综合', '短剧', '漫剧', '漫画']);
      final manju = tabs.singleWhere((tab) => tab.title == '漫剧');
      expect(manju.items.map((item) => item.id), [_seriesId]);
      expect(manju.hasMore, isTrue);
      expect(manju.nextOffset, 17);
      expect(tabs[0].items.map((item) => item.kind), ['manju', 'video']);
      expect(tabs[1].items.map((item) => item.id), ['live-action']);
      expect(tabs[3].items.map((item) => item.id), ['comic']);
      final repeated = separateManjuSearchTabs(tabs);
      expect(repeated.map((tab) => tab.title), tabs.map((tab) => tab.title));
      expect(repeated[2].items.map((item) => item.id), [_seriesId]);
      expect(repeated[2].nextOffset, 17);
    },
  );

  test('a filtered-empty video page still exposes the manju search cursor', () {
    final tabs = parseSearchTabs({
      'search_tabs': [
        {
          'title': '短剧',
          'has_more': true,
          'next_offset': '23',
          'data': [
            {'video_id': 'live-action', 'title': '普通短剧'},
          ],
        },
      ],
    });
    final manju = tabs.singleWhere((tab) => tab.title == '漫剧');
    expect(manju.items, isEmpty);
    expect(manju.hasMore, isTrue);
    expect(manju.nextOffset, 23);
  });

  test('homepage 24 uses only its own cards, session and pagination', () async {
    final transport = MockClient(
      (_) async => http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'code': 0,
            'data': {
              'tab_item': [
                {
                  'tab_type': 2,
                  'next_offset': 99,
                  'session_id': 'novel-session',
                  'cell_data': [
                    {
                      'book_data': {'book_id': 'novel', 'book_name': '小说'},
                    },
                  ],
                },
                // Minimized from the verified response: manju cards can be tagged
                // "上新" only. The requested homepage tab supplies their kind.
                {
                  'tab_type': 24,
                  'title': '漫剧',
                  'has_more': false,
                  'bottom_unlimited': true,
                  'cell_data': [
                    {
                      'cell_data': [
                        {
                          'video_data': [_video],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          }),
        ),
        200,
      ),
    );
    addTearDown(transport.close);
    final api = ApiClient(client: transport);
    final page = await api.homepagePage(tabType: 24);
    expect(page.items, hasLength(1));
    expect(page.items.single.kind, 'manju');
    expect(page.items.single.id, _seriesId);
    expect(page.items.single.episodeId, _episodeId);
    expect(page.nextOffset, isNull);
    expect(page.sessionId, isNull);
    final novel = await api.homepagePage(tabType: 2);
    expect(novel.items.single.id, 'novel');
    expect(novel.nextOffset, 99);
    expect(novel.sessionId, 'novel-session');
    expect((await api.homepagePage(tabType: 8)).items, isEmpty);
  });

  test(
    'manju directory keeps string episode IDs for the video content API',
    () {
      final chapters = parseDirectory({
        'code': 0,
        'data': {
          'book_info': {'genre': '205'},
          'item_data_list': [
            {'item_id': _episodeId, 'title': '第1集'},
          ],
        },
      }).expand((volume) => volume).toList();
      expect(chapters.single.itemId, _episodeId);
      expect(chapters.single.title, '第1集');
    },
  );
}

const _seriesId = '7679367796244892696';
const _episodeId = '7679385177390337048';
const _video = <String, dynamic>{
  'series_id': _seriesId,
  'vid': _episodeId,
  'title': '三天后穿越古代，我贷款搬空商城！',
  'episode_cnt': 457,
  'tag_info': {'text': '上新'},
};
