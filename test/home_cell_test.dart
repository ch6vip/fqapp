import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/home_cell.dart';

/// The bookstore feed ships blocks, and the official client picks a row
/// renderer by `show_type`. fqapp used to flatten everything into one card
/// list, which is why the homepage could only ever be a grid. These cases pin
/// the boundaries the UI now depends on.
void main() {
  Map<String, dynamic> book(String id, String title) => {
    'book_data': {'book_id': id, 'book_name': title, 'thumb_url': ''},
  };

  group('parseHomeCells', () {
    test('keeps top-level blocks in order with their show_type and name', () {
      final payload = {
        'code': 0,
        'data': {
          'tab_index': 0,
          'tab_item': [
            {
              'tab_type': 2,
              'cell_data': [
                {
                  'show_type': 511,
                  'cell_name': '排行榜',
                  'cell_id_str': '7098235271900037133',
                  'cell_data': [
                    {
                      'show_type': 512,
                      'cell_data': [book('b1', '书一')],
                    },
                  ],
                },
                {
                  'show_type': 384,
                  'cell_name': '猜你喜欢',
                  'cell_data': [
                    {
                      'show_type': 385,
                      'cell_data': [book('b2', '书二'), book('b3', '书三')],
                    },
                  ],
                },
              ],
            },
          ],
        },
      };

      final cells = parseHomeCells(payload);
      expect(cells.map((c) => c.name), ['排行榜', '猜你喜欢']);
      expect(cells.map((c) => c.showType), [511, 384]);
      expect(cells.first.id, '7098235271900037133');
      // 511 的卡片在子块里，不在本层。
      expect(cells.first.items, isEmpty);
      expect(cells.first.children, hasLength(1));
      expect(cells.first.flatten().map((i) => i.id), ['b1']);
      // 384 同样要下钻。
      expect(cells.last.flatten().map((i) => i.id), ['b2', 'b3']);
    });

    test('picks the block list of the selected tab', () {
      final payload = {
        'data': {
          'tab_index': 1,
          'tab_item': [
            {
              'cell_data': [
                {
                  'show_type': 384,
                  'cell_name': '推荐',
                  'cell_data': [book('a', 'A')],
                },
              ],
            },
            {
              'cell_data': [
                {
                  'show_type': 385,
                  'cell_name': '小说',
                  'cell_data': [book('b', 'B')],
                },
              ],
            },
          ],
        },
      };
      expect(parseHomeCells(payload).map((c) => c.name), ['小说']);
    });

    test('falls back to the first tab that carries blocks', () {
      final payload = {
        'data': {
          'tab_item': [
            {'tab_type': 25, 'title': '小说'},
            {
              'tab_type': 2,
              'cell_data': [
                {
                  'show_type': 384,
                  'cell_name': '推荐',
                  'cell_data': [book('a', 'A')],
                },
              ],
            },
          ],
        },
      };
      expect(parseHomeCells(payload).map((c) => c.name), ['推荐']);
    });

    test('reads the second-stage video flow one cell_view deeper', () {
      final payload = {
        'data': {
          'cell_view': {
            'cell_data': [
              {
                'show_type': 155,
                'cell_name': '短剧',
                'cell_data': [
                  {
                    'show_type': 339,
                    'cell_data': [book('v1', '剧一')],
                  },
                ],
              },
            ],
          },
        },
      };
      final cells = parseHomeCells(payload);
      expect(cells.single.name, '短剧');
      expect(cells.single.flatten().map((i) => i.id), ['v1']);
    });

    test('accepts a single tab object, which is what the client passes', () {
      // api_client 挑出 tab_type 匹配的那一项后，把「单个 tab 对象」交给解析
      // 器——没有外层 data / tab_item。真机上首页曾经因此拿到 0 个区块，
      // 退回混排，区块标题一个都不出现。
      final tab = {
        'tab_type': 2,
        'title': '推荐',
        'cell_data': [
          {
            'show_type': 511,
            'cell_name': '排行榜',
            'cell_data': [
              {
                'show_type': 512,
                'cell_data': [book('t1', '书一')],
              },
            ],
          },
          {
            'show_type': 384,
            'cell_name': '猜你喜欢',
            'cell_data': [
              {
                'show_type': 385,
                'cell_data': [book('t2', '书二')],
              },
            ],
          },
        ],
      };
      final cells = parseHomeCells(tab);
      expect(cells.map((c) => c.name), ['排行榜', '猜你喜欢']);
      expect(cells.map((c) => c.flatten().length), [1, 1]);
    });

    test('returns nothing for a payload without blocks', () {
      expect(parseHomeCells(const {'code': 0, 'data': {}}), isEmpty);
      // 老后端只有扁平列表时不能让页面变空：调用方退回 items。
      expect(parseHomeCells(const {'code': 0}), isEmpty);
    });

    test('drops blocks that carry neither cards nor children', () {
      final payload = {
        'data': {
          'cell_data': [
            {'show_type': 511, 'cell_name': '空块'},
            {
              'show_type': 384,
              'cell_name': '有内容',
              'cell_data': [book('c1', '书')],
            },
          ],
        },
      };
      expect(parseHomeCells(payload).map((c) => c.name), ['有内容']);
    });

    test('keeps per-block style switches for the renderer', () {
      final payload = {
        'data': {
          'cell_data': [
            {
              'show_type': 511,
              'cell_name': '排行榜',
              'style': {'cover_size': 2, 'hide_title': true},
              'cell_data': [book('s1', '书')],
            },
          ],
        },
      };
      final style = parseHomeCells(payload).single.style;
      expect(style['cover_size'], 2);
      expect(style['hide_title'], isTrue);
    });
  });

  /// The 385 stream carries a 书荒广场 card with no `book_data` — only
  /// `topic_data`. Per the alignment scope the card is skipped entirely: the
  /// parser drops it, and the stream's cards stay books only.
  group('parseHomeCells 书荒广场卡', () {
    Map<String, dynamic> topicCard() => {
      'show_type': 339,
      'cell_name': '书荒广场',
      'dynamic_card_type': 3,
      'cell_url':
          'dragon1967://lynxview?fallbackUrl=dragon1967%3A%2F%2Fwebview',
      'style': {'dynamic_card_move_title_and_entry_to_bottom': true},
      'topic_data': [
        {
          'title': '番茄十大颠峰小说',
          'url': 'dragon1967://webview?url=https%3A%2F%2Fexample.com%2Ft1',
          'topic_data': {'topic_id': '7381334221975339547'},
          'topic_desc': {
            'card_tips': '拯救了30万人的书荒',
            'topic_cover': 'https://example.com/c1.jpeg',
          },
        },
      ],
    };

    test('drops the topic card and keeps the book cards', () {
      final payload = {
        'data': {
          'cell_data': [
            {
              'show_type': 385,
              'cell_data': [book('b1', '书一'), topicCard(), book('b2', '书二')],
            },
          ],
        },
      };

      final grid = parseHomeCells(payload).single;
      // 话题卡没有 book_data 也没有可渲染的卡片，整卡被跳过。
      expect(grid.children.length, 2);
      expect(homeCellEntries(grid).map((i) => i.id), ['b1', 'b2']);
    });

    test('a grid of only books still flattens the same way', () {
      final payload = {
        'data': {
          'cell_data': [
            {
              'show_type': 385,
              'cell_data': [book('b1', '书一'), book('b2', '书二')],
            },
          ],
        },
      };

      final grid = parseHomeCells(payload).single;
      expect(grid.flatten().map((i) => i.id), ['b1', 'b2']);
      expect(homeCellEntries(grid).length, 2);
    });
  });
}
