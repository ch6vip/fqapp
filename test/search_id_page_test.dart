import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/search_history_store.dart';
import 'package:fqapp/widgets/media_card.dart';

const _id = '7677801492920667198';

void main() {
  testWidgets(
    'ID lookup is shared by categories and can be repeated from history',
    (tester) async {
      final ids = <String>[];
      var keywordCalls = 0;
      await tester.pumpWidget(
        _app(
          idLoader: (id) async {
            ids.add(id);
            return _item(id, '精确漫剧', 'manju');
          },
          keywordLoader:
              (query, {required int tabType, required int offset}) async {
                keywordCalls++;
                return [];
              },
        ),
      );
      await tester.pumpAndSettle();
      expect(ids, [_id]);
      expect(keywordCalls, 0);
      expect(find.text('精确漫剧'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(5));
      expect(find.text('加载更多'), findsNothing);
      expect(find.text('没有更多了'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '短剧'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaCard), findsNothing);
      expect(find.text('该分类下没有匹配的作品'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '漫剧'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<MediaCard>(find.byType(MediaCard)).item.kind,
        'manju',
      );
      expect(ids, [_id]);
      expect(keywordCalls, 0);

      await tester.tap(find.byTooltip('清空'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_id));
      await tester.pumpAndSettle();
      expect(ids, [_id, _id]);
      expect(find.text('精确漫剧'), findsOneWidget);
    },
  );

  testWidgets(
    'explicit ID prefix supports short IDs and bare 1984 stays a title',
    (tester) async {
      final ids = <String>[];
      final keywords = <String>[];
      await tester.pumpWidget(
        _app(
          initialQuery: 'ID: 1984',
          idLoader: (id) async {
            ids.add(id);
            return _item(id, 'ID 对应作品', 'book');
          },
          keywordLoader:
              (query, {required int tabType, required int offset}) async {
                keywords.add(query);
                return [
                  SearchTab(
                    title: '综合',
                    items: [_item('other', '数字书名', 'book')],
                    hasMore: false,
                  ),
                ];
              },
        ),
      );
      await tester.pumpAndSettle();
      expect(ids, ['1984']);
      expect(keywords, isEmpty);
      await tester.enterText(find.byType(TextField), '1984');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(keywords, ['1984']);
      expect(ids, ['1984']);
      expect(find.text('数字书名'), findsOneWidget);
      expect(find.text('按作品 ID 查找'), findsNothing);
    },
  );

  testWidgets(
    'missing IDs show no fabricated result and allow keyword search',
    (tester) async {
      final keywords = <String>[];
      await tester.pumpWidget(
        _app(
          idLoader: (_) async => null,
          keywordLoader:
              (query, {required int tabType, required int offset}) async {
                keywords.add(query);
                return [
                  SearchTab(
                    title: '综合',
                    items: [_item('book', '关键词命中', 'book')],
                    hasMore: false,
                  ),
                ];
              },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('未找到该 ID 对应的作品'), findsOneWidget);
      expect(find.byType(MediaCard), findsNothing);
      expect(keywords, isEmpty);
      await tester.tap(find.text('按关键词搜索'));
      await tester.pumpAndSettle();
      expect(keywords, [_id]);
      expect(find.text('关键词命中'), findsOneWidget);
      expect(find.text('按作品 ID 查找'), findsNothing);
    },
  );

  testWidgets('a failed ID lookup retries once from the selected category', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      _app(
        idLoader: (id) async {
          if (++attempts == 1) throw Exception('网络暂时不可用');
          return _item(id, '重试成功', 'manju');
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('加载失败，点击重试'), findsOneWidget);
    expect(find.text('未找到该 ID 对应的作品'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, '漫剧'));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    await tester.tap(find.text('加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('重试成功'), findsOneWidget);
  });

  testWidgets(
    'switching tabs during lookup sends one request and late ID results are ignored',
    (tester) async {
      final pending = Completer<MediaItem?>();
      var idCalls = 0;
      await tester.pumpWidget(
        _app(
          idLoader: (_) {
            idCalls++;
            return pending.future;
          },
          keywordLoader:
              (query, {required int tabType, required int offset}) async => [
                SearchTab(
                  title: '综合',
                  items: [_item('new', '新关键词结果', 'book')],
                  hasMore: false,
                ),
              ],
        ),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(ChoiceChip, '漫剧'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ChoiceChip, '漫画'));
      await tester.pump();
      expect(idCalls, 1);
      await tester.enterText(find.byType(TextField), '新关键词');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      pending.complete(_item(_id, '过期 ID 结果', 'manju'));
      await tester.pumpAndSettle();
      expect(find.text('新关键词结果'), findsOneWidget);
      expect(find.text('过期 ID 结果'), findsNothing);
    },
  );

  testWidgets('a late keyword response cannot overwrite a new ID lookup', (
    tester,
  ) async {
    final pending = Completer<List<SearchTab>>();
    await tester.pumpWidget(
      _app(
        initialQuery: '旧关键词',
        idLoader: (id) async => _item(id, 'ID 结果', 'manju'),
        keywordLoader: (query, {required int tabType, required int offset}) =>
            pending.future,
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), _id);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    pending.complete([
      SearchTab(title: '综合', items: [_item('old', '旧关键词结果', 'book')]),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('ID 结果'), findsOneWidget);
    expect(find.text('旧关键词结果'), findsNothing);
  });

  testWidgets(
    'clearing and closing the page ignore pending ID results and errors',
    (tester) async {
      final pending = <Completer<MediaItem?>>[];
      await tester.pumpWidget(
        _app(
          idLoader: (_) {
            final request = Completer<MediaItem?>();
            pending.add(request);
            return request.future;
          },
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('清空'));
      await tester.pumpAndSettle();
      pending.first.complete(_item(_id, '过期 ID 结果', 'manju'));
      await tester.pumpAndSettle();
      expect(find.text('搜索历史'), findsOneWidget);
      expect(find.text('过期 ID 结果'), findsNothing);
      await tester.tap(find.text(_id));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.last.completeError(Exception('页面已关闭'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _app({
  String initialQuery = _id,
  required Future<MediaItem?> Function(String) idLoader,
  SearchPageLoader? keywordLoader,
}) => MaterialApp(
  home: SearchPage(
    initialQuery: initialQuery,
    idSearchLoader: idLoader,
    searchLoader:
        keywordLoader ??
        (query, {required int tabType, required int offset}) async => [],
    historyStore: _History(),
  ),
);

MediaItem _item(String id, String title, String kind) => MediaItem(
  id: id,
  title: title,
  kind: kind,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  seriesId: kind == 'manju' ? id : null,
);

class _History implements SearchHistoryRepository {
  List<String> items = [];
  @override
  Future<List<String>> load() async => items;
  @override
  Future<List<String>> add(String query) async =>
      items = mergeSearchHistory(items, query);
  @override
  Future<List<String>> remove(String query) async =>
      items = items.where((item) => item != query).toList();
  @override
  Future<void> clear() async => items = [];
}
