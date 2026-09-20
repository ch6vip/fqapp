import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/drama_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/shelf_store.dart';

MediaItem _item(String label, {String kind = 'video', String ep = ''}) =>
    MediaItem(
      id: label,
      title: '$label 作品',
      cover: '',
      author: '演员',
      badge: '',
      ep: ep,
      kind: kind,
    );

/// A notifier whose stream answers with `perTab` items per tab_type, so a test
/// can tell which channel a feed is actually reading. The drama tab's override
/// has to open on the 短剧 channel the way the real `dramaProvider` does.
HomeNotifier _notifier({int perTab = 1, int initialTabIndex = 0}) => HomeNotifier(
  initialTabIndex: initialTabIndex,
  homepageLoader: ({int tabType = 2, int offset = 0, String? sessionId}) async {
    return HomepagePage(
      items: [
        for (var index = 0; index < perTab; index++)
          _item('$tabType-$index', ep: index == 0 ? '全12集' : ''),
      ],
      nextOffset: null,
      sessionId: null,
    );
  },
  searchLoader: (query, {int page = 1}) async => const [],
);

/// Both feeds are faked together: the shell mounts the home page next to the
/// 短剧 destination, and the drama page reads only the second provider.
ProviderScope _scope({required Widget child, int perTab = 1}) => ProviderScope(
  overrides: [
    homeProvider.overrideWith(() => _notifier(perTab: perTab)),
    dramaProvider.overrideWith(
      () => _notifier(perTab: perTab, initialTabIndex: dramaTabIndex),
    ),
  ],
  child: child,
);

ProviderContainer _container({int perTab = 1}) => ProviderContainer(
  overrides: [
    homeProvider.overrideWith(() => _notifier(perTab: perTab)),
    dramaProvider.overrideWith(
      () => _notifier(perTab: perTab, initialTabIndex: dramaTabIndex),
    ),
  ],
);

/// The drama feed is a vertical pager; one drag moves it exactly one page.
Future<void> _swipeUp(WidgetTester tester) async {
  await tester.drag(find.byKey(const Key('drama_feed')), const Offset(0, -600));
  await tester.pumpAndSettle();
}

late Directory _hiveDir;

void main() {
  // The follow button writes the local shelf, so the box has to exist before a
  // test taps it. Opening it in setUp keeps that I/O out of the fake-async zone
  // the test bodies run in (see the bookshelf note's testing lesson).
  setUp(() async {
    _hiveDir = await Directory.systemTemp.createTemp('fqapp-drama-test-');
    Hive.init(_hiveDir.path);
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await _hiveDir.delete(recursive: true);
    } catch (_) {
      // Temp dirs live under the system temp folder; a failed cleanup is noise.
    }
  });

  test('the 短剧 tab opens on the 短剧 channel with 推荐/漫剧 behind it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(homeProvider).tabIndex, 0);
    expect(container.read(dramaProvider).tabIndex, dramaTabIndex);
    expect(HomeNotifier.tabs[dramaTabIndex], '短剧');
    expect(dramaChannels.map((channel) => channel.label), ['推荐', '漫剧']);
    expect(dramaChannels.first.tabIndex, dramaTabIndex);
    expect(dramaChannels.first.kind, 'video');
    expect(dramaChannels.last.kind, 'manju');
    expect(HomeNotifier.tabs[dramaChannels.last.tabIndex], '漫剧');
  });

  test('the drama feed keeps its own cursor when the home page switches', () async {
    final container = _container();
    addTearDown(container.dispose);

    await container.read(dramaProvider.notifier).load();
    await container.read(homeProvider.notifier).load();
    final dramaItems = container.read(dramaProvider).items;
    expect(dramaItems, isNotEmpty);
    expect(dramaItems.every((item) => item.kind == 'video'), isTrue);

    container.read(homeProvider.notifier).selectTab(5); // 听书 supersedes it.
    await Future<void>.delayed(Duration.zero);

    expect(container.read(dramaProvider).tabIndex, dramaTabIndex);
    expect(container.read(dramaProvider).items, same(dramaItems));
    expect(container.read(homeProvider).items.first.id, startsWith('5-'));
  });

  testWidgets('the feed shows the official chrome and one full-screen card', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      _scope(perTab: 4, child: const MaterialApp(home: DramaPage())),
    );
    await tester.pumpAndSettle();

    // Top bar: the official search hint and the channel strip.
    expect(find.text('请输入短剧名或主演名'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('漫剧'), findsOneWidget);
    expect(find.byKey(const Key('drama_search_button')), findsOneWidget);
    expect(find.byKey(const Key('drama_refresh_button')), findsOneWidget);

    // One card, filling the page, with the official calls to action.
    expect(find.byKey(const Key('drama_feed')), findsOneWidget);
    expect(find.text('8-0 作品'), findsOneWidget);
    expect(find.text('观看完整短剧'), findsOneWidget);
    expect(find.text('查看剧集'), findsOneWidget);
    expect(find.text('追剧'), findsOneWidget);
    expect(find.text('全12集'), findsOneWidget);
    expect(find.text('上滑继续观看短剧'), findsOneWidget);
    expect(find.text('8-1 作品'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('swiping up reveals the next drama and switching channels swaps the feed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      _scope(perTab: 4, child: const MaterialApp(home: DramaPage())),
    );
    await tester.pumpAndSettle();
    expect(find.text('8-0 作品'), findsOneWidget);

    await _swipeUp(tester);
    expect(find.text('8-0 作品'), findsNothing);
    expect(find.text('8-1 作品'), findsOneWidget);

    // 漫剧 is the second channel: the same notifier, its own cursor.
    await tester.tap(find.text('漫剧'));
    await tester.pumpAndSettle();
    expect(find.text('24-0 作品'), findsOneWidget);
    expect(find.text('8-1 作品'), findsNothing);

    await tester.tap(find.text('推荐'));
    await tester.pumpAndSettle();
    expect(find.text('8-0 作品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed feed shows the official error copy and retries', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    var failing = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dramaProvider.overrideWith(
            () => HomeNotifier(
              initialTabIndex: dramaTabIndex,
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    if (failing) throw ApiException('短剧服务暂时不可用');
                    return const HomepagePage(
                      items: [],
                      nextOffset: null,
                      sessionId: null,
                    );
                  },
              // The stream outage falls back to search, so both must fail for
              // the page to reach its error state.
              searchLoader: (query, {int page = 1}) async {
                if (failing) throw ApiException('短剧服务暂时不可用');
                return const [];
              },
            ),
          ),
        ],
        child: const MaterialApp(home: DramaPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('网络出错，请点击重试'), findsOneWidget);
    expect(find.text('短剧服务暂时不可用'), findsOneWidget);

    failing = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('暂无符合条件的短剧'), findsOneWidget);
    expect(find.text('网络出错，请点击重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a card tap loads the series directory before playing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    final pending = Completer<List<List<Chapter>>>();
    final calls = <String>[];
    await tester.pumpWidget(
      _scope(
        perTab: 1,
        child: MaterialApp(
          home: DramaPage(
            directoryLoader: (id, tab) {
              calls.add('$id:$tab');
              return pending.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('drama_card_video_8-0')));
    await tester.pump();
    expect(calls, ['8-0:短剧']);
    expect(find.text('视频加载中，请稍后'), findsOneWidget);

    pending.completeError(const ApiException('剧集列表暂时无法加载'));
    await tester.pumpAndSettle();
    expect(find.textContaining('剧集列表暂时无法加载'), findsOneWidget);
    expect(find.text('视频加载中，请稍后'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('追剧 落进本地书架并立刻把按钮变成 已追剧', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      _scope(perTab: 1, child: const MaterialApp(home: DramaPage())),
    );
    await tester.pumpAndSettle();
    expect(find.text('追剧'), findsOneWidget);
    expect(find.text('已追剧'), findsNothing);
    expect(ShelfStore.instance.records(), isEmpty);

    // The tap starts a Hive write inside the page, so it has to run in the real
    // async zone for the write (and the store's notification) to complete.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('drama_follow_button')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(ShelfStore.instance.records().map((r) => r.item.id), ['8-0']);
    expect(find.text('已追剧'), findsOneWidget);
    expect(find.text('追剧'), findsNothing);
    expect(find.textContaining('已追剧，可在「书架-短剧」查看'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bottom bar lists 短剧 right after 首页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      _scope(
        child: MaterialApp(home: RootShell(backendStarter: () async {})),
      ),
    );
    await tester.pumpAndSettle();

    // Scoped to the bar: the home page's own category strip also has a 短剧 entry.
    Finder navLabel(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

    final home = tester.getCenter(navLabel('首页')).dx;
    final drama = tester.getCenter(navLabel('短剧')).dx;
    final library = tester.getCenter(navLabel('书架')).dx;
    final mine = tester.getCenter(navLabel('我的')).dx;
    expect(home, lessThan(drama));
    expect(drama, lessThan(library));
    expect(library, lessThan(mine));

    // The destination is lazy: nothing of the 短剧 feed is built before a tap.
    expect(find.byType(DramaPage), findsNothing);
    await tester.tap(navLabel('短剧'));
    await tester.pumpAndSettle();
    expect(find.byType(DramaPage), findsOneWidget);
    expect(find.byKey(const Key('drama_feed')), findsOneWidget);
    expect(find.text('观看完整短剧'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
