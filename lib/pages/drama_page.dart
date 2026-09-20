import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/library_store.dart';
import '../services/player_history.dart';
import '../services/shelf_store.dart';
import '../services/user_facing_error.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import 'detail_page.dart';
import 'home_provider.dart';
import 'player_page.dart';
import 'search_page.dart';

/// One channel of the 短剧 tab.
///
/// The official tab hosts several channels behind one strip and names them from
/// the server (`BookMallTabData.tabName`), with 「推荐」 and 「漫剧」 as the client
/// fallbacks. This app has exactly those two feeds, and `HomeNotifier` already
/// caches a cursor per channel, so a channel is just the tab index to read.
class DramaChannel {
  final String label;
  final int tabIndex;
  final String kind;

  const DramaChannel({
    required this.label,
    required this.tabIndex,
    required this.kind,
  });
}

final dramaChannels = <DramaChannel>[
  DramaChannel(label: '推荐', tabIndex: dramaTabIndex, kind: 'video'),
  DramaChannel(
    label: '漫剧',
    tabIndex: HomeNotifier.tabs.indexOf('漫剧'),
    kind: 'manju',
  ),
];

/// The bottom navigation's 短剧 destination, laid out like the official
/// `SeriesMallFragment`: a full-screen vertical feed of dramas with a floating
/// top bar (search row + channel strip) over it.
///
/// It reads [dramaProvider] rather than [homeProvider], so the home page's own
/// category strip can never move this feed. Layout numbers come from
/// `build/reference-analysis`'s sibling analysis of the official client; the
/// overlay typography below the search row is composed from the app's existing
/// full-screen card style because the official feed overlay was not extracted.
///
/// Note: 官方首屏形态与卡片尺寸的出处 — 见
/// .agents/notes/implemented/feature/2026-09-20-official-drama-tab.md
class DramaPage extends ConsumerStatefulWidget {
  const DramaPage({super.key, this.directoryLoader, this.searchPageBuilder});

  /// Test seams: the official feed opens the player straight from a card, which
  /// needs the series directory first.
  final Future<List<List<Chapter>>> Function(String id, String tab)?
  directoryLoader;
  final Widget Function()? searchPageBuilder;

  @override
  ConsumerState<DramaPage> createState() => _DramaPageState();
}

class _DramaPageState extends ConsumerState<DramaPage> {
  static const _searchRowHeight = 44.0;
  static const _stripHeight = 38.0;

  final PageController _pages = PageController();
  int _channel = 0;
  String? _openingId;

  DramaChannel get _current => dramaChannels[_channel];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(dramaProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  List<MediaItem> _visibleItems(HomeState state) => state.items
      .where((item) => item.kind == _current.kind)
      .toList(growable: false);

  void _selectChannel(int index) {
    if (index == _channel) return;
    setState(() => _channel = index);
    ref.read(dramaProvider.notifier).selectTab(dramaChannels[index].tabIndex);
    if (_pages.hasClients) _pages.jumpToPage(0);
  }

  Future<void> _refresh() => ref.read(dramaProvider.notifier).load();

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dramaProvider);
    final items = _visibleItems(state);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _feed(state, items)),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopBar(
              channels: dramaChannels,
              selected: _channel,
              onSelect: _selectChannel,
              onRefresh: _refresh,
              onSearch: _openSearch,
            ),
          ),
        ],
      ),
    );
  }

  Widget _feed(HomeState state, List<MediaItem> items) {
    if (state.error != null) {
      return _FeedMessage(
        key: const Key('drama_error'),
        message: '网络出错，请点击重试',
        detail: state.error!,
        actionLabel: '重试',
        onAction: _refresh,
      );
    }
    if (items.isEmpty) {
      if (state.isLoading || state.hasMore) {
        return const _FeedMessage(message: '正在刷新内容');
      }
      return _FeedMessage(
        key: const Key('drama_empty'),
        message: '暂无符合条件的短剧',
        detail: '换个频道，或稍后再试。',
        actionLabel: '刷新内容',
        onAction: _refresh,
      );
    }

    return PageView.builder(
      key: const Key('drama_feed'),
      controller: _pages,
      scrollDirection: Axis.vertical,
      itemCount: items.length,
      onPageChanged: (index) {
        // Two cards of runway, so a swipe never lands on an empty page.
        if (index >= items.length - 2) ref.read(dramaProvider.notifier).loadMore();
      },
      itemBuilder: (context, index) {
        final item = items[index];
        // The follow state comes from the store, so it is read through the
        // store's own listenable: a 追剧 tap must flip the button immediately,
        // and a removal from the shelf page must flip it back here too.
        return ValueListenableBuilder<int>(
          valueListenable: ShelfStore.instance.listenable,
          builder: (context, _, _) => _DramaFeedCard(
            item: item,
            opening: _openingId == item.id,
            followed: ShelfStore.instance.containsItem(item),
            swipeHint: index < items.length - 1 || state.hasMore,
            onOpen: () => _openPlayer(item),
            onEpisodes: () => _openDetail(item),
            onFollow: () => _toggleFollow(item),
          ),
        );
      },
    );
  }

  /// The official card opens the play page directly
  /// (`VideoInfiniteHolderV3` → `ShortSeriesLaunchArgs`), so the directory is
  /// fetched here and the player is pushed with the resume episode selected.
  Future<void> _openPlayer(MediaItem item) async {
    if (_openingId != null) return;
    setState(() => _openingId = item.id);
    final contentId = item.seriesId ?? item.id;
    final tab = item.kind == 'manju' ? '漫剧' : '短剧';
    try {
      final loader =
          widget.directoryLoader ?? ApiClient.instance.directoryChapters;
      var volumes = await loader(contentId, tab);
      if (volumes.isEmpty && item.episodeId != null) {
        // A search result can be a single episode rather than a whole series.
        volumes = [
          [
            Chapter(
              itemId: item.episodeId!,
              title: item.title,
              volumeName: '剧集',
            ),
          ],
        ];
      }
      final eps = volumes.expand((volume) => volume).toList(growable: false);
      if (eps.isEmpty) throw const ApiException('剧集列表暂时无法加载');
      final saved = await PlayerHistory(LibraryStore.instance).load(contentId);
      final index = (resumeEpisodeIndex(saved, eps) ?? 0).clamp(
        0,
        eps.length - 1,
      );
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            bookId: contentId,
            kind: item.kind,
            title: item.title,
            cover: item.cover,
            eps: eps,
            startIndex: index.toInt(),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingError(error))));
      }
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  void _openDetail(MediaItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailPage(item: item)),
    );
  }

  Future<void> _toggleFollow(MediaItem item) async {
    if (!ShelfStore.instance.isReady) return;
    final followed = await ShelfStore.instance.toggle(item);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(followed ? '已追剧，可在「书架-短剧」查看' : '已取消追剧')),
    );
  }

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => widget.searchPageBuilder?.call() ?? const SearchPage(),
      ),
    );
  }
}

/// The floating top bar: a 44dp search row over a 38dp channel strip, both on a
/// light scrim so the official black-on-white text stays readable over video.
class _TopBar extends StatelessWidget {
  final List<DramaChannel> channels;
  final int selected;
  final ValueChanged<int> onSelect;
  final Future<void> Function() onRefresh;
  final VoidCallback onSearch;

  const _TopBar({
    required this.channels,
    required this.selected,
    required this.onSelect,
    required this.onRefresh,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.94),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0, 1],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: _DramaPageState._searchRowHeight,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _searchField(context),
                ),
              ),
            ),
            SizedBox(
              height: _DramaPageState._stripHeight,
              child: Row(
                children: [
                  Expanded(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: channels.length,
                      itemBuilder: (context, index) => _ChannelTab(
                        label: channels[index].label,
                        selected: index == selected,
                        onTap: () => onSelect(index),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('drama_refresh_button'),
                    tooltip: '刷新内容',
                    onPressed: onRefresh,
                    iconSize: 20,
                    color: Colors.black87,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                    icon: const Icon(LucideIcons.refresh_ccw),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchField(BuildContext context) => Semantics(
    button: true,
    label: '搜索短剧',
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        key: const Key('drama_search_button'),
        onTap: onSearch,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              const Icon(LucideIcons.search, size: 18, color: Color(0x66000000)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '请输入短剧名或主演名',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0x66000000),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// One tab of the channel strip: 18sp label with a 3dp indicator under it.
class _ChannelTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChannelTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 18,
                    height: 1.1,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color: selected
                        ? const Color(0xFF000000)
                        : const Color(0x1A000000),
                  ),
                ),
                const SizedBox(height: 3),
                Container(
                  width: 20,
                  height: 3,
                  decoration: BoxDecoration(
                    color: selected ? const Color(0xFF000000) : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One full-screen card of the feed.
class _DramaFeedCard extends StatelessWidget {
  final MediaItem item;
  final bool opening;
  final bool followed;
  final bool swipeHint;
  final VoidCallback onOpen;
  final VoidCallback onEpisodes;
  final VoidCallback onFollow;

  const _DramaFeedCard({
    required this.item,
    required this.opening,
    required this.followed,
    required this.swipeHint,
    required this.onOpen,
    required this.onEpisodes,
    required this.onFollow,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        StoryCover(
          item: item,
          cacheWidth: (size.width * pixelRatio).ceil(),
          alignment: Alignment.topCenter,
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, 0.45, 1],
              colors: [Color(0x14000000), Color(0x33000000), Color(0xE6000000)],
            ),
          ),
        ),
        Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('drama_card_${item.kind}_${item.id}'),
            onTap: onOpen,
            child: const SizedBox.expand(),
          ),
        ),
        if (swipeHint && !opening)
          const Positioned(
            left: 0,
            right: 0,
            bottom: 168,
            child: Text(
              '上滑继续观看短剧',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 28,
          child: _info(context),
        ),
        if (opening)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x8C000000),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 14),
                    Text(
                      '视频加载中，请稍后',
                      style: TextStyle(fontSize: 13, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _info(BuildContext context) {
    final meta = [
      if (item.author.isNotEmpty) item.author,
      if (item.tag?.text case final String tag when tag.isNotEmpty) tag,
      homeKindLabel(item.kind),
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  height: 1.2,
                  fontWeight: FontWeight.w800,
                  shadows: [Shadow(color: Colors.black45, blurRadius: 12)],
                ),
              ),
            ),
            if (item.ep.isNotEmpty) ...[
              const SizedBox(width: 10),
              _UpdateTag(text: item.ep),
            ],
          ],
        ),
        const SizedBox(height: 7),
        Text(
          meta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            _Pill(
              key: const Key('drama_open_button'),
              label: '观看完整短剧',
              icon: LucideIcons.play,
              onTap: onOpen,
            ),
            const SizedBox(width: 10),
            _Pill(
              key: const Key('drama_episodes_button'),
              label: '查看剧集',
              icon: LucideIcons.list,
              outlined: true,
              onTap: onEpisodes,
            ),
            const SizedBox(width: 10),
            _Pill(
              key: const Key('drama_follow_button'),
              label: followed ? '已追剧' : '追剧',
              icon: followed ? LucideIcons.check : LucideIcons.plus,
              outlined: true,
              onTap: onFollow,
            ),
          ],
        ),
      ],
    );
  }
}

/// The 9sp update badge the official cards carry in their top-right corner.
class _UpdateTag extends StatelessWidget {
  final String text;

  const _UpdateTag({required this.text});

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 26),
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    decoration: BoxDecoration(
      color: HomePalette.accent,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: const TextStyle(color: Colors.white, fontSize: 9, height: 1.2),
    ),
  );
}

class _Pill extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool outlined;
  final VoidCallback onTap;

  const _Pill({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: outlined ? const Color(0x33FFFFFF) : Colors.white,
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: outlined ? Colors.white : const Color(0xFF252923),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                height: 1.1,
                fontWeight: FontWeight.w700,
                color: outlined ? Colors.white : const Color(0xFF252923),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The loading / empty / error surface of the feed.
class _FeedMessage extends StatelessWidget {
  final String message;
  final String? detail;
  final String? actionLabel;
  final Future<void> Function()? onAction;

  const _FeedMessage({
    super.key,
    required this.message,
    this.detail,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onAction == null)
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            else
              const Icon(LucideIcons.clapperboard, size: 30, color: Colors.white54),
            const SizedBox(height: 18),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: 10),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: Colors.white60,
                ),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
