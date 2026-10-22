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
                {'show_type': 384, 'cell_name': '推荐', 'cell_data': [book('a', 'A')]},
              ],
            },
            {
              'cell_data': [
                {'show_type': 385, 'cell_name': '小说', 'cell_data': [book('b', 'B')]},
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
                {'show_type': 384, 'cell_name': '推荐', 'cell_data': [book('a', 'A')]},
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
                  {'show_type': 339, 'cell_data': [book('v1', '剧一')]},
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
}
