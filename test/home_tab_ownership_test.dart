import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/home_feed_cache.dart';

/// 「听书」第二次加载后整页变成推荐/小说分类的排行榜和小说卡片。
///
/// 真实上游（`/reading/bookapi/bookmall/tab/v`）的分类表只给**被回答那一项**
/// 带 `cell_data`，其余项只有标题；听书那一项是 `show_type=337`（本客户端没有
/// 对应渲染器，所以听书第一屏走的是「卡片网格」），而且它给的 `next_offset`
/// 拿来翻页会被上游回 `101116 SERVICE_ERROR`。于是第二次加载（下拉刷新，或从
/// 详情页回来时 `_onScroll` 触发 `loadMore`）实际会走到「拿别的分类的东西当
/// 听书」的几条路径上。这里逐条钉住：
///
/// * 响应声明自己属于别的分类时，整页拒绝（区块和卡片都不认领）；
/// * 追加页同样要认领归属，不能把别的分类的下一页接进来；
/// * 搜索兜底只认点名本分类的桶，混合桶（综合）只喂书籍类；
/// * 解析层不再退到「第一个带 cell_data 的项」。
void main() {
  setUp(() => HomeFeedCache.hiveReady = false);
  tearDown(() => HomeFeedCache.hiveReady = false);

  final audioIndex = HomeNotifier.tabs.indexOf('听书');

  group('a page answered for another tab is refused', () {
    test('听书首页收到推荐的回答时不画它的区块和书', () async {
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          usesLocalTabs: true,
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async {
                if (tabType != 5) {
                  return _page(items: [], cells: []);
                }
                // 上游这次回答的是推荐流：被回答项 `tab_type=2`，但顶层分类表
                // 里「听书」那一项也在（只是空的）。
                return _page(
                  items: [_item('novel-page')],
                  cells: [_cell(511, '排行榜'), _cell(384, '猜你喜欢')],
                  nextOffset: 12,
                  sessionId: 'session',
                  tabs: const [
                    HomeTabItem(type: 2, title: '推荐'),
                    HomeTabItem(type: 5, title: '听书'),
                  ],
                  answeredTabType: 2,
                  tabScoped: true,
                );
              },
          searchLoader: (query, {int page = 1}) async => query == '听书'
              ? [
                  SearchTab(
                    title: '听书',
                    items: [_item('audio-1', kind: 'audio')],
                  ),
                ]
              : const [],
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);

      await notifier.load();
      notifier.selectTab(audioIndex);
      await _flush();

      final state = container.read(provider);
      expect(state.tabIndex, audioIndex);
      expect(state.items.map((item) => item.id), [
        'audio-1',
      ], reason: '别的分类的卡片一张都不能进来，听力页走搜索兜底');
      expect(state.cells, isEmpty, reason: '推荐流的排行榜/猜你喜欢不能画进听书');
    });

    test('分类表在但没有一项是我们的，同样拒绝', () async {
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          usesLocalTabs: true,
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                  tabType == 5
                  ? _page(
                      items: [_item('novel-page')],
                      cells: [_cell(511, '排行榜')],
                      nextOffset: 12,
                      sessionId: null,
                      tabs: const [HomeTabItem(type: 2, title: '推荐')],
                      tabScoped: true,
                    )
                  : _page(items: [], cells: []),
          searchLoader: (query, {int page = 1}) async => const [],
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);

      await notifier.load();
      notifier.selectTab(audioIndex);
      await _flush();

      expect(container.read(provider).items, isEmpty);
      expect(container.read(provider).cells, isEmpty);
    });

    test('追加页回答的是别的分类时也不追加', () async {
      var audioPage = 0;
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          usesLocalTabs: true,
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async {
                if (tabType != 5) return _page(items: [], cells: []);
                audioPage++;
                if (audioPage == 1) {
                  return _page(
                    items: [_item('audio-1', kind: 'audio')],
                    cells: [_cell(337, '听书')],
                    nextOffset: 12,
                    sessionId: 'session',
                    answeredTabType: 5,
                    tabScoped: true,
                  );
                }
                // 第二次加载：上游回了推荐流的下一页。
                return _page(
                  items: [_item('novel-2')],
                  cells: [_cell(384, '猜你喜欢')],
                  nextOffset: 24,
                  sessionId: 'session',
                  tabs: const [HomeTabItem(type: 2, title: '推荐')],
                  answeredTabType: 2,
                  tabScoped: true,
                );
              },
          searchLoader: (query, {int page = 1}) async => const [],
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);

      await notifier.load();
      notifier.selectTab(audioIndex);
      await _flush();
      expect(container.read(provider).items.map((i) => i.id), ['audio-1']);

      await notifier.loadMore();
      final state = container.read(provider);
      expect(state.items.map((i) => i.id), [
        'audio-1',
      ], reason: '别的分类的下一页不能接在听书后面');
      expect(state.cells.map((c) => c.showType), [337]);
    });
  });

  test('没有分类表的响应仍按本分类处理（老后端兼容）', () async {
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        usesLocalTabs: true,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                tabType == 5
                ? _page(
                    items: [_item('audio-legacy', kind: 'audio')],
                    cells: [_cell(337, '听书')],
                  )
                : _page(items: [], cells: []),
        searchLoader: (query, {int page = 1}) async => const [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);

    await notifier.load();
    notifier.selectTab(audioIndex);
    await _flush();

    expect(container.read(provider).items.map((i) => i.id), ['audio-legacy']);
  });

  test('没有分类表、却带着推荐那一族区块的页也拒绝', () async {
    // 靶场里另一条通道：第二次响应干脆不带 `tab_item`（一个裸的推荐页）。
    // 没有分类表就无法证明归属，但区块族会暴露它：511 排行榜 + 384 猜你喜欢
    // 是书籍轴的区块，听书从来只下发 337。
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        usesLocalTabs: true,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                tabType == 5
                ? _page(
                    items: [_item('novel-page')],
                    cells: [_cell(511, '排行榜'), _cell(384, '猜你喜欢')],
                    nextOffset: 12,
                  )
                : _page(items: [], cells: []),
        searchLoader: (query, {int page = 1}) async => query == '听书'
            ? [
                SearchTab(
                  title: '听书',
                  items: [_item('audio-1', kind: 'audio')],
                ),
              ]
            : const [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);

    await notifier.load();
    notifier.selectTab(audioIndex);
    await _flush();

    final state = container.read(provider);
    expect(state.items.map((i) => i.id), ['audio-1']);
    expect(state.cells, isEmpty, reason: '推荐那一族的区块不能画进听书');
  });

  group('the search fallback only borrows its own bucket', () {
    test('听书不会借「综合」桶里的卡片', () async {
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          usesLocalTabs: true,
          // 听书第一屏没有游标 → 翻页只走搜索兜底（真实上游就是这条路径）。
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                  tabType == 5
                  ? _page(
                      items: [_item('audio-1', kind: 'audio')],
                      cells: [_cell(337, '听书')],
                      answeredTabType: 5,
                      tabScoped: true,
                    )
                  : _page(items: [], cells: []),
          // 搜索第 2 页只回「综合」，里面是推荐/小说卡片（这里故意标成 audio，
          // 用来证明拦截靠的是分桶身份，而不是卡片自称的种类）。
          searchLoader: (query, {int page = 1}) async => [
            SearchTab(
              title: '综合',
              items: [_item('novel-in-mixed-bucket', kind: 'audio')],
            ),
          ],
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);

      await notifier.load();
      notifier.selectTab(audioIndex);
      await _flush();
      await notifier.loadMore();

      expect(container.read(provider).items.map((i) => i.id), [
        'audio-1',
      ], reason: '混合桶里的书不能当成听书内容');
    });

    test('混合桶仍然可以喂书籍类（小说兜底不变）', () async {
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          usesLocalTabs: true,
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                  throw StateError('recommendations unavailable'),
          searchLoader: (query, {int page = 1}) async => [
            SearchTab(title: '综合', items: [_item('novel-$page')]),
          ],
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);

      await notifier.load();
      notifier.selectTab(HomeNotifier.tabs.indexOf('小说'));
      await _flush();

      expect(container.read(provider).items.map((i) => i.id), ['novel-1']);
    });
  });

  test('分类表没声明 tab_index 时不再拿别人的区块', () {
    final cells = parseHomeCells({
      'data': {
        'tab_item': [
          {
            'tab_type': 2,
            'title': '推荐',
            'cell_data': [
              {'show_type': 511, 'cell_name': '排行榜'},
            ],
          },
          {'tab_type': 5, 'title': '听书'},
        ],
      },
    });
    expect(cells, isEmpty, reason: '不知道哪一项被回答时，宁可不给区块，也不要拿推荐流的排行榜');
  });
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

HomepagePage _page({
  required List<MediaItem> items,
  required List<HomeCell> cells,
  int? nextOffset,
  String? sessionId,
  List<HomeTabItem> tabs = const [],
  int? answeredTabType,
  bool tabScoped = false,
}) => HomepagePage(
  items: items,
  cells: cells,
  nextOffset: nextOffset,
  sessionId: sessionId,
  tabs: tabs,
  answeredTabType: answeredTabType,
  tabScoped: tabScoped,
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
