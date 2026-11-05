import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/search_discovery.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/search_history_store.dart';

import 'support/search_finders.dart';

/// 搜索页范围与来源的回归测试（Wenku8 移植后的单行分段页签）。
///
/// 覆盖：输入时页签保持可见、书旗与番茄分类互斥并恢复原分类、发现区顺序、
/// 书旗不请求联想词、ID 查询切来源、书旗不提供评分、流尾配色和默认列表。
void main() {
  // 大部分用例检查封面网格；预置「用户选过封面视图」。
  setUp(
    () => SharedPreferences.setMockInitialValues({'search_list_view': false}),
  );

  const id = '7677801492920667198';

  testWidgets('typing keeps the category and source segments visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        suggestLoader: (_) async => const [SearchSuggestion(text: '修仙精品小说')],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '修仙');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('search_suggestions')), findsOneWidget);
    expect(find.byKey(const Key('search-category-tabs')), findsOneWidget);
    expect(searchSegment('综合'), findsOneWidget);
    expect(searchSegment('书旗'), findsOneWidget);
  });

  testWidgets('shuqi replaces the category and a category restores fanqie', (
    tester,
  ) async {
    final requests = <(String, int, int)>[];
    final shuqiCalls = <String>[];
    await tester.pumpWidget(
      _app(
        searchLoader: (query, {required int tabType, required int offset}) {
          requests.add((query, tabType, offset));
          return Future.value([
            SearchTab(
              title: tabType == 3 ? '书籍' : '综合',
              items: [_item('$tabType-$offset', '$query 结果')],
              hasMore: false,
            ),
          ]);
        },
        shuqiLoader: (key) async {
          shuqiCalls.add(key);
          return _shuqiPayload('书旗作品');
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(requests, [('测试', 1, 0)]);

    await tester.tap(searchSegment('小说'));
    await tester.pumpAndSettle();
    expect(requests.last, ('测试', 3, 0));

    final before = requests.length;
    await tester.tap(searchSegment('书旗'));
    await tester.pumpAndSettle();
    expect(shuqiCalls, ['测试']);
    expect(find.text('不提供评分'), findsOneWidget);
    expect(requests, hasLength(before), reason: '书旗不请求番茄分类');

    // 书旗与番茄分类是同一行互斥分段：点「小说」回到番茄并按该分类重新
    // 请求，而不是重置到综合。
    await tester.tap(searchSegment('小说'));
    await tester.pumpAndSettle();
    expect(requests.last, ('测试', 3, 0));
    expect(find.text('不提供评分'), findsNothing);
  });

  testWidgets(
    'discovery shows history before hot and hides hot while typing or in shuqi',
    (tester) async {
      await tester.pumpWidget(
        _app(
          history: _MemoryHistory(['修仙', '夜行司']),
          suggestLoader: (_) async => const <SearchSuggestion>[],
          hotLoader: () async =>
              const HotSearch(entries: [HotSearchEntry(title: '热搜词')]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(searchRecentHeading), findsOneWidget);
      expect(find.text('热搜榜'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(searchRecentHeading)).dy,
        lessThan(tester.getTopLeft(find.text('热搜榜')).dy),
      );

      await tester.enterText(find.byType(TextField), '修');
      await tester.pumpAndSettle();
      expect(find.text('热搜榜'), findsNothing);
      expect(find.text('修仙'), findsOneWidget);
      expect(find.text('夜行司'), findsNothing);

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.text('热搜榜'), findsOneWidget);

      await tester.tap(searchSegment('书旗'));
      await tester.pumpAndSettle();
      expect(find.text('热搜榜'), findsNothing);
      expect(find.text(searchRecentHeading), findsOneWidget);
    },
  );

  testWidgets('shuqi never asks fanqie for suggestions', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      _app(
        history: _MemoryHistory(['修仙']),
        suggestLoader: (query) async {
          calls.add(query);
          return const [SearchSuggestion(text: '修仙建议')];
        },
        shuqiLoader: (_) async => _shuqiPayload('书旗作品'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(searchSegment('书旗'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '修仙');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(calls, isEmpty);
    expect(find.byKey(const Key('search_suggestions')), findsNothing);
    expect(find.byKey(const ValueKey('search_history_修仙')), findsOneWidget);
  });

  testWidgets('an ID lookup leaves no ID hint after switching to shuqi', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        initialQuery: id,
        idLoader: (value) async => _item(value, '精确作品'),
        shuqiLoader: (_) async => _shuqiPayload('书旗作品'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('按作品 ID 查找'), findsOneWidget);
    expect(find.text('精确作品'), findsOneWidget);
    expect(find.text(searchEndOfResults), findsNothing);

    await tester.tap(searchSegment('书旗'));
    await tester.pumpAndSettle();

    expect(find.text('按作品 ID 查找'), findsNothing);
    expect(find.text('书旗作品'), findsOneWidget);
    expect(find.text(searchEndOfResults), findsOneWidget);
  });

  testWidgets('the shuqi heading explains that ratings are unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(shuqiLoader: (_) async => _shuqiPayload('书旗作品')),
    );
    await tester.pumpAndSettle();

    await tester.tap(searchSegment('书旗'));
    await tester.enterText(find.byType(TextField), '关键词');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('不提供评分'), findsOneWidget);
    expect(searchScoreFilter, findsNothing);
  });

  testWidgets('the result footer uses the muted color', (tester) async {
    await tester.pumpWidget(
      _app(
        initialQuery: '测试',
        searchLoader:
            (query, {required int tabType, required int offset}) async {
              return [
                SearchTab(
                  title: '综合',
                  items: [_item('one', '列表作品')],
                  hasMore: false,
                ),
              ];
            },
      ),
    );
    await tester.pumpAndSettle();

    final footer = tester.widget<Text>(find.text(searchEndOfResults));
    final scheme = Theme.of(
      tester.element(find.text(searchEndOfResults)),
    ).colorScheme;
    expect(footer.style?.color, scheme.onSurfaceVariant);
    expect(footer.style?.color, isNot(scheme.onSurface));
  });

  testWidgets('results default to the list layout without a saved preference', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(420, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        initialQuery: '测试',
        searchLoader:
            (query, {required int tabType, required int offset}) async {
              return [
                SearchTab(
                  title: '综合',
                  items: [_item('one', '列表作品')],
                  hasMore: false,
                ),
              ];
            },
      ),
    );
    await tester.pumpAndSettle();

    expect(searchGridTiles, findsNothing);
    expect(find.text('列表作品'), findsOneWidget);
  });
}

Widget _app({
  String? initialQuery,
  SearchPageLoader? searchLoader,
  Future<MediaItem?> Function(String)? idLoader,
  SearchSuggestLoader? suggestLoader,
  HotSearchLoader? hotLoader,
  Future<Map<String, dynamic>> Function(String)? shuqiLoader,
  SearchHistoryRepository? history,
}) => MaterialApp(
  home: SearchPage(
    initialQuery: initialQuery,
    searchLoader: searchLoader ?? _emptySearch,
    idSearchLoader: idLoader,
    suggestLoader: suggestLoader,
    hotSearchLoader: hotLoader,
    shuqiSearchLoader: shuqiLoader,
    historyStore: history ?? _MemoryHistory(),
  ),
);

Future<List<SearchTab>> _emptySearch(
  String query, {
  required int tabType,
  required int offset,
}) async => const [];

Map<String, dynamic> _shuqiPayload(String title) => {
  'source': 'shuqi',
  'data': [
    {
      'bookId': '34078',
      'name': title,
      'author': '忘语',
      'coverUrl': '',
      'intro': '',
      'wordCount': '2451万字',
      'status': '完结',
      'kind': '玄幻',
    },
  ],
};

MediaItem _item(String id, String title) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
);

class _MemoryHistory implements SearchHistoryRepository {
  _MemoryHistory([List<String> seed = const []]) : items = [...seed];

  List<String> items;

  @override
  Future<List<String>> load() async => items;

  @override
  Future<List<String>> add(String query) async =>
      items = mergeSearchHistory(items, query);

  @override
  Future<List<String>> remove(String query) async =>
      items = items.where((value) => value != query).toList();

  @override
  Future<void> clear() async => items = [];
}
