import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';

/// 「全部」降级混排页的等价性基线：首次页（推荐流不可用）与翻页共用同一
/// 份「多源搜索 + 交错 + 组装」实现，这组测试在重构前后都必须通过，锁定
/// 结果顺序、跨页去重、分页游标与错误透传。
void main() {
  test('降级首屏按 短剧→漫剧→漫画→听书 交错每个来源', () async {
    final provider = _provider(
      homepageLoader: _failingHomepage('推荐流不可用', '漫剧流不可用'),
      searchLoader: (query, {int page = 1}) async => switch (query) {
        '短剧' => [
          SearchTab(
            title: '短剧',
            items: [
              _item('v1', kind: 'video'),
              _item('v2', kind: 'video'),
            ],
          ),
        ],
        '听书' => [
          SearchTab(
            title: '听书',
            items: [
              _item('a1', kind: 'audio'),
              _item('a2', kind: 'audio'),
            ],
          ),
        ],
        _ => const <SearchTab>[],
      },
      mangaSearchLoader: ({int offset = 0}) async => [
        SearchTab(
          title: '漫画',
          items: [_item('g1', kind: 'manga')],
          hasMore: true,
          nextOffset: 17,
        ),
      ],
      manjuSearchLoader: ({int offset = 0}) async => [
        SearchTab(
          title: '漫剧',
          items: [
            _item('m1', kind: 'manju'),
            _item('m2', kind: 'manju'),
            _item('m3', kind: 'manju'),
          ],
          hasMore: true,
          nextOffset: 17,
        ),
      ],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(provider.notifier).load();

    final state = container.read(provider);
    expect(state.error, isNull);
    // 推荐源失败时不占组；其余来源按 短剧、漫剧、漫画、听书 的顺序逐轮
    // 各取一张，长度不齐的组在末轮自然结束。
    expect(state.items.map((item) => item.id), [
      'v1',
      'm1',
      'g1',
      'a1',
      'v2',
      'm2',
      'a2',
      'm3',
    ]);
    expect(state.hasMore, isTrue);
  });

  test('翻页沿用首屏游标并把第二页交错追加（跨页去重）', () async {
    final videoPages = <int>[];
    final audioPages = <int>[];
    final manjuOffsets = <int>[];
    final mangaOffsets = <int>[];
    final provider = _provider(
      homepageLoader: _failingHomepage('推荐流不可用', '漫剧流不可用'),
      searchLoader: (query, {int page = 1}) async {
        switch (query) {
          case '短剧':
            videoPages.add(page);
            return [
              SearchTab(
                title: '短剧',
                items: page == 1
                    ? [_item('v1', kind: 'video')]
                    // 第二页重复 v1：跨页去重必须只保留第一张。
                    : [_item('v2', kind: 'video'), _item('v1', kind: 'video')],
              ),
            ];
          case '听书':
            audioPages.add(page);
            return [
              SearchTab(
                title: '听书',
                items: [_item(page == 1 ? 'a1' : 'a2', kind: 'audio')],
              ),
            ];
          default:
            return const <SearchTab>[];
        }
      },
      mangaSearchLoader: ({int offset = 0}) async {
        mangaOffsets.add(offset);
        return [
          SearchTab(
            title: '漫画',
            items: [_item(offset == 0 ? 'g1' : 'g2', kind: 'manga')],
            hasMore: offset == 0,
            nextOffset: offset == 0 ? 17 : null,
          ),
        ];
      },
      manjuSearchLoader: ({int offset = 0}) async {
        manjuOffsets.add(offset);
        return [
          SearchTab(
            title: '漫剧',
            items: [_item(offset == 0 ? 'm1' : 'm2', kind: 'manju')],
            hasMore: offset == 0,
            nextOffset: offset == 0 ? 17 : null,
          ),
        ];
      },
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);

    await notifier.load();
    expect(container.read(provider).items.map((item) => item.id), [
      'v1',
      'm1',
      'g1',
      'a1',
    ]);

    await notifier.loadMore();

    // 听书/短剧的搜索页游标来自首屏的 1，翻页要请求第 2 页；漫剧/漫画的
    // 游标来自首屏返回的 next_offset（17）。
    expect(videoPages, [1, 2]);
    expect(audioPages, [1, 2]);
    expect(manjuOffsets, [0, 17]);
    expect(mangaOffsets, [0, 17]);
    expect(container.read(provider).items.map((item) => item.id), [
      'v1',
      'm1',
      'g1',
      'a1',
      'v2',
      'm2',
      'g2',
      'a2',
    ]);
  });

  test('翻页把推荐源放在交错的首位，并用上一页的 offset 续拉', () async {
    final homepageOffsets = <int>[];
    final provider = _provider(
      homepageLoader:
          ({int tabType = 2, int offset = 0, String? sessionId}) async {
            if (tabType != 2) {
              return _emptyPage();
            }
            homepageOffsets.add(offset);
            return offset == 0
                ? HomepagePage(
                    items: [_item('b1')],
                    nextOffset: 5,
                    sessionId: 'session-0',
                  )
                : HomepagePage(
                    items: [_item('b2')],
                    nextOffset: null,
                    sessionId: 'session-5',
                  );
          },
      searchLoader: (query, {int page = 1}) async => switch (query) {
        '短剧' => [
          SearchTab(
            title: '短剧',
            items: [_item('v1', kind: 'video')],
          ),
        ],
        '听书' => [
          SearchTab(
            title: '听书',
            items: [_item('a1', kind: 'audio')],
          ),
        ],
        _ => const <SearchTab>[],
      },
      mangaSearchLoader: ({int offset = 0}) async => [
        SearchTab(
          title: '漫画',
          items: [_item('g1', kind: 'manga')],
        ),
      ],
      manjuSearchLoader: ({int offset = 0}) async => [
        SearchTab(
          title: '漫剧',
          items: [_item('m1', kind: 'manju')],
        ),
      ],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);

    await notifier.load();
    // 推荐流可用时首屏只显示自己的区块，不混排。
    expect(container.read(provider).items.map((item) => item.id), ['b1']);

    await notifier.loadMore();

    expect(homepageOffsets, [0, 5]);
    // 翻页路径始终交错五个来源，推荐源排第一。
    expect(container.read(provider).items.map((item) => item.id), [
      'b1',
      'b2',
      'v1',
      'm1',
      'g1',
      'a1',
    ]);
  });

  test('推荐流返回空页时仍占用首组，且小说搜索页从第 2 页续拉', () async {
    final novelPages = <int>[];
    final provider = _provider(
      homepageLoader:
          ({int tabType = 2, int offset = 0, String? sessionId}) async {
            // 推荐流成功回答，但这一页没有任何卡片/区块。
            if (tabType == 2) return _emptyPage();
            throw StateError('漫剧流不可用');
          },
      searchLoader: (query, {int page = 1}) async {
        if (query == '小说') novelPages.add(page);
        return switch (query) {
          '短剧' => [
            SearchTab(
              title: '短剧',
              items: [_item('v1', kind: 'video')],
            ),
          ],
          '听书' => [
            SearchTab(
              title: '听书',
              items: [_item('a1', kind: 'audio')],
            ),
          ],
          _ => const <SearchTab>[],
        };
      },
      mangaSearchLoader: ({int offset = 0}) async => [
        SearchTab(
          title: '漫画',
          items: [_item('g1', kind: 'manga')],
          hasMore: true,
          nextOffset: 17,
        ),
      ],
      manjuSearchLoader: ({int offset = 0}) async => [
        SearchTab(
          title: '漫剧',
          items: [_item('m1', kind: 'manju')],
          hasMore: true,
          nextOffset: 17,
        ),
      ],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);

    await notifier.load();
    // 空推荐组不改变其他来源的相对顺序。
    expect(container.read(provider).items.map((item) => item.id), [
      'v1',
      'm1',
      'g1',
      'a1',
    ]);
    expect(novelPages, [1]);

    await notifier.loadMore();

    // 首屏的搜索兜底已经消费了小说搜索第 1 页，翻页必须从第 2 页开始。
    expect(novelPages, [1, 2]);
  });

  test('所有来源都失败时首屏报错，而不是交出空页', () async {
    final provider = _provider(
      homepageLoader: _failingHomepage('推荐流不可用', '漫剧流不可用'),
      searchLoader: (query, {int page = 1}) async =>
          throw StateError('$query 搜索失败'),
      mangaSearchLoader: ({int offset = 0}) async => throw StateError('漫画搜索失败'),
      manjuSearchLoader: ({int offset = 0}) async => throw StateError('漫剧搜索失败'),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(provider.notifier).load();

    final state = container.read(provider);
    expect(state.items, isEmpty);
    expect(state.error, isNotNull);
    expect(state.hasMore, isFalse);
  });

  test('单个来源失败不影响其余来源交错', () async {
    final provider = _provider(
      homepageLoader: _failingHomepage('推荐流不可用', '漫剧流不可用'),
      searchLoader: (query, {int page = 1}) async {
        if (query == '短剧') throw StateError('短剧搜索失败');
        return query == '听书'
            ? [
                SearchTab(
                  title: '听书',
                  items: [_item('a1', kind: 'audio')],
                ),
              ]
            : const <SearchTab>[];
      },
      mangaSearchLoader: ({int offset = 0}) async => [
        SearchTab(
          title: '漫画',
          items: [_item('g1', kind: 'manga')],
        ),
      ],
      manjuSearchLoader: ({int offset = 0}) async => [
        SearchTab(
          title: '漫剧',
          items: [_item('m1', kind: 'manju')],
        ),
      ],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(provider.notifier).load();

    final state = container.read(provider);
    expect(state.error, isNull);
    expect(state.items.map((item) => item.id), ['m1', 'g1', 'a1']);
  });

  test('首屏各源都成功但都没结果时接受空页（与翻页的判定不同）', () async {
    final provider = _provider(
      homepageLoader: _failingHomepage('推荐流不可用', '漫剧流不可用'),
      searchLoader: (query, {int page = 1}) async => const <SearchTab>[],
      mangaSearchLoader: ({int offset = 0}) async => const <SearchTab>[],
      manjuSearchLoader: ({int offset = 0}) async => const <SearchTab>[],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(provider.notifier).load();

    final state = container.read(provider);
    expect(state.error, isNull);
    expect(state.items, isEmpty);
    expect(state.hasMore, isFalse);
  });

  test('翻页时推荐源失败且其余来源全空要报错，不能谎报已到底', () async {
    final provider = _provider(
      homepageLoader:
          ({int tabType = 2, int offset = 0, String? sessionId}) async =>
              HomepagePage(
                items: [_item('b1')],
                nextOffset: null,
                sessionId: null,
              ),
      searchLoader: (query, {int page = 1}) async {
        if (query == '小说') throw StateError('小说搜索失败');
        return const <SearchTab>[];
      },
      mangaSearchLoader: ({int offset = 0}) async => const <SearchTab>[],
      manjuSearchLoader: ({int offset = 0}) async => const <SearchTab>[],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);

    await notifier.load();
    expect(container.read(provider).hasMore, isTrue);

    await notifier.loadMore();

    final state = container.read(provider);
    // 已有内容保留，错误交给流尾重试；hasMore 不能停在 true 让页面自动重试。
    expect(state.items.map((item) => item.id), ['b1']);
    expect(state.error, isNotNull);
    expect(state.hasMore, isFalse);
  });
}

NotifierProvider<HomeNotifier, HomeState> _provider({
  required HomepageLoader homepageLoader,
  required SearchTabsLoader searchLoader,
  required CategorySearchLoader mangaSearchLoader,
  required CategorySearchLoader manjuSearchLoader,
}) => NotifierProvider<HomeNotifier, HomeState>(
  () => HomeNotifier(
    homepageLoader: homepageLoader,
    searchLoader: searchLoader,
    mangaSearchLoader: mangaSearchLoader,
    manjuSearchLoader: manjuSearchLoader,
  ),
);

/// 推荐流（tab_type=2）与漫剧流（24）都失败，其余 tab_type 一律返回空页。
HomepageLoader _failingHomepage(
  String recommendationError,
  String manjuError,
) => ({int tabType = 2, int offset = 0, String? sessionId}) async {
  if (tabType == 2) throw StateError(recommendationError);
  if (tabType == 24) throw StateError(manjuError);
  return _emptyPage();
};

HomepagePage _emptyPage() =>
    const HomepagePage(items: [], nextOffset: null, sessionId: null);

MediaItem _item(String id, {String kind = 'book'}) => MediaItem(
  id: id,
  title: id,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: kind,
);
