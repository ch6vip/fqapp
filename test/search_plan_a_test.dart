import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/search_discovery.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/search_history_store.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';

/// 方案 A（搜索页两层顶栏）的回归测试。
///
/// 这些用例覆盖样稿里没有画成单独状态、但编号说明里点名的行为：范围条与
/// 来源在输入时保持可见、书旗禁用分类页签、发现区顺序、书旗不请求联想词、
/// ID 查询切来源、书旗工具条说明、流尾配色和矮窗口默认版式。
void main() {
  // 大部分用例检查网格 / 卡片；预置「用户选过封面视图」，避免默认测试
  // 窗口（800×600，横屏）触发新加的「横屏默认列表」规则。
  setUp(
    () => SharedPreferences.setMockInitialValues({'search_list_view': false}),
  );

  const id = '7677801492920667198';

  testWidgets('typing keeps the scope bar and source switch visible', (
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
    expect(find.byKey(const Key('search-source-fanqie')), findsOneWidget);
    expect(find.byKey(const Key('search-shuqi-source')), findsOneWidget);
  });

  testWidgets(
    'shuqi disables category tabs and fanqie restores the previous category',
    (tester) async {
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

      await tester.tap(find.widgetWithText(ChoiceChip, '小说'));
      await tester.pumpAndSettle();
      expect(requests.last, ('测试', 3, 0));

      await tester.tap(find.byKey(const Key('search-shuqi-source')));
      await tester.pumpAndSettle();
      expect(shuqiCalls, ['测试']);
      expect(find.text('书旗来源暂不提供评分'), findsOneWidget);

      // 书旗来源下分类页签置灰且不可点：请求数量不变，来源也没有被切回。
      final before = requests.length;
      await tester.tap(
        find.widgetWithText(ChoiceChip, '小说'),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(requests, hasLength(before));
      expect(find.text('书旗来源暂不提供评分'), findsOneWidget);

      // 点「番茄」回到切换前的「小说」，而不是重置到综合。
      await tester.tap(find.byKey(const Key('search-source-fanqie')));
      await tester.pumpAndSettle();
      expect(requests.last, ('测试', 3, 0));
    },
  );

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

      expect(find.text('搜索历史'), findsOneWidget);
      expect(find.text('热搜榜'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('搜索历史')).dy,
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

      await tester.tap(find.byKey(const Key('search-shuqi-source')));
      await tester.pumpAndSettle();
      expect(find.text('热搜榜'), findsNothing);
      expect(find.text('搜索历史'), findsOneWidget);
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

    await tester.tap(find.byKey(const Key('search-shuqi-source')));
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
    expect(find.text('没有更多了'), findsNothing);

    await tester.tap(find.byKey(const Key('search-shuqi-source')));
    await tester.pumpAndSettle();

    expect(find.text('按作品 ID 查找'), findsNothing);
    expect(find.text('书旗作品'), findsOneWidget);
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('the shuqi toolbar explains that ratings are unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(shuqiLoader: (_) async => _shuqiPayload('书旗作品')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('search-shuqi-source')));
    await tester.enterText(find.byType(TextField), '关键词');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('书旗来源暂不提供评分'), findsOneWidget);
    expect(find.byKey(const Key('search-minimum-score')), findsNothing);
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

    final footer = tester.widget<Text>(find.text('没有更多了'));
    expect(footer.style?.color, const HomePalette(false).muted);
    expect(footer.style?.color, isNot(const HomePalette(false).body));
  });

  testWidgets(
    'a short window defaults to the list layout without a saved preference',
    (tester) async {
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

      expect(find.byType(HomeMediaCard), findsNothing);
      expect(find.text('列表作品'), findsOneWidget);
    },
  );
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
