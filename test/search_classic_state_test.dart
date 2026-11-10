import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/search_discovery.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/book_open_preferences.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/search/classic_search_result_row.dart';
import 'package:fqapp/widgets/search/search_media_tile.dart';
import 'package:fqapp/widgets/wenku/wenku_glass.dart';

import 'support/app_ui_host.dart';
import 'support/search_finders.dart';

/// 搜索页在“换展示树”时不能换掉业务状态。
///
/// 这里覆盖审查提出的两类阻塞：结果区的内容锚点（换主题、列表/网格）和
/// 输入焦点/IME 会话；另外把 pending 首屏/追加请求，以及 source、category、
/// 评分、视图在两次主题往返里的保持纳入回归。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BookOpenPreferences.instance.resetForTest();
  });

  group('result content anchor', () {
    testWidgets('classic/archive round trip keeps the work in a loaded page', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _store(AppThemeStyle.classic);
      final offsets = <int>[];
      await tester.pumpWidget(
        _host(
          store,
          SearchPage(
            initialQuery: '分页锚点',
            searchLoader: (query, {required int tabType, required int offset}) {
              offsets.add(offset);
              if (offset == 0) {
                return Future.value([
                  SearchTab(
                    title: '综合',
                    items: [for (var i = 0; i < 40; i++) _item(i)],
                    hasMore: true,
                    nextOffset: 40,
                  ),
                ]);
              }
              return Future.value([
                SearchTab(
                  title: '综合',
                  items: [for (var i = 40; i < 80; i++) _item(i)],
                  hasMore: false,
                ),
              ]);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = _scroll(tester);
      // Load the appended page through the real near-bottom trigger.
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(offsets, [0, 40]);

      scroll.jumpTo(2000);
      await tester.pumpAndSettle();
      final anchor = _topVisibleClassicRow(tester);
      final before = scroll.offset;
      expect(anchor, isNotNull);
      expect(before, greaterThan(1000));

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      expect(offsets, [0, 40], reason: '换主题不重发分页请求');
      expect(find.text(anchor!), findsOneWidget);
      expect(_isOnScreen(tester, anchor), isTrue, reason: '档案布局里锚点作品仍可见');

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(offsets, [0, 40], reason: '换回来也不重发请求');
      expect(find.text(anchor), findsOneWidget);
      expect(_isOnScreen(tester, anchor), isTrue);
      expect(scroll.offset, greaterThan(1000));
      expect(
        (scroll.offset - before).abs(),
        lessThan(120),
        reason: '同一作品回到列表中的合理行内位置',
      );
    });

    testWidgets(
      'archive startup anchor ignores rows hidden behind the header',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(420, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final store = _store(AppThemeStyle.archive);
        var calls = 0;
        await tester.pumpWidget(
          _host(
            store,
            SearchPage(
              initialQuery: '档案锚点',
              searchLoader:
                  (query, {required int tabType, required int offset}) {
                    calls++;
                    return Future.value([
                      SearchTab(
                        title: '综合',
                        items: [for (var i = 0; i < 80; i++) _item(i)],
                        hasMore: false,
                      ),
                    ]);
                  },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scroll = _scroll(tester);

        // 1985 是复审复现点：上一条结果与滚动视口相交，但整条藏在玻璃
        // 页头后面。邻近位置一起回归，避免只修一个魔法偏移。
        for (final point in <double>[1900, 1985, 2050]) {
          if (store.value != AppThemeStyle.archive) {
            await store.select(AppThemeStyle.archive);
            await tester.pumpAndSettle();
          }
          scroll.jumpTo(point);
          await tester.pumpAndSettle();
          final before = _topVisibleArchiveRow(tester);
          expect(before, isNotNull, reason: 'archive offset $point');
          expect(
            before!.distance,
            isNot(0),
            reason: 'archive offset $point 首条行应真的跨过有效可见顶',
          );

          await store.select(AppThemeStyle.classic);
          await tester.pumpAndSettle();
          final after = _topVisibleClassicAnchor(tester);
          expect(calls, 1, reason: 'offset $point 切换不重发请求');
          expect(after?.id, before.id, reason: 'offset $point 保留第一条实际可见作品');
          expect(
            after?.title,
            before.title,
            reason: 'offset $point 保留第一条实际可见作品',
          );
          expect(
            (after!.distance - before.distance).abs(),
            lessThan(1),
            reason: 'offset $point 保留相对有效可见顶的行内偏移',
          );
          expect(find.text(before.title), findsOneWidget);
        }
      },
    );

    testWidgets('list/grid toggle keeps the work and its row position', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _store(AppThemeStyle.classic);
      await tester.pumpWidget(
        _host(
          store,
          SearchPage(
            initialQuery: '视图锚点',
            searchLoader: (query, {required int tabType, required int offset}) {
              return Future.value([
                SearchTab(
                  title: '综合',
                  items: [for (var i = 0; i < 80; i++) _item(i)],
                  hasMore: false,
                ),
              ]);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = _scroll(tester);
      // The toolbar scrolls away with the list; stay close enough to the top
      // that its button is still built, then invoke its handler directly.
      scroll.jumpTo(120);
      await tester.pumpAndSettle();
      final anchor = _topVisibleClassicRow(tester);
      final before = scroll.offset;
      expect(anchor, isNotNull);
      final toggle = tester
          .widget<IconButton>(
            find.byKey(const Key('search-layout-toggle'), skipOffstage: false),
          )
          .onPressed!;

      toggle();
      await tester.pumpAndSettle();
      expect(find.byType(HomeMediaCard), findsWidgets);
      expect(find.text(anchor!), findsOneWidget);
      expect(_isOnScreen(tester, anchor), isTrue);
      expect(scroll.offset, greaterThan(0));

      toggle();
      await tester.pumpAndSettle();
      expect(find.byType(ClassicSearchResultRow), findsWidgets);
      expect(find.text(anchor), findsOneWidget);
      expect(_isOnScreen(tester, anchor), isTrue);
      expect(scroll.offset, greaterThan(80));
      expect((scroll.offset - before).abs(), lessThan(160));
    });
  });

  group('input session', () {
    testWidgets('focused IME composition survives both style switches', (
      tester,
    ) async {
      final store = _store(AppThemeStyle.classic);
      var searches = 0;
      var suggestions = 0;
      await tester.pumpWidget(
        _host(
          store,
          SearchPage(
            initialQuery: '输入',
            searchLoader: (query, {required int tabType, required int offset}) {
              searches++;
              return Future.value([
                SearchTab(title: '综合', items: [_item(1)], hasMore: false),
              ]);
            },
            suggestLoader: (query) async {
              suggestions++;
              return const <SearchSuggestion>[];
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byKey(const Key('search-input')));
      final value = const TextEditingValue(
        text: '拼音ni',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 2, end: 4),
      );
      tester.testTextInput.updateEditingValue(value);
      // Let the suggestion debounce run; it must not restart on style switch.
      await tester.pump(const Duration(milliseconds: 300));

      var editable = tester.state<EditableTextState>(find.byType(EditableText));
      expect(editable.widget.focusNode.hasFocus, isTrue);
      expect(editable.widget.controller.value, value);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      final searchCalls = searches;
      final suggestCalls = suggestions;

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      editable = tester.state<EditableTextState>(find.byType(EditableText));
      expect(editable.widget.focusNode.hasFocus, isTrue);
      expect(editable.widget.controller.value, value);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(searches, searchCalls);
      expect(suggestions, suggestCalls);

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      editable = tester.state<EditableTextState>(find.byType(EditableText));
      expect(editable.widget.focusNode.hasFocus, isTrue);
      expect(editable.widget.controller.value, value);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(searches, searchCalls);
      expect(suggestions, suggestCalls);
    });

    testWidgets('an unfocused field is not refocused by a style switch', (
      tester,
    ) async {
      final store = _store(AppThemeStyle.classic);
      await tester.pumpWidget(
        _host(
          store,
          SearchPage(
            initialQuery: '未聚焦',
            searchLoader: (query, {required int tabType, required int offset}) {
              return Future.value([
                SearchTab(title: '综合', items: [_item(1)], hasMore: false),
              ]);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      var editable = tester.state<EditableTextState>(find.byType(EditableText));
      expect(editable.widget.focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);

      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      editable = tester.state<EditableTextState>(find.byType(EditableText));
      expect(editable.widget.focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      editable = tester.state<EditableTextState>(find.byType(EditableText));
      expect(editable.widget.focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
    });

    testWidgets('a new empty search still focuses once', (tester) async {
      final store = _store(AppThemeStyle.classic);
      await tester.pumpWidget(
        _host(
          store,
          SearchPage(
            searchLoader: (query, {required int tabType, required int offset}) {
              return Future.value([]);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(editable.widget.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
    });
  });

  group('in-flight requests', () {
    testWidgets('a pending first page lands after both switches', (
      tester,
    ) async {
      final store = _store(AppThemeStyle.classic);
      final pending = Completer<List<SearchTab>>();
      var calls = 0;
      await tester.pumpWidget(
        _host(
          store,
          SearchPage(
            initialQuery: '首屏',
            searchLoader: (query, {required int tabType, required int offset}) {
              calls++;
              return pending.future;
            },
          ),
        ),
      );
      await tester.pump();
      await store.select(AppThemeStyle.archive);
      await tester.pump(const Duration(milliseconds: 250));
      await store.select(AppThemeStyle.classic);
      await tester.pump(const Duration(milliseconds: 250));
      expect(calls, 1);

      pending.complete([
        SearchTab(title: '综合', items: [_item(1), _item(2)], hasMore: false),
      ]);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byType(ClassicSearchResultRow), findsNWidgets(2));
      expect(find.text('作品 1'), findsOneWidget);
      expect(find.text('作品 2'), findsOneWidget);
    });

    testWidgets('a pending appended page keeps its cursor across switches', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _store(AppThemeStyle.classic);
      final pending = Completer<List<SearchTab>>();
      final offsets = <int>[];
      await tester.pumpWidget(
        _host(
          store,
          SearchPage(
            initialQuery: '追加',
            searchLoader: (query, {required int tabType, required int offset}) {
              offsets.add(offset);
              if (offset > 0) return pending.future;
              return Future.value([
                SearchTab(
                  title: '综合',
                  items: [_item(0)],
                  hasMore: true,
                  nextOffset: 14,
                ),
              ]);
            },
          ),
        ),
      );
      for (var i = 0; i < 8 && offsets.length < 2; i++) {
        await tester.pump();
      }
      expect(offsets, [0, 14]);

      await store.select(AppThemeStyle.archive);
      await tester.pump(const Duration(milliseconds: 250));
      await store.select(AppThemeStyle.classic);
      await tester.pump(const Duration(milliseconds: 250));
      expect(offsets, [0, 14]);

      pending.complete([
        SearchTab(title: '综合', items: [_item(1)], hasMore: false),
      ]);
      await tester.pumpAndSettle();
      expect(offsets, [0, 14]);
      expect(find.text('作品 0'), findsOneWidget);
      expect(find.text('作品 1'), findsOneWidget);
    });
  });

  testWidgets('category, rating and grid view survive both style switches', (
    tester,
  ) async {
    final store = _store(AppThemeStyle.classic);
    final requests = <(String, int, int)>[];
    await tester.pumpWidget(
      _host(
        store,
        SearchPage(
          initialQuery: '组合状态',
          searchLoader: (query, {required int tabType, required int offset}) {
            requests.add((query, tabType, offset));
            return Future.value([
              SearchTab(
                title: tabType == 3 ? '书籍' : '综合',
                items: tabType == 3
                    ? [
                        _item(1, title: '低分作品', score: 8.2),
                        _item(2, title: '高分作品', score: 9.4),
                      ]
                    : [_item(3, title: '综合作品', score: 9.5)],
                hasMore: false,
              ),
            ]);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(searchSegment('小说'));
    await tester.pumpAndSettle();
    expect(requests.last, ('组合状态', 3, 0));
    await _selectClassicScore(tester, '9 分及以上');
    expect(find.text('低分作品'), findsNothing);
    expect(find.text('高分作品'), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-layout-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(HomeMediaCard), findsWidgets);
    final calls = requests.length;

    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();
    expect(requests.length, calls);
    expect(find.text('高分作品'), findsOneWidget);
    expect(find.text('低分作品'), findsNothing);
    expect(find.text('综合作品'), findsNothing, reason: '仍停在小说分类');
    expect(find.byType(SearchBookGridTile), findsWidgets, reason: '档案仍是网格视图');
    expect(find.text('9 分以上'), findsOneWidget, reason: '档案评分筛选仍是 9 分');

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(requests.length, calls);
    expect(find.text('高分作品'), findsOneWidget);
    expect(find.text('低分作品'), findsNothing);
    expect(find.byType(HomeMediaCard), findsWidgets, reason: '经典仍是网格视图');
    expect(find.text('9 分及以上'), findsOneWidget);
  });

  testWidgets('the shuqi source survives both style switches', (tester) async {
    final store = _store(AppThemeStyle.classic);
    final fanqie = <String>[];
    final shuqi = <String>[];
    await tester.pumpWidget(
      _host(
        store,
        SearchPage(
          initialQuery: '来源',
          searchLoader: (query, {required int tabType, required int offset}) {
            fanqie.add(query);
            return Future.value([
              SearchTab(
                title: '综合',
                items: [_item(1, title: '番茄作品')],
                hasMore: false,
              ),
            ]);
          },
          shuqiSearchLoader: (query) async {
            shuqi.add(query);
            return _shuqiPayload('书旗作品');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('search-shuqi-source')));
    await tester.pumpAndSettle();
    expect(shuqi, ['来源']);
    expect(find.text('书旗作品'), findsOneWidget);
    expect(fanqie, ['来源']);

    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();
    expect(shuqi, ['来源']);
    expect(fanqie, ['来源']);
    expect(find.text('书旗作品'), findsOneWidget);

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(shuqi, ['来源']);
    expect(fanqie, ['来源']);
    expect(find.text('书旗作品'), findsOneWidget);
    expect(find.text('书旗来源暂不提供评分'), findsOneWidget);
  });
}

AppThemeStyleStore _store(AppThemeStyle style) =>
    AppThemeStyleStore()..value = style;

Widget _host(AppThemeStyleStore store, Widget home) =>
    AppUiHost(store: store, home: home);

ScrollController _scroll(WidgetTester tester) => tester
    .widget<CustomScrollView>(find.byType(CustomScrollView).first)
    .controller!;

String? _topVisibleClassicRow(WidgetTester tester) =>
    _topVisibleClassicAnchor(tester)?.title;

typedef _VisibleRow = ({String title, String id, double distance});

({String title, String id, double distance})? _topVisibleClassicAnchor(
  WidgetTester tester,
) {
  final viewport = tester.getRect(find.byType(CustomScrollView).first);
  return _firstVisibleRow(
    tester,
    find.byType(ClassicSearchResultRow),
    viewport.top,
    viewport.bottom,
    (widget) {
      final row = widget as ClassicSearchResultRow;
      return (title: row.item.title, id: row.item.id);
    },
  );
}

/// 档案搜索的有效可见顶是玻璃页头的实际底边，而不是滚动视口顶。
({String title, String id, double distance})? _topVisibleArchiveRow(
  WidgetTester tester,
) {
  final plane = tester.getRect(
    find.byKey(const ValueKey('frosted-navigation-plane')),
  );
  final visibleTop = plane.bottom - FrostedHeader.featherHeight;
  final viewport = tester.getRect(find.byType(CustomScrollView).first);
  return _firstVisibleRow(
    tester,
    find.byType(SearchNovelRow),
    visibleTop,
    viewport.bottom,
    (widget) {
      final row = widget as SearchNovelRow;
      return (title: row.item.title, id: row.item.id);
    },
  );
}

_VisibleRow? _firstVisibleRow(
  WidgetTester tester,
  Finder finder,
  double visibleTop,
  double visibleBottom,
  ({String title, String id}) Function(Widget widget) describe,
) {
  _VisibleRow? best;
  var bestTop = double.infinity;
  for (final element in finder.evaluate()) {
    final object = element.renderObject;
    if (object is! RenderBox || !object.hasSize) continue;
    final top = object.localToGlobal(Offset.zero).dy;
    final bottom = top + object.size.height;
    if (bottom <= visibleTop || top >= visibleBottom) continue;
    if (top < bestTop) {
      bestTop = top;
      final row = describe(element.widget);
      best = (title: row.title, id: row.id, distance: visibleTop - top);
    }
  }
  return best;
}

bool _isOnScreen(WidgetTester tester, String text) {
  final finder = find.text(text);
  if (finder.evaluate().isEmpty) return false;
  final rect = tester.getRect(finder.first);
  final size = tester.binding.renderViews.first.size;
  return rect.bottom > 0 && rect.top < size.height;
}

Future<void> _selectClassicScore(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('search-minimum-score')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

MediaItem _item(int index, {String? title, double? score}) => MediaItem(
  id: '$index',
  title: title ?? '作品 $index',
  cover: '',
  author: '作者$index',
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
