import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/rank.dart';

/// The catalogue, recorded from a live novel homepage payload. Note the field
/// names: `rank_algo_list` (not `rank_list`), and the list id lives on the card's
/// `cell_id_str`.
Map<String, dynamic> _homepage() => {
  'code': 0,
  'data': {
    'tab_item': [
      {
        'tab_type': 2,
        'cell_data': [
          {
            'cell_id': 7098235271900037000,
            'cell_id_str': '7098235271900037133',
            'cell_name': '排行榜',
            'rank_with_category_data': {
              'rank_algo_list': [
                {'rank_name': '推荐榜', 'rank_algo': 101},
                {'rank_name': '完本榜', 'rank_algo': 100},
                {'rank_name': '巅峰榜', 'rank_algo': 200},
                {'rank_name': '新书榜', 'rank_algo': 108},
                {'rank_name': '漫剧榜', 'rank_algo': 550},
                {'rank_name': '短剧榜', 'rank_algo': 502},
              ],
              'sub_info_list': [
                {'info_id': 0, 'info_name': '全部', 'info_type': 1},
                {'info_id': 37, 'info_name': '穿越', 'info_type': 1},
                {'info_id': 19, 'info_name': '系统', 'info_type': 1},
              ],
            },
          },
        ],
      },
    ],
  },
};

Map<String, dynamic> _entries({bool hasMore = true, int count = 2}) => {
  'code': 0,
  'data': {
    'has_more': hasMore,
    'cell_view': {
      'cell_data': [
        for (var i = 0; i < count; i++)
          {
            'cell_id': 1000 + i,
            'book_data': [
              {
                'book_id': '767938517739033704$i',
                'book_name': '锦衣夜行九万里 $i',
                'author': '安岳的白沐潼',
                'thumb_url': 'https://example.test/$i.jpg',
                'abstract': '锦衣公子神通骨',
                'category': '传统玄幻,热血',
                'creation_status': 1,
                'word_number': 2009374,
                'read_count': 12345,
              },
            ],
          },
      ],
    },
  },
};

void main() {
  group('RankCatalog catalogue', () {
    test('reads the rank list id from the card', () {
      final catalog = RankCatalog.fromHomepagePayload(_homepage());
      // Without this id the entries endpoint returns an empty list.
      expect(catalog.rankId, '7098235271900037133');
    });

    test('reads every rank with its algo', () {
      final catalog = RankCatalog.fromHomepagePayload(_homepage());
      expect(catalog.tabs.map((t) => t.name), [
        '推荐榜',
        '完本榜',
        '巅峰榜',
        '新书榜',
        '漫剧榜',
        '短剧榜',
      ]);
      expect(catalog.tabs.map((t) => t.algo), [101, 100, 200, 108, 550, 502]);
    });

    test('reads the sub-categories', () {
      final catalog = RankCatalog.fromHomepagePayload(_homepage());
      expect(catalog.categories.map((c) => c.name), ['全部', '穿越', '系统']);
      expect(catalog.categories.map((c) => c.id), [0, 37, 19]);
    });

    test('finds the catalogue when it is nested in the page tree', () {
      final payload = {
        'code': 0,
        'data': {
          'tab_item': [
            {
              'tab_type': 2,
              'cell_data': [
                {
                  'cell_data': [
                    {'nested': true},
                  ],
                },
                {
                  'cell_id_str': '42',
                  'rank_with_category_data': {
                    'rank_algo_list': [
                      {'rank_name': '巅峰榜', 'rank_algo': 200},
                    ],
                  },
                },
              ],
            },
          ],
        },
      };
      final catalog = RankCatalog.fromHomepagePayload(payload);
      expect(catalog.rankId, '42');
      expect(catalog.tabs.single.name, '巅峰榜');
    });

    test('a page without a rank card yields the empty catalogue', () {
      expect(
        RankCatalog.fromHomepagePayload({'code': 0, 'data': {}}).isEmpty,
        isTrue,
      );
      expect(RankCatalog.empty.isEmpty, isTrue);
    });

    test('entries without an algo are skipped', () {
      final catalog = RankCatalog.fromHomepagePayload({
        'code': 0,
        'data': {
          'cell_data': [
            {
              'cell_id_str': '42',
              'rank_with_category_data': {
                'rank_algo_list': [
                  {'rank_name': '坏数据'},
                  {'rank_name': '', 'rank_algo': 200},
                  {'rank_name': '巅峰榜', 'rank_algo': 200},
                ],
              },
            },
          ],
        },
      });
      expect(catalog.tabs.single.name, '巅峰榜');
    });
  });

  group('RankCatalog entries', () {
    test('numbers the entries from the requested start', () {
      final page = RankCatalog.parsePage(_entries());
      expect(page.entries.map((e) => e.position), [1, 2]);
      expect(page.hasMore, isTrue);
    });

    test('a later page continues the numbering', () {
      final page = RankCatalog.parsePage(_entries(), startAt: 31);
      expect(page.entries.map((e) => e.position), [31, 32]);
    });

    test('reads the book fields out of the cell wrapper', () {
      final entry = RankCatalog.parsePage(_entries()).entries.first;
      expect(entry.id, '7679385177390337040');
      expect(entry.title, '锦衣夜行九万里 0');
      expect(entry.author, '安岳的白沐潼');
      expect(entry.cover, 'https://example.test/0.jpg');
      // Only the primary category survives.
      expect(entry.category, '传统玄幻');
      expect(entry.statusLabel, '连载中');
      expect(entry.metaLabel, '安岳的白沐潼 · 传统玄幻 · 连载中');
    });

    test("unwraps the board's group cells one level down", () {
      // Live shape of the rank board: cell_view.cell_data holds GROUP cells
      // (月榜 / 男生榜 / …) whose own cell_data carries the work cells. The
      // parser used to read only one level, so every board answered empty
      // (该榜单暂无内容).
      final page = RankCatalog.parsePage({
        'code': 0,
        'data': {
          'has_more': false,
          'cell_view': {
            'cell_data': [
              {
                'cell_name': '月榜',
                'cell_data': [
                  {
                    'book_data': [
                      {
                        'book_id': '7276384138653862966',
                        'book_name': '我不是戏神',
                        'author': '三九音域',
                        'category': '都市,高武',
                        'creation_status': 1,
                        'word_number': 3124695,
                      },
                    ],
                  },
                  {
                    'book_data': [
                      {
                        'book_id': '7109042094553765447',
                        'book_name': '十日终焉',
                        'author': '杀虫队队员',
                        'category': '悬疑,脑洞',
                        'creation_status': 1,
                        'word_number': 2834234,
                      },
                    ],
                  },
                ],
              },
              {'cell_name': '男生榜', 'cell_data': <dynamic>[]},
            ],
          },
        },
      });
      expect(page.entries.map((e) => e.title), ['我不是戏神', '十日终焉']);
      expect(page.entries.map((e) => e.position), [1, 2]);
      expect(page.entries.first.id, '7276384138653862966');
      expect(page.hasMore, isFalse);
    });

    test('accepts an inline book instead of a book_data list', () {
      final page = RankCatalog.parsePage({
        'code': 0,
        'data': {
          'cell_view': {
            'cell_data': [
              {'book_id': '9', 'book_name': '内联作品'},
            ],
          },
        },
      });
      expect(page.entries.single.title, '内联作品');
      expect(page.entries.single.position, 1);
    });

    test('has_more false ends the list', () {
      final page = RankCatalog.parsePage(_entries(hasMore: false, count: 1));
      expect(page.hasMore, isFalse);
      expect(page.entries, hasLength(1));
    });

    test('a business error yields an empty page', () {
      expect(RankCatalog.parsePage({'code': 100103}).isEmpty, isTrue);
    });

    test('a malformed payload yields an empty page', () {
      expect(RankCatalog.parsePage({'code': 0, 'data': {}}).isEmpty, isTrue);
      expect(
        RankCatalog.parsePage({
          'code': 0,
          'data': {'cell_view': 'x'},
        }).isEmpty,
        isTrue,
      );
      expect(RankCatalog.empty.isEmpty, isTrue);
    });

    test('cells without a book are skipped', () {
      final page = RankCatalog.parsePage({
        'code': 0,
        'data': {
          'cell_view': {
            'cell_data': [
              {'cell_id': 1},
              {
                'book_data': [
                  {'book_id': '9', 'book_name': '保留'},
                ],
              },
            ],
          },
        },
      });
      expect(page.entries, hasLength(1));
      // Numbering counts only the entries that exist.
      expect(page.entries.single.position, 1);
    });
  });
}
