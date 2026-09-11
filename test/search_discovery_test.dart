import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/search_discovery.dart';

/// Recorded from a live `/api/v1/search/suggest?q=修仙` response.
Map<String, dynamic> _suggest() => {
  'code': 0,
  'data': {
    'query_key': '修仙',
    'query_result': ['修仙精品小说', '穿越+系统+修仙', '修仙'],
    'query_result_v2': [
      {
        'name': '修仙精品小说',
        'display_high_light': [
          {'rich_text': '<em>修仙</em>精品小说', 'text': '修仙精品小说'},
        ],
      },
      {
        'name': '修仙',
        'display_high_light': [
          {'rich_text': '<em>修仙</em>', 'text': '修仙'},
        ],
      },
    ],
  },
};

/// Recorded from a live `/api/v1/search/hot` response: two cells, one of which
/// carries the words and one of which is empty.
Map<String, dynamic> _hot() => {
  'code': 0,
  'data': [
    {
      'cell_id_str': '7208531160555585573',
      'cell_name': '',
      'search_tag_data': [
        {'is_hot': false, 'tag_title': '洞房夜，摸到了老婆的狐狸耳朵', 'tag_type': 2},
        {'is_hot': false, 'tag_title': '看过的书', 'tag_type': 2},
      ],
    },
    {'cell_id_str': '2', 'cell_name': '', 'search_tag_data': []},
  ],
};

void main() {
  group('SearchSuggestion', () {
    test('reads every plain suggestion in order', () {
      final suggestions = SearchSuggestion.fromPayload(_suggest());
      expect(suggestions.map((s) => s.text), ['修仙精品小说', '穿越+系统+修仙', '修仙']);
    });

    test('merges the highlighted form by matching text', () {
      final suggestions = SearchSuggestion.fromPayload(_suggest());
      expect(suggestions.first.highlighted, '<em>修仙</em>精品小说');
      // A suggestion with no v2 entry keeps an empty highlight.
      expect(suggestions[1].highlighted, '');
    });

    test('falls back to the v2 form when only it is present', () {
      final suggestions = SearchSuggestion.fromPayload({
        'code': 0,
        'data': {
          'query_result_v2': [
            {
              'name': '只有高亮',
              'display_high_light': [
                {'rich_text': '<em>只有</em>高亮'},
              ],
            },
          ],
        },
      });
      expect(suggestions.single.text, '只有高亮');
      expect(suggestions.single.highlighted, '<em>只有</em>高亮');
    });

    test('deduplicates repeated words', () {
      final suggestions = SearchSuggestion.fromPayload({
        'code': 0,
        'data': {
          'query_result': ['同一', '同一', ''],
        },
      });
      expect(suggestions, hasLength(1));
    });

    test('a business error yields no suggestions', () {
      expect(SearchSuggestion.fromPayload({'code': 100001}), isEmpty);
      expect(SearchSuggestion.fromPayload({'code': 0}), isEmpty);
      expect(SearchSuggestion.fromPayload({'code': 0, 'data': 'x'}), isEmpty);
    });
  });

  group('HotSearch', () {
    test('reads the words nested under search_tag_data', () {
      final hot = HotSearch.fromPayload(_hot());
      expect(hot.words, ['洞房夜，摸到了老婆的狐狸耳朵', '看过的书']);
      expect(hot.isNotEmpty, isTrue);
    });

    test('skips cells that carry no words', () {
      final hot = HotSearch.fromPayload({
        'code': 0,
        'data': [
          {'search_tag_data': []},
          {'cell_name': '没有标签'},
        ],
      });
      expect(hot.isEmpty, isTrue);
    });

    test('deduplicates words across cells', () {
      final hot = HotSearch.fromPayload({
        'code': 0,
        'data': [
          {
            'search_tag_data': [
              {'tag_title': '重复'},
            ],
          },
          {
            'search_tag_data': [
              {'tag_title': '重复'},
              {'tag_title': '新词'},
            ],
          },
        ],
      });
      expect(hot.words, ['重复', '新词']);
    });

    test('a malformed payload yields an empty board', () {
      expect(HotSearch.fromPayload({'code': 0}).isEmpty, isTrue);
      expect(HotSearch.fromPayload({'code': 0, 'data': 'x'}).isEmpty, isTrue);
      expect(HotSearch.fromPayload({'code': 103001}).isEmpty, isTrue);
      expect(HotSearch.empty.isEmpty, isTrue);
    });
  });
}
