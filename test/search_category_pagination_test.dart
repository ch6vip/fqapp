import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/search_history_store.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';

/// 分类分页与范围条横向滚动。
///
/// 这个用例原来在 search_page_test.dart；方案 A 把范围条右端固定给来源切换后，
/// 420dp 宽的手机上「漫画」需要先横向滚动分类条才会露出来。用例因此挪到单独
/// 文件，分页与游标断言保持不变。
void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'search_list_view': false}),
  );

  testWidgets(
    'a short category loads its own pages and preserves other cursors',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final requests = <(int, int)>[];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          requests.add((tabType, offset));
          if (tabType == 1) {
            return [
              SearchTab(
                title: '综合',
                items: offset == 0
                    ? [for (var i = 0; i < 30; i++) _item('b$i', '小说 $i')]
                    : [_item('b30', '末页小说')],
                hasMore: offset == 0,
                nextOffset: offset == 0 ? 14 : 0,
              ),
              SearchTab(
                title: '漫画',
                items: [_item('old', '综合里的漫画', kind: 'manga')],
                hasMore: false,
              ),
            ];
          }
          return [
            SearchTab(
              title: '漫画',
              items: [_item('m$offset', '漫画 $offset', kind: 'manga')],
              hasMore: offset == 0,
              nextOffset: offset == 0 ? 23 : 0,
            ),
          ];
        }),
      );
      await tester.pumpAndSettle();
      expect(requests, [(1, 0)]);

      // 范围条右端固定给来源切换后，420dp 宽里「漫画」需要横向滚动才露出来。
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, '漫画'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '漫画'));
      await tester.pumpAndSettle();
      expect(requests, [(1, 0), (8, 0), (8, 23)]);
      expect(find.text('漫画 23'), findsOneWidget);
      expect(find.text('综合里的漫画'), findsNothing);

      // 滚回范围条起点，「综合」才会重新进入可见区域并被构建。
      await tester.drag(
        find.byKey(const Key('search-category-tabs')),
        const Offset(300, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '综合'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(3));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(requests.last, (1, 14));
      expect(find.text('末页小说'), findsOneWidget);
      expect(_visibleKinds(tester).toSet(), {'book'});
    },
  );
}

Widget _app(SearchPageLoader loader) => MaterialApp(
  home: SearchPage(
    initialQuery: '测试',
    searchLoader: loader,
    historyStore: _History(),
  ),
);

List<String> _visibleKinds(WidgetTester tester) => tester
    .widgetList<HomeMediaCard>(find.byType(HomeMediaCard))
    .map((card) => card.item.kind)
    .toList();

MediaItem _item(String id, String title, {String kind = 'book'}) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: kind,
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
