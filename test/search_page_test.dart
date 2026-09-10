import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/search_history_store.dart';
import 'package:fqapp/widgets/media_card.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'fixed categories request their own source and filter copied hits',
    (tester) async {
      final requests = <(String, int, int)>[];
      final mixed = [
        for (final kind in ['book', 'video', 'manju', 'manga', 'audio'])
          _item('shared-id', '$kind 作品', kind: kind),
      ];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          requests.add((query, tabType, offset));
          // Old bridge responses copy all general hits into the other tabs.
          return [
            for (final title in [
              '用户',
              '漫画',
              '全文',
              '综合',
              '社区',
              '短剧',
              '书籍',
              '听书',
              '买书',
            ])
              SearchTab(
                title: title,
                items: mixed,
                hasMore: false,
                nextOffset: 0,
              ),
          ];
        }),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widgetList<ChoiceChip>(find.byType(ChoiceChip))
            .map((chip) => (chip.label as Text).data),
        ['综合', '短剧', '漫剧', '漫画', '听书'],
      );
      expect(_visibleKinds(tester), [
        'book',
        'video',
        'manju',
        'manga',
        'audio',
      ]);
      expect(requests, [('测试', 1, 0)]);

      for (final category in [
        ('短剧', 'video', 11),
        ('漫剧', 'manju', 11),
        ('漫画', 'manga', 8),
        ('听书', 'audio', 2),
      ]) {
        await tester.tap(find.widgetWithText(ChoiceChip, category.$1));
        await tester.pumpAndSettle();
        expect(_visibleKinds(tester), [category.$2]);
        expect(requests.last, ('测试', category.$3, 0));
      }
      expect(requests.map((request) => request.$2), [1, 11, 11, 8, 2]);

      await tester.tap(find.widgetWithText(ChoiceChip, '综合'));
      await tester.pumpAndSettle();
      expect(_visibleKinds(tester), [
        'book',
        'video',
        'manju',
        'manga',
        'audio',
      ]);
      expect(
        requests,
        hasLength(5),
        reason: 'Completed categories keep their cache',
      );
    },
  );

  testWidgets('an empty first page can continue at the actual cursor 14', (
    tester,
  ) async {
    final offsets = <int>[];
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) async {
        offsets.add(offset);
        return [
          SearchTab(
            title: '综合',
            items: offset == 14 ? [_item('book', '后续小说')] : [],
            hasMore: offset == 0,
            nextOffset: offset == 0 ? 14 : 0,
          ),
        ];
      }),
    );
    await tester.pumpAndSettle();
    expect(offsets, [0]);
    expect(find.text('加载更多'), findsOneWidget);
    expect(find.text('没有更多了'), findsNothing);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(offsets, [0, 14]);
    expect(find.text('后续小说'), findsOneWidget);
    expect(find.text('没有更多了'), findsOneWidget);
  });

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
      await tester.tap(find.widgetWithText(ChoiceChip, '漫画'));
      await tester.pumpAndSettle();
      expect(requests, [(1, 0), (8, 0), (8, 23)]);
      expect(find.text('漫画 23'), findsOneWidget);
      expect(find.text('综合里的漫画'), findsNothing);

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

  testWidgets(
    'duplicate pages preserve their advancing cursor without looping',
    (tester) async {
      final offsets = <int>[];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          offsets.add(offset);
          return [
            SearchTab(
              title: '综合',
              items: [
                _item('one', '第一本'),
                if (offset == 27) _item('two', '第二本'),
              ],
              hasMore: offset != 27,
              nextOffset: offset == 0 ? 14 : (offset == 14 ? 27 : 0),
            ),
          ];
        }),
      );
      await tester.pumpAndSettle();
      expect(offsets, [
        0,
        14,
      ], reason: 'No automatic loop through duplicate pages');
      expect(find.text('加载更多'), findsOneWidget);
      expect(find.text('没有更多了'), findsNothing);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(offsets, [0, 14, 27]);
      expect(find.text('第一本'), findsOneWidget);
      expect(find.text('第二本'), findsOneWidget);
      expect(_gridCount(tester), 2);
    },
  );

  testWidgets(
    'filtered-empty manju pages continue independently of short drama',
    (tester) async {
      final requests = <(int, int)>[];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          requests.add((tabType, offset));
          if (tabType == 1) {
            return [SearchTab(title: '综合', items: [], hasMore: false)];
          }
          return [
            SearchTab(
              title: '综合',
              items: [_item('unrelated', '其他栏目的漫剧', kind: 'manju')],
              hasMore: true,
              nextOffset: 99,
            ),
            SearchTab(
              title: '短剧',
              items: [
                if (offset == 0)
                  _item('live', '真人短剧', kind: 'video')
                else
                  _item('animated', '后续漫剧', kind: 'manju'),
              ],
              hasMore: offset == 0,
              nextOffset: offset == 0 ? 17 : 0,
            ),
          ];
        }),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '漫剧'));
      await tester.pumpAndSettle();
      expect(requests, [(1, 0), (11, 0)]);
      expect(find.byType(MediaCard), findsNothing);
      expect(find.text('加载更多'), findsOneWidget);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(requests.last, (11, 17));
      expect(find.text('后续漫剧'), findsOneWidget);
      expect(find.text('其他栏目的漫剧'), findsNothing);

      await tester.tap(find.widgetWithText(ChoiceChip, '短剧'));
      await tester.pumpAndSettle();
      expect(requests, [(1, 0), (11, 0), (11, 17), (11, 0), (11, 17)]);
      expect(find.text('真人短剧'), findsOneWidget);
      expect(find.text('后续漫剧'), findsNothing);
    },
  );

  for (final terminal in <({String label, bool? hasMore, int? next})>[
    (label: 'explicit exhaustion', hasMore: false, next: 28),
    (label: 'unchanged cursor', hasMore: true, next: 14),
    (label: 'backward cursor', hasMore: true, next: 7),
    (label: 'missing cursor', hasMore: true, next: null),
  ]) {
    testWidgets('pagination stops on ${terminal.label}', (tester) async {
      final offsets = <int>[];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          offsets.add(offset);
          return [
            SearchTab(
              title: '综合',
              items: [_item('one', '唯一作品')],
              hasMore: offset == 0 ? true : terminal.hasMore,
              nextOffset: offset == 0 ? 14 : terminal.next,
            ),
          ];
        }),
      );
      await tester.pumpAndSettle();
      expect(offsets, [0, 14]);
      expect(find.text('没有更多了'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
    });
  }

  testWidgets('a valid cursor can advance when has_more is omitted', (
    tester,
  ) async {
    final offsets = <int>[];
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) async {
        offsets.add(offset);
        return [
          SearchTab(
            title: '综合',
            items: offset == 0 ? [] : [_item('one', '后续作品')],
            nextOffset: offset == 0 ? 14 : null,
          ),
        ];
      }),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(offsets, [0, 14]);
    expect(find.text('后续作品'), findsOneWidget);
  });

  testWidgets(
    'initial errors stay in their category and retry at offset zero',
    (tester) async {
      final requests = <(int, int)>[];
      var attempts = 0;
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          requests.add((tabType, offset));
          if (tabType == 1 && attempts++ == 0) throw Exception('首屏失败');
          return [
            SearchTab(
              title: tabType == 1 ? '综合' : '漫画',
              items: [
                _item('success', '成功作品', kind: tabType == 1 ? 'book' : 'manga'),
              ],
              hasMore: false,
            ),
          ];
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('加载失败，点击重试'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '漫画'));
      await tester.pumpAndSettle();
      expect(_visibleKinds(tester), ['manga']);
      expect(find.textContaining('首屏失败'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '综合'));
      await tester.pumpAndSettle();
      expect(requests, [(1, 0), (8, 0)]);
      await tester.tap(find.text('加载失败，点击重试'));
      await tester.pumpAndSettle();
      expect(requests, [(1, 0), (8, 0), (1, 0)]);
      expect(_visibleKinds(tester), ['book']);
    },
  );

  testWidgets('pagination failures retain results and retry the same cursor', (
    tester,
  ) async {
    final offsets = <int>[];
    var failed = false;
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) async {
        offsets.add(offset);
        if (offset == 14 && !failed) {
          failed = true;
          throw Exception('分页失败');
        }
        return [
          SearchTab(
            title: '综合',
            items: [_item('$offset', '作品 $offset')],
            hasMore: offset == 0,
            nextOffset: offset == 0 ? 14 : 0,
          ),
        ];
      }),
    );
    await tester.pumpAndSettle();
    expect(offsets, [0, 14]);
    expect(find.text('作品 0'), findsOneWidget);
    expect(find.text('加载失败，点击重试'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(offsets, [0, 14], reason: 'Scrolling must not retry a failed page');
    await tester.tap(find.text('加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(offsets, [0, 14, 14]);
    expect(find.text('作品 14'), findsOneWidget);
    expect(_gridCount(tester), 2);
  });

  testWidgets(
    'out of order category responses keep results and loading isolated',
    (tester) async {
      final manga = Completer<List<SearchTab>>();
      final audio = Completer<List<SearchTab>>();
      final requests = <int>[];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          requests.add(tabType);
          if (tabType == 8) return manga.future;
          if (tabType == 2) return audio.future;
          return [SearchTab(title: '综合', items: [], hasMore: false)];
        }),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '漫画'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ChoiceChip, '听书'));
      await tester.pump();
      manga.complete([
        SearchTab(
          title: '漫画',
          items: [_item('manga', '漫画结果', kind: 'manga')],
          hasMore: false,
        ),
      ]);
      await tester.pump();
      expect(find.text('漫画结果'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      audio.complete([
        SearchTab(
          title: '听书',
          items: [_item('audio', '听书结果', kind: 'audio')],
          hasMore: false,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('听书结果'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '漫画'));
      await tester.pumpAndSettle();
      expect(find.text('漫画结果'), findsOneWidget);
      expect(requests, [1, 8, 2]);
    },
  );

  for (final failLate in [false, true]) {
    testWidgets(
      'a new query ignores a late page ${failLate ? 'error' : 'result'}',
      (tester) async {
        final oldPage = Completer<List<SearchTab>>();
        final requests = <(String, int, int)>[];
        await tester.pumpWidget(
          _app((query, {required int tabType, required int offset}) async {
            requests.add((query, tabType, offset));
            if (query == '测试' && offset == 14) return oldPage.future;
            return [
              SearchTab(
                title: '综合',
                items: [_item(query, '$query 作品')],
                hasMore: query == '测试',
                nextOffset: query == '测试' ? 14 : 0,
              ),
            ];
          }),
        );
        await tester.pump();
        await tester.pump();
        expect(requests, [('测试', 1, 0), ('测试', 1, 14)]);
        await tester.enterText(find.byType(TextField), '新关键词');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        if (failLate) {
          oldPage.completeError(Exception('过期请求失败'));
        } else {
          oldPage.complete([
            SearchTab(
              title: '综合',
              items: [_item('stale', '过期作品')],
              hasMore: true,
              nextOffset: 27,
            ),
          ]);
        }
        await tester.pumpAndSettle();
        expect(find.text('新关键词 作品'), findsOneWidget);
        expect(find.text('过期作品'), findsNothing);
        expect(find.text('加载失败，点击重试'), findsNothing);
        expect(requests.last, ('新关键词', 1, 0));
        expect(requests, hasLength(3));
      },
    );
  }

  testWidgets('clearing input and disposing ignore pending responses', (
    tester,
  ) async {
    final pending = <Completer<List<SearchTab>>>[];
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) {
        final result = Completer<List<SearchTab>>();
        pending.add(result);
        return result.future;
      }),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    pending.first.complete([
      SearchTab(title: '综合', items: [_item('stale', '过期作品')]),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    await tester.tap(find.text('测试'));
    await tester.pump();
    expect(pending, hasLength(2));
    await tester.pumpWidget(const SizedBox());
    pending.last.completeError(Exception('页面已关闭'));
    await tester.pump();
    expect(tester.takeException(), isNull);
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
          searchLoader:
              (query, {required int tabType, required int offset}) async {
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
          searchLoader:
              (query, {required int tabType, required int offset}) async => [],
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

    final offsets = <int>[];
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) async {
        offsets.add(offset);
        return [
          SearchTab(
            title: '综合',
            items: offset == 0
                ? [for (var i = 1; i <= 30; i++) _item('$i', '第$i本')]
                : [_item('30', '重复条目'), _item('31', '第31本')],
            hasMore: offset == 0,
            nextOffset: offset == 0 ? 14 : 0,
          ),
        ];
      }),
    );
    await tester.pumpAndSettle();
    expect(offsets, [0]);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();

    expect(offsets, [0, 14]);
    expect(_gridCount(tester), 31);
    expect(find.text('第31本'), findsOneWidget);
    expect(find.text('重复条目'), findsNothing);
  });
}

Widget _app(SearchPageLoader loader) => MaterialApp(
  home: SearchPage(
    initialQuery: '测试',
    searchLoader: loader,
    historyStore: _DelayedHistory()..initial.complete([]),
  ),
);

List<String> _visibleKinds(WidgetTester tester) => tester
    .widgetList<MediaCard>(find.byType(MediaCard))
    .map((card) => card.item.kind)
    .toList();

int _gridCount(WidgetTester tester) {
  final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
  return (grid.delegate as SliverChildBuilderDelegate).childCount!;
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
