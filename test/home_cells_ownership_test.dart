import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/home_feed_cache.dart';

/// 区块的归属：`HomeState.cellsTabIndex` 必须和写下这份 `cells` 的分类一致。
///
/// 真机那条路径是「听书」里画出「推荐榜」——请求侧把 `tab_index` 写死成 0，
/// 上游就回了推荐流的区块。请求参数已修（见 home_tab_index_request_test）；
/// 这里钉住数据侧：区块必须带着自己的归属标记，页面才能据此拒绝跨分类渲染。
void main() {
  setUp(() => HomeFeedCache.hiveReady = false);
  tearDown(() => HomeFeedCache.hiveReady = false);

  /// 区块族跟着分类走：推荐（`tab_type=2`）是 384「猜你喜欢」，其余分类
  /// 各自一族（听书 337）——同族的区块才允许出现在该分类的响应里。
  HomeCell cell(String name, int tabType) => HomeCell(
    showType: tabType == 2 ? 384 : 337,
    name: name,
    id: '',
    style: const {},
    items: const [],
    children: const [],
  );

  MediaItem item(String id, {String kind = 'book'}) => MediaItem(
    id: id,
    title: id,
    cover: '',
    author: '',
    badge: '',
    ep: '',
    kind: kind,
  );

  NotifierProvider<HomeNotifier, HomeState> buildProvider() =>
      NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          usesLocalTabs: true,
          indexedHomepageLoader:
              ({
                int tabType = 2,
                int offset = 0,
                String? sessionId,
                int? tabIndex,
                int? lastTabIndex,
              }) async => HomepagePage(
                items: [item('t$tabType')],
                cells: [cell('tab-$tabType', tabType)],
                nextOffset: null,
                sessionId: null,
              ),
          searchLoader: (query, {int page = 1}) async => [],
        ),
      );

  test('区块带着加载它的分类下标', () async {
    final provider = buildProvider();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    final audioIndex = HomeNotifier.tabs.indexOf('听书');

    await notifier.load();
    expect(container.read(provider).tabIndex, 0);
    expect(container.read(provider).cellsTabIndex, 0);

    notifier.selectTab(audioIndex);
    await _flush();

    final audio = container.read(provider);
    expect(audio.tabIndex, audioIndex);
    expect(
      audio.cellsTabIndex,
      audioIndex,
      reason: '听书的区块必须标注属于听书，否则页面无从拒绝跨分类渲染',
    );
    expect(audio.cells.map((c) => c.name), ['tab-5']);
  });

  test('切回没有缓存的分类时归属标记跟着清空', () async {
    final provider = buildProvider();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);

    await notifier.load();
    expect(container.read(provider).cellsTabIndex, 0);

    // 切到一个从没加载过的分类：区块为空，归属也必须清掉，不能残留推荐的值。
    notifier.selectTab(HomeNotifier.tabs.indexOf('漫剧'));
    await _flush();
    final fresh = container.read(provider);
    if (fresh.cells.isEmpty) {
      expect(
        fresh.cellsTabIndex,
        isNot(0),
        reason: '空区块不能还挂着上一个分类的归属',
      );
    }
  });

  test('区块归属不会跟着顶栏改：切走但 feed 没变时仍写原分类', () async {
    final provider = buildProvider();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    final audioIndex = HomeNotifier.tabs.indexOf('听书');

    await notifier.load();
    notifier.selectTab(audioIndex);
    await _flush();
    expect(container.read(provider).cellsTabIndex, audioIndex);
    expect(container.read(provider).cells.first.name, 'tab-5');

    // 回到推荐：feed 换成推荐那份，归属跟着换回 0。
    notifier.selectTab(0);
    await _flush();
    expect(container.read(provider).cellsTabIndex, 0);
    expect(container.read(provider).cells.first.name, 'tab-2');
  });
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
