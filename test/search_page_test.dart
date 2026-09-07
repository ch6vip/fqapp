import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/search_history_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('an empty tab can request results from the next page', (
    tester,
  ) async {
    final requestedPages = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          initialQuery: '测试',
          historyStore: _DelayedHistory()..initial.complete([]),
          searchLoader: (query, {int page = 1}) async {
            requestedPages.add(page);
            return [
              SearchTab(
                title: '小说',
                items: page == 2 ? [_item('book', '第二页小说')] : [],
              ),
              SearchTab(
                title: '短剧',
                items: page == 1 ? [_item('video', '短剧')] : [],
              ),
            ];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requestedPages, [1]);
    expect(find.text('加载更多'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(requestedPages, contains(2));
    expect(find.text('第二页小说'), findsOneWidget);
  });

  testWidgets('selecting a short result tab resumes automatic pagination', (
    tester,
  ) async {
    final requestedPages = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          initialQuery: '测试',
          historyStore: _DelayedHistory()..initial.complete([]),
          searchLoader: (query, {int page = 1}) async {
            requestedPages.add(page);
            if (page > 2) return [];
            return [
              SearchTab(
                title: '小说',
                items: page == 1
                    ? [for (var i = 0; i < 30; i++) _item('b$i', '小说 $i')]
                    : [],
              ),
              SearchTab(title: '漫画', items: [_item('m$page', '漫画 $page')]),
            ];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requestedPages, [1]);
    await tester.tap(find.widgetWithText(ChoiceChip, '漫画'));
    await tester.pumpAndSettle();
    expect(requestedPages, contains(2));
    expect(find.text('漫画 2'), findsOneWidget);
  });

  testWidgets('history can search again, delete one entry and clear all', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'search_history_v1': ['小王子', '测试小说'],
    });
    final queries = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          searchLoader: (query, {int page = 1}) async {
            queries.add(query);
            return [];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('小王子'));
    await tester.pumpAndSettle();
    expect(queries, ['小王子']);
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除 小王子'));
    await tester.pumpAndSettle();
    expect(find.text('小王子'), findsNothing);
    expect(find.text('测试小说'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '清空').last);
    await tester.pumpAndSettle();
    expect(find.text('暂无搜索历史'), findsOneWidget);
    expect(await SearchHistoryStore.instance.load(), isEmpty);
  });

  testWidgets('late initial history cannot replace a newly searched keyword', (
    tester,
  ) async {
    final history = _DelayedHistory();
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          initialQuery: '新搜索',
          historyStore: history,
          searchLoader: (query, {int page = 1}) async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    history.initial.complete(['旧搜索']);
    await tester.pump();
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.text('新搜索'), findsOneWidget);
    expect(find.text('旧搜索'), findsNothing);
  });

  testWidgets('loads and deduplicates the next search page near the bottom', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final requestedPages = <int>[];
    Future<List<SearchTab>> loader(String query, {int page = 1}) async {
      requestedPages.add(page);
      if (page == 1) {
        return [
          SearchTab(
            title: '综合',
            items: [for (var i = 1; i <= 30; i++) _item('$i', '第$i本')],
          ),
        ];
      }
      if (page == 2) {
        return [
          SearchTab(
            title: '综合',
            items: [_item('30', '重复条目'), _item('31', '第31本')],
          ),
        ];
      }
      return [SearchTab(title: '综合', items: [])];
    }

    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(initialQuery: '萝莉', searchLoader: loader),
      ),
    );
    await tester.pumpAndSettle();
    expect(requestedPages, [1]);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();

    expect(requestedPages, contains(2));
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    final delegate = grid.delegate as SliverChildBuilderDelegate;
    expect(delegate.childCount, 31);
    expect(find.text('第31本'), findsOneWidget);
  });
}

MediaItem _item(String id, String title) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
);

class _DelayedHistory implements SearchHistoryRepository {
  final initial = Completer<List<String>>();
  List<String> items = [];
  @override
  Future<List<String>> load() => initial.future;
  @override
  Future<List<String>> add(String query) async =>
      items = mergeSearchHistory(items, query);
  @override
  Future<List<String>> remove(String query) async =>
      items = items.where((value) => value != query).toList();
  @override
  Future<void> clear() async => items = [];
}
