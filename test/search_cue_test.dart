import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/search_discovery.dart';

/// 搜索页热搜词接口（`/api/v1/search/cue`）的解析规则。
///
/// 首页原来在搜索胶囊里轮换这些词，2026-11 重做后只留在搜索页；
/// 解析规则不变，测试跟着模型走。
void main() {
  group('SearchCue payload', () {
    test('reads data_v1 words and rotate_interval_ms', () {
      final cue = SearchCue.fromPayload(const {
        'code': 0,
        'rotate_interval_ms': 8000,
        'data_v1': [
          {'display_text': '词一', 'text': 'ignored'},
          {'display_text_v2': '词二优先'},
          {'text': '词三兜底'},
          {'display_text': ''},
          {'display_text': '词一'},
        ],
      });
      expect(cue.words, ['词一', '词二优先', '词三兜底']);
      expect(cue.rotateIntervalMs, 8000);
    });

    test('falls back to the default interval and empty on bad payloads', () {
      expect(SearchCue.empty.isEmpty, isTrue);
      expect(SearchCue.empty.rotateIntervalMs, SearchCue.defaultIntervalMs);
      expect(
        SearchCue.fromPayload(const {'code': 1, 'data_v1': []}).isEmpty,
        isTrue,
      );
      expect(
        SearchCue.fromPayload(const {
          'data_v1': [],
          'rotate_interval_ms': 0,
        }).rotateIntervalMs,
        SearchCue.defaultIntervalMs,
      );
    });
  });
}
