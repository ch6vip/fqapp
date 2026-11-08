import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/search_discovery.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/book_open_preferences.dart';
import 'package:fqapp/services/search_history_store.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/search/classic_search_content_toolbar.dart';
import 'package:fqapp/widgets/search/classic_search_result_row.dart';
import 'package:fqapp/widgets/search/classic_search_scope_bar.dart';
import 'package:fqapp/widgets/search/search_media_tile.dart';
import 'package:fqapp/widgets/search/search_score_filter.dart';
import 'package:fqapp/widgets/wenku/book_collection_layout.dart';

import 'support/app_ui_host.dart';
import 'support/search_finders.dart';

/// 经典主题的搜索页。
///
/// 这里只验证展示分支与当前业务 State 的连接：关键词/ID、番茄/书旗、分类、
/// 分页/取消、评分、列表/网格、样式来回切换和详情入口。档案主题的原有断言
/// 仍在 search_*_test.dart 里跑，本文件末尾另加一条 archive 回归。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BookOpenPreferences.instance.resetForTest();
  });

  testWidgets('classic search renders the old chrome and list/grid', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AppThemeStyle.classic,
        SearchPage(
          initialQuery: '测试',
          searchLoader: _loader((query, {required tabType, required offset}) {
            return [
              SearchTab(
                title: '综合',
                items: [_item('one', '第一本'), _item('two', '第二本')],
                hasMore: false,
              ),
            ];
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ClassicSearchScopeBar), findsOneWidget);
    expect(find.byKey(const Key('search-input')), findsOneWidget);
    expect(find.byType(ClassicSearchContentToolbar), findsOneWidget);
    expect(find.byType(ClassicSearchResultRow), findsNWidgets(2));
    expect(find.byType(HomeMediaCard), findsNothing);

    await tester.tap(find.byKey(const Key('search-layout-toggle')));
    await tester.pumpAndSettle();

    expect(find.byType(ClassicSearchResultRow), findsNothing);
    expect(find.byType(HomeMediaCard), findsNWidgets(2));
    expect(
      (await SharedPreferences.getInstance()).getBool('search_list_view'),
      isFalse,
    );
  });

  testWidgets('switching style keeps the query, results and request count', (
    tester,
  ) async {
    final store = _store(AppThemeStyle.classic);
    final requests = <String>[];
    await tester.pumpWidget(
      _hostStore(
        store,
        SearchPage(
          initialQuery: '旧词',
          searchLoader: _loader((query, {required tabType, required offset}) {
            requests.add(query);
            return [
              SearchTab(
                title: '综合',
                items: [_item(query, '$query 作品')],
                hasMore: false,
              ),
            ];
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, ['旧词']);

    await tester.enterText(find.byKey(const Key('search-input')), '新词');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(requests, ['旧词', '新词']);
    expect(find.text('新词 作品'), findsOneWidget);
    expect(find.byType(ClassicSearchResultRow), findsOneWidget);

    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();
    expect(find.byType(ClassicSearchScopeBar), findsNothing);
    expect(find.byType(BookCollectionView), findsOneWidget);
    expect(find.text('新词 作品'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '新词',
    );

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(find.byType(ClassicSearchScopeBar), findsOneWidget);
    expect(find.byType(ClassicSearchResultRow), findsOneWidget);
    expect(find.text('新词 作品'), findsOneWidget);
    expect(requests, ['旧词', '新词'], reason: '换样式不重发请求');
  });

  testWidgets('classic categories and the source switch reuse one state', (
    tester,
  ) async {
    final requests = <(String, int, int)>[];
    final shuqiCalls = <String>[];
    await tester.pumpWidget(
      _host(
        AppThemeStyle.classic,
        SearchPage(
          initialQuery: '测试',
          searchLoader: _loader((query, {required tabType, required offset}) {
            requests.add((query, tabType, offset));
            return [
              SearchTab(
                title: tabType == 3 ? '书籍' : '综合',
                items: [_item('$tabType-$offset', '$tabType 分类作品')],
                hasMore: false,
              ),
            ];
          }),
          shuqiSearchLoader: (query) async {
            shuqiCalls.add(query);
            return _shuqiPayload('书旗作品');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, [('测试', 1, 0)]);

    await tester.tap(searchSegment('小说'));
    await tester.pumpAndSettle();
    expect(requests.last, ('测试', 3, 0));
    expect(find.text('3 分类作品'), findsOneWidget);

    await tester.tap(find.byKey(const Key('search-shuqi-source')));
    await tester.pumpAndSettle();
    expect(shuqiCalls, ['测试']);
    expect(find.text('书旗作品'), findsOneWidget);
    expect(find.text('书旗来源暂不提供评分'), findsOneWidget);
    expect(requests, hasLength(2), reason: '书旗不请求番茄分类');

    await tester.tap(find.byKey(const Key('search-source-fanqie')));
    await tester.pumpAndSettle();
    expect(shuqiCalls, ['测试']);
    expect(requests.last, ('测试', 3, 0));
    expect(find.text('3 分类作品'), findsOneWidget);
  });

  testWidgets('classic rating filter only filters loaded results', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AppThemeStyle.classic,
        SearchPage(
          initialQuery: '评分',
          searchLoader: _loader((query, {required tabType, required offset}) {
            return [
              SearchTab(
                title: '综合',
                items: [
                  _item('low', '低分作品', score: 8.2),
                  _item('high', '高分作品', score: 9.3),
                ],
                hasMore: false,
              ),
            ];
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('低分作品'), findsOneWidget);
    expect(find.text('高分作品'), findsOneWidget);

    await _selectClassicScore(tester, '9 分及以上');
    expect(find.text('低分作品'), findsNothing);
    expect(find.text('高分作品'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getDouble('search_minimum_score'),
      9,
    );

    await _selectClassicScore(tester, '评分不限');
    expect(find.text('低分作品'), findsOneWidget);
    expect(find.text('高分作品'), findsOneWidget);
  });

  testWidgets('classic ID lookup keeps the hint and keyword fallback', (
    tester,
  ) async {
    final ids = <String>[];
    final keywords = <String>[];
    await tester.pumpWidget(
      _host(
        AppThemeStyle.classic,
        SearchPage(
          initialQuery: 'ID: 1984',
          idSearchLoader: (id) async {
            ids.add(id);
            return _item(id, 'ID 作品');
          },
          searchLoader: _loader((query, {required tabType, required offset}) {
            keywords.add(query);
            return [
              SearchTab(
                title: '综合',
                items: [_item('other', '关键词作品')],
                hasMore: false,
              ),
            ];
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(ids, ['1984']);
    expect(keywords, isEmpty);
    expect(find.text('按作品 ID 查找'), findsOneWidget);
    expect(find.text('ID 作品'), findsOneWidget);

    await tester.tap(find.text('按关键词搜索'));
    await tester.pumpAndSettle();
    expect(keywords, isNotEmpty);
    expect(find.text('关键词作品'), findsOneWidget);
    expect(find.text('按作品 ID 查找'), findsNothing);
  });

  testWidgets('classic pagination merges pages at the real cursor', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final offsets = <int>[];
    await tester.pumpWidget(
      _host(
        AppThemeStyle.classic,
        SearchPage(
          initialQuery: '分页',
          searchLoader: _loader((query, {required tabType, required offset}) {
            offsets.add(offset);
            return [
              SearchTab(
                title: '综合',
                items: [_item('p$offset', offset == 0 ? '第一页' : '第二页')],
                hasMore: offset == 0,
                nextOffset: offset == 0 ? 14 : 0,
              ),
            ];
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(offsets, [0, 14]);
    expect(find.text('第一页'), findsOneWidget);
    expect(find.text('第二页'), findsOneWidget);
    expect(find.text('没有更多了'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
  });

  testWidgets('a new query ignores a late classic page', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final stale = Completer<List<SearchTab>>();
    final requests = <(String, int)>[];
    await tester.pumpWidget(
      _host(
        AppThemeStyle.classic,
        SearchPage(
          initialQuery: '旧',
          searchLoader:
              (query, {required int tabType, required int offset}) async {
                requests.add((query, offset));
                if (query == '旧' && offset == 0) {
                  return [
                    SearchTab(
                      title: '综合',
                      items: [_item('old', '旧查询作品')],
                      hasMore: true,
                      nextOffset: 14,
                    ),
                  ];
                }
                if (query == '旧') return stale.future;
                return [
                  SearchTab(
                    title: '综合',
                    items: [_item('new', '新词作品')],
                    hasMore: false,
                  ),
                ];
              },
        ),
      ),
    );
    // 第 2 页一直未返回，加载圈会持续动画，不能等 pumpAndSettle。
    for (var i = 0; i < 5 && requests.length < 2; i++) {
      await tester.pump();
    }
    expect(requests, [('旧', 0), ('旧', 14)]);
    await tester.enterText(find.byKey(const Key('search-input')), '新词');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('新词作品'), findsOneWidget);

    stale.complete([
      SearchTab(
        title: '综合',
        items: [_item('stale', '过期作品')],
        hasMore: true,
        nextOffset: 27,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('过期作品'), findsNothing);
    expect(find.text('新词作品'), findsOneWidget);
    expect(find.text('加载失败，点击重试'), findsNothing);
  });

  testWidgets('classic discovery keeps history, hot words and suggestions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'search_history_v1': ['修仙', '夜行司'],
    });
    final queries = <String>[];
    await tester.pumpWidget(
      _host(
        AppThemeStyle.classic,
        SearchPage(
          historyStore: _MemoryHistory(['修仙', '夜行司']),
          suggestLoader: (query) async => const [
            SearchSuggestion(text: '修仙小说'),
          ],
          hotSearchLoader: () async => const HotSearch(
            entries: [
              HotSearchEntry(title: '热搜词', badge: '巅峰榜'),
              HotSearchEntry(title: '第二条热搜'),
            ],
          ),
          searchLoader: _loader((query, {required tabType, required offset}) {
            queries.add(query);
            return [
              SearchTab(
                title: '综合',
                items: [_item(query, '$query 作品')],
                hasMore: false,
              ),
            ];
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.text('热搜榜'), findsOneWidget);
    expect(find.byKey(const ValueKey('search_history_修仙')), findsOneWidget);
    expect(find.byKey(const ValueKey('search_hot_热搜词')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('search-input')), '修');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search_suggestions')), findsOneWidget);
    expect(find.text('热搜榜'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('search_suggestion_修仙小说')));
    await tester.pumpAndSettle();
    expect(queries, ['修仙小说']);
    expect(find.text('修仙小说 作品'), findsOneWidget);

    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsOneWidget);
    await tester.tap(find.byTooltip('删除 夜行司'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search_history_夜行司')), findsNothing);
    expect(find.byKey(const ValueKey('search_history_修仙')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search_hot_热搜词')));
    await tester.pumpAndSettle();
    expect(queries, ['修仙小说', '热搜词']);
    expect(find.text('热搜词 作品'), findsOneWidget);
  });

  testWidgets('classic category results open the shared detail route', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AppThemeStyle.classic,
        SearchPage(
          initialQuery: '测试',
          searchLoader: _loader((query, {required tabType, required offset}) {
            return [
              SearchTab(
                title: tabType == 3 ? '书籍' : '综合',
                items: [_item('book', '进入详情')],
                hasMore: false,
              ),
            ];
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(searchSegment('小说'));
    await tester.pumpAndSettle();
    expect(find.text('进入详情'), findsOneWidget);

    await tester.tap(find.byType(ClassicSearchResultRow).first);
    // openBookDetail 先等偏好加载完再 push，两个 pump 才保证路由已建好。
    await tester.pump();
    await tester.pump();
    expect(find.byType(DetailPage), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('classic hot board results open the shared detail route', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AppThemeStyle.classic,
        SearchPage(
          hotSearchLoader: () async =>
              const HotSearch(entries: [HotSearchEntry(title: '热搜词')]),
          searchLoader: _loader((query, {required tabType, required offset}) {
            return [
              SearchTab(
                title: '综合',
                items: [_item('hot-book', '热搜作品')],
                hasMore: false,
              ),
            ];
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('search_hot_热搜词')));
    await tester.pumpAndSettle();
    expect(find.text('热搜作品'), findsOneWidget);

    await tester.tap(find.byType(ClassicSearchResultRow).first);
    await tester.pump();
    await tester.pump();
    expect(find.byType(DetailPage), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('archive search keeps the existing collection shell', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AppThemeStyle.archive,
        SearchPage(
          initialQuery: '测试',
          searchLoader: _loader((query, {required tabType, required offset}) {
            return [
              SearchTab(
                title: '综合',
                items: [_item('book', '档案作品', score: 9.1)],
                hasMore: false,
              ),
            ];
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(BookCollectionView), findsOneWidget);
    expect(find.byType(SearchNovelRow), findsOneWidget);
    expect(find.byType(SearchScoreFilter), findsOneWidget);
    expect(find.byType(ClassicSearchScopeBar), findsNothing);
    expect(find.byType(ClassicSearchContentToolbar), findsNothing);
    expect(find.text('档案作品'), findsOneWidget);
  });
}

AppThemeStyleStore _store(AppThemeStyle style) =>
    AppThemeStyleStore()..value = style;

Widget _host(AppThemeStyle style, Widget home) =>
    _hostStore(_store(style), home);

Widget _hostStore(AppThemeStyleStore store, Widget home) =>
    AppUiHost(store: store, home: home);

Future<void> _selectClassicScore(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('search-minimum-score')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

SearchPageLoader _loader(
  List<SearchTab> Function(
    String query, {
    required int tabType,
    required int offset,
  })
  body,
) =>
    (query, {required int tabType, required int offset}) async =>
        body(query, tabType: tabType, offset: offset);

MediaItem _item(String id, String title, {double? score}) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
  score: score,
);

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

class _MemoryHistory implements SearchHistoryRepository {
  _MemoryHistory(List<String> initial) : items = [...initial];

  List<String> items;

  @override
  Future<List<String>> load() async => List.unmodifiable(items);

  @override
  Future<List<String>> add(String query) async {
    items = [query, ...items.where((item) => item != query)];
    return List.unmodifiable(items);
  }

  @override
  Future<List<String>> remove(String query) async {
    items = [...items.where((item) => item != query)];
    return List.unmodifiable(items);
  }

  @override
  Future<void> clear() async => items = [];
}
