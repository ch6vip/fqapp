import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/home_feed_cache.dart';

/// 「首页点听书 → 去书架 → 回首页 → 再点听书」之后，听书里显示的是首页
/// 推荐内容。两个成因各钉一组用例：
///
/// * 请求侧：`tab_index` 必须跟着顶栏走。上游拿它决定回哪个分类的
///   `cell_data`，写死 0 就等于任何分类都要推荐流的区块。
/// * 渲染侧：`cells` 不属于当前分类时不渲染，别再画别人的区块。
void main() {
  setUp(() {
    HomeFeedCache.hiveReady = false;
  });

  tearDown(() {
    HomeFeedCache.hiveReady = false;
  });

  group('the homepage request carries the tab strip index', () {
    test('听书 asks upstream for its own index, not 0', () async {
      final requests = <({int tabType, int? tabIndex, int? lastTabIndex})>[];

      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          usesLocalTabs: true,
          indexedHomepageLoader:
              ({
                int tabType = 2,
                int offset = 0,
                String? sessionId,
                int? tabIndex,
                int? lastTabIndex,
              }) async {
                requests.add((
                  tabType: tabType,
                  tabIndex: tabIndex,
                  lastTabIndex: lastTabIndex,
                ));
                return _page(
                  items: [_item('t$tabType', kind: tabType == 5 ? 'audio' : 'book')],
                  cells: [_cell(384, 'tab-$tabType')],
                );
              },
          searchLoader: (query, {int page = 1}) async => [],
        ),
      );

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);

      await notifier.load();
      expect(requests.single.tabType, 2);
      expect(requests.single.tabIndex, 0, reason: '推荐 = 顶栏第 0 项');

      notifier.selectTab(HomeNotifier.tabs.indexOf('听书'));
      await _flush();

      final audio = requests.last;
      expect(audio.tabType, 5);
      expect(audio.tabIndex, HomeNotifier.tabs.indexOf('听书'));
      expect(audio.lastTabIndex, 0, reason: '从推荐切过来的');
    });

    test('回到首页再进听书仍报同一对下标', () async {
      final requests = <({int tabType, int? tabIndex, int? lastTabIndex})>[];

      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          usesLocalTabs: true,
          indexedHomepageLoader:
              ({
                int tabType = 2,
                int offset = 0,
                String? sessionId,
                int? tabIndex,
                int? lastTabIndex,
              }) async {
                requests.add((
                  tabType: tabType,
                  tabIndex: tabIndex,
                  lastTabIndex: lastTabIndex,
                ));
                return _page(
                  items: [_item('t$tabType', kind: tabType == 5 ? 'audio' : 'book')],
                  cells: [_cell(384, 'tab-$tabType')],
                );
              },
          searchLoader: (query, {int page = 1}) async => [],
        ),
      );

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      final audioIndex = HomeNotifier.tabs.indexOf('听书');

      await notifier.load();
      notifier.selectTab(audioIndex);
      await _flush();
      // 去书架再回来：provider 与页面都活着，切回首页只是 selectTab(0)。
      notifier.selectTab(0);
      await _flush();
      notifier.selectTab(audioIndex);
      await _flush();

      final audioRequests = requests.where((r) => r.tabType == 5).toList();
      expect(audioRequests, isNotEmpty);
      expect(
        audioRequests.every((r) => r.tabIndex == audioIndex),
        isTrue,
        reason: '听书的请求必须始终带听书自己的下标',
      );
      expect(
        audioRequests.every((r) => r.tabIndex != 0),
        isTrue,
        reason: '写死 0 就是「听书里显示推荐」的根因',
      );
    });
  });

  group('cells belong to the tab that loaded them', () {
    test('切走再切回拿到的是自己那份区块', () async {
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          usesLocalTabs: true,
          indexedHomepageLoader:
              ({
                int tabType = 2,
                int offset = 0,
                String? sessionId,
                int? tabIndex,
                int? lastTabIndex,
              }) async => _page(
                items: [_item('t$tabType', kind: tabType == 5 ? 'audio' : 'book')],
                cells: [_cell(384, 'tab-$tabType')],
              ),
          searchLoader: (query, {int page = 1}) async => [],
        ),
      );

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      final audioIndex = HomeNotifier.tabs.indexOf('听书');

      await notifier.load();
      expect(_names(container.read(provider)), ['tab-2']);

      notifier.selectTab(audioIndex);
      await _flush();
      expect(container.read(provider).tabIndex, audioIndex);
      expect(_names(container.read(provider)), ['tab-5']);

      notifier.selectTab(0);
      await _flush();
      expect(_names(container.read(provider)), ['tab-2']);

      notifier.selectTab(audioIndex);
      await _flush();
      expect(_names(container.read(provider)), ['tab-5']);
    });
  });
}

List<String> _names(HomeState state) =>
    state.cells.map((cell) => cell.name).toList(growable: false);

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

HomepagePage _page({required List<MediaItem> items, required List<HomeCell> cells}) =>
    HomepagePage(
      items: items,
      cells: cells,
      nextOffset: null,
      sessionId: null,
    );

HomeCell _cell(int showType, String name) => HomeCell(
  showType: showType,
  name: name,
  id: '',
  style: const {},
  items: const [],
  children: const [],
);

MediaItem _item(String id, {String kind = 'book'}) => MediaItem(
  id: id,
  title: id,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: kind,
);
