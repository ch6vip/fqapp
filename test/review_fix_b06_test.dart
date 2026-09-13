import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/search_discovery.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/search_history_store.dart';

void main() {
  testWidgets('the clear icon drops the draft and the suggestion panel', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          searchLoader:
              (query, {required int tabType, required int offset}) async =>
                  const <SearchTab>[],
          historyStore: _MemoryHistory(),
          suggestLoader: (_) async => const [SearchSuggestion(text: '修仙精品小说')],
          hotSearchLoader: () async => HotSearch.empty,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '修仙');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search_suggestions')), findsOneWidget);

    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('search_suggestions')), findsNothing);
    expect(find.text('搜索历史'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('deleting all text returns to the history screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          initialQuery: '测试',
          searchLoader:
              (query, {required int tabType, required int offset}) async => [
                SearchTab(
                  title: '综合',
                  items: [_item('old', '旧结果')],
                  hasMore: false,
                ),
              ],
          historyStore: _MemoryHistory(),
          suggestLoader: (_) async => const <SearchSuggestion>[],
          hotSearchLoader: () async => HotSearch.empty,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('旧结果'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    expect(find.text('旧结果'), findsNothing);
    expect(find.text('搜索历史'), findsOneWidget);
  });
}

MediaItem _item(String id, String title, {String kind = 'book'}) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: kind,
);

class _MemoryHistory implements SearchHistoryRepository {
  List<String> items = [];

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
