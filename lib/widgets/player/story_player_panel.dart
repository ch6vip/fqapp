import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/media_item.dart';

const storyAccent = Color(0xFFFF6699);

class StoryPlayerPanel extends StatefulWidget {
  final ScrollController scrollController;
  final List<Chapter> episodes;
  final int currentIndex;
  final int? playingIndex;
  final String title;
  final String description;
  final bool descriptionLoading;
  final String? descriptionError;
  final VoidCallback? onRetryDescription;
  final int initialTab;
  final bool expanded;
  final bool playing;
  final ValueChanged<int> onTabChanged;
  final ValueChanged<int> onSelectEpisode;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
  final VoidCallback onDragCancel;
  final VoidCallback onExpand;
  final VoidCallback onClose;

  const StoryPlayerPanel({
    super.key,
    required this.scrollController,
    required this.episodes,
    required this.currentIndex,
    required this.playingIndex,
    required this.title,
    required this.description,
    required this.descriptionLoading,
    required this.descriptionError,
    required this.onRetryDescription,
    required this.initialTab,
    required this.expanded,
    this.playing = false,
    required this.onTabChanged,
    required this.onSelectEpisode,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    required this.onExpand,
    required this.onClose,
  });

  @override
  State<StoryPlayerPanel> createState() => _StoryPlayerPanelState();
}

class _StoryPlayerPanelState extends State<StoryPlayerPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scrollStorage = PageStorageBucket();
  late int _tab;
  late bool _useGrid;
  bool _searchOpen = false;
  bool _needsLocate = true;
  String _query = '';
  double _horizontalDrag = 0;
  int _columns = 5;
  double _tileHeight = 52;
  double _rowHeight = 64;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    _useGrid = _hasNumberedTitles(widget.episodes);
    _tabs = TabController(length: 2, vsync: this, initialIndex: _tab)
      ..addListener(_tabChanged);
  }

  @override
  void didUpdateWidget(StoryPlayerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.episodes, widget.episodes)) {
      _useGrid = _hasNumberedTitles(widget.episodes);
      _needsLocate = true;
    }
    if (oldWidget.currentIndex != widget.currentIndex) _needsLocate = true;
    if (oldWidget.initialTab != widget.initialTab &&
        _tabs.index != widget.initialTab) {
      _tabs.index = widget.initialTab;
    }
  }

  void _tabChanged() {
    // TabController also notifies when its animation finishes. Only a real
    // tab change should rebuild the body or reset its scroll position.
    if (!mounted || _tab == _tabs.index) return;
    _searchFocus.unfocus();
    setState(() {
      _tab = _tabs.index;
    });
    widget.onTabChanged(_tab);
  }

  void _locateEpisode() {
    if (!_needsLocate || _tab != 1 || _query.isNotEmpty) return;
    _needsLocate = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tab != 1 || _query.isNotEmpty) return;
      if (!widget.scrollController.hasClients ||
          !widget.scrollController.position.hasContentDimensions ||
          widget.scrollController.position.viewportDimension <= 0) {
        _needsLocate = true;
        return;
      }
      final position = widget.scrollController.position;
      final row = _useGrid
          ? widget.currentIndex ~/ _columns
          : widget.currentIndex;
      final stride = _useGrid ? _tileHeight + 8 : _rowHeight;
      widget.scrollController.jumpTo(
        (8 + row * stride - position.viewportDimension / 3).clamp(
          0.0,
          position.maxScrollExtent,
        ),
      );
    });
  }

  void _toggleSearch() {
    if (_searchOpen) {
      _searchFocus.unfocus();
      _search.clear();
      setState(() {
        _searchOpen = false;
        _query = '';
        _needsLocate = true;
      });
    } else {
      setState(() => _searchOpen = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _searchOpen) _searchFocus.requestFocus();
      });
    }
  }

  void _select(int index) {
    _searchFocus.unfocus();
    widget.onSelectEpisode(index);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context);
    final tabHeight = math.max(46.0, scale.scale(16) + 24);
    final toolbarHeight = math.max(44.0, scale.scale(14) + 20);
    final headerHeight = 14 + tabHeight + (_tab == 1 ? toolbarHeight + 8 : 0);
    _tileHeight = math.max(52.0, scale.scale(16) * 1.2 + 24);
    _rowHeight = math.max(64.0, scale.scale(16) * 1.25 + 32);
    return Theme(
      data: ThemeData.light(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: storyAccent,
          primary: storyAccent,
        ),
      ),
      child: Material(
        key: const ValueKey('story-panel'),
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final preferredColumns = scale.scale(16) > 20 ? 4 : 5;
            final minTileWidth = math.max(
              44.0,
              scale.scale(widget.episodes.length.toString().length * 9.0) + 16,
            );
            final columns =
                ((constraints.maxWidth - 32 + 8) / (minTileWidth + 8))
                    .floor()
                    .clamp(1, preferredColumns);
            if (_columns != columns) {
              _columns = columns;
              _needsLocate = true;
            }
            _locateEpisode();
            // While the sheet closes, clip the fixed header instead of
            // squeezing its controls into a zero-height Column.
            return OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: math.max(headerHeight, constraints.maxHeight),
              maxHeight: math.max(headerHeight, constraints.maxHeight),
              child: Column(
                children: [
                  GestureDetector(
                    key: const ValueKey('story-panel-drag'),
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragStart: widget.onDragStart,
                    onVerticalDragUpdate: widget.onDragUpdate,
                    onVerticalDragEnd: widget.onDragEnd,
                    onVerticalDragCancel: widget.onDragCancel,
                    child: Column(
                      children: [
                        SizedBox(
                          height: 14,
                          child: Center(
                            child: Container(
                              width: 30,
                              height: 4,
                              decoration: BoxDecoration(
                                color: const Color(0xFFCACDD1),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: tabHeight,
                          child: Row(
                            children: [
                              Expanded(
                                child: TabBar(
                                  controller: _tabs,
                                  isScrollable: true,
                                  tabAlignment: TabAlignment.start,
                                  dividerColor: Colors.transparent,
                                  labelColor: const Color(0xFF18191C),
                                  unselectedLabelColor: const Color(0xFF9499A0),
                                  labelStyle: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  indicator: const _StoryTabIndicator(),
                                  tabs: [
                                    const Tab(text: '简介'),
                                    Tab(
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Text('选集'),
                                          const SizedBox(width: 6),
                                          Text(
                                            '${widget.episodes.length}',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w400,
                                              color: Color(0xFF9499A0),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: 40,
                                child: IconButton(
                                  tooltip: widget.expanded ? '收起面板' : '展开面板',
                                  onPressed: widget.onExpand,
                                  iconSize: 18,
                                  icon: Icon(
                                    widget.expanded
                                        ? Icons.unfold_less
                                        : Icons.unfold_more,
                                    color: const Color(0xFFA8ADB4),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 44,
                                child: IconButton(
                                  tooltip: '关闭面板',
                                  onPressed: widget.onClose,
                                  icon: const Icon(
                                    Icons.close,
                                    size: 22,
                                    color: Color(0xFF61666D),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_tab == 1) _episodeToolbar(toolbarHeight),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (_) => _horizontalDrag = 0,
                      onHorizontalDragUpdate: (details) =>
                          _horizontalDrag += details.delta.dx,
                      onHorizontalDragEnd: (details) {
                        final velocity = details.primaryVelocity ?? 0;
                        if (_horizontalDrag.abs() < 40 &&
                            velocity.abs() < 400) {
                          return;
                        }
                        final direction = velocity.abs() >= 400
                            ? velocity
                            : _horizontalDrag;
                        _tabs.animateTo(direction < 0 ? 1 : 0);
                      },
                      child: PageStorage(
                        bucket: _scrollStorage,
                        child: KeyedSubtree(
                          key: PageStorageKey<String>('story-panel-tab-$_tab'),
                          child: _tab == 0 ? _introduction() : _episodes(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _episodeToolbar(double height) => Padding(
    key: const ValueKey('story-episode-toolbar'),
    padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
    child: SizedBox(
      height: height,
      child: _searchOpen
          ? Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('story-episode-search'),
                    controller: _search,
                    focusNode: _searchFocus,
                    keyboardType: _useGrid
                        ? TextInputType.number
                        : TextInputType.text,
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: _useGrid ? '输入集数' : '搜索集数或标题',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      filled: true,
                      fillColor: const Color(0xFFF5F6F8),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (value) {
                      setState(() => _query = value.trim());
                      if (widget.scrollController.hasClients) {
                        widget.scrollController.jumpTo(0);
                      }
                    },
                    onSubmitted: (_) => _searchFocus.unfocus(),
                  ),
                ),
                IconButton(
                  tooltip: '关闭搜索',
                  onPressed: _toggleSearch,
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Text(
                    widget.episodes.isEmpty
                        ? '暂无剧集'
                        : widget.playingIndex == widget.currentIndex
                        ? '${widget.playing ? '正在播放' : '当前'} 第 ${widget.currentIndex + 1} 集'
                        : '已选择 第 ${widget.currentIndex + 1} 集',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF61666D),
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _toggleSearch,
                  icon: const Icon(Icons.search, size: 19),
                  label: const Text('找集'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF61666D),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(60, 40),
                  ),
                ),
              ],
            ),
    ),
  );

  Widget _introduction() => ListView(
    key: const ValueKey('story-introduction'),
    controller: widget.scrollController,
    padding: EdgeInsets.fromLTRB(
      16,
      18,
      16,
      24 + MediaQuery.paddingOf(context).bottom,
    ),
    children: [
      Text(
        widget.title,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Color(0xFF18191C),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        '共 ${widget.episodes.length} 集',
        style: const TextStyle(color: Color(0xFF9499A0), fontSize: 13),
      ),
      const SizedBox(height: 20),
      ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        tileColor: const Color(0xFFF6F7F8),
        leading: const Icon(Icons.layers_outlined),
        title: const Text('查看全部剧集'),
        subtitle: Text(
          widget.episodes.isEmpty ? '暂无剧集' : '当前第 ${widget.currentIndex + 1} 集',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _tabs.animateTo(1),
      ),
      const SizedBox(height: 24),
      const Text(
        '剧情简介',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      if (widget.descriptionLoading)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (widget.descriptionError != null) ...[
        const Text('简介加载失败', style: TextStyle(color: Color(0xFF9499A0))),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: widget.onRetryDescription,
            child: const Text('重新加载简介'),
          ),
        ),
      ] else
        Text(
          widget.description.isEmpty ? '暂无简介' : widget.description,
          style: const TextStyle(
            fontSize: 15,
            height: 1.7,
            color: Color(0xFF61666D),
          ),
        ),
    ],
  );

  Widget _episodes() {
    final number = int.tryParse(_query);
    final indexes = [
      for (var i = 0; i < widget.episodes.length; i++)
        if (_query.isEmpty ||
            (number != null
                ? number == i + 1
                : widget.episodes[i].title.toLowerCase().contains(
                    _query.toLowerCase(),
                  )))
          i,
    ];
    return CustomScrollView(
      key: const ValueKey('story-episodes'),
      controller: widget.scrollController,
      slivers: [
        if (indexes.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('没有匹配的剧集')),
            ),
          )
        else if (_useGrid)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            sliver: SliverGrid(
              key: const ValueKey('story-episode-grid'),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columns,
                mainAxisExtent: _tileHeight,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, position) => _episodeTile(indexes[position]),
                childCount: indexes.length,
              ),
            ),
          )
        else
          SliverFixedExtentList(
            key: const ValueKey('story-episode-list'),
            itemExtent: _rowHeight,
            delegate: SliverChildBuilderDelegate((context, position) {
              final index = indexes[position];
              final active = index == widget.playingIndex;
              final pending = index == widget.currentIndex && !active;
              return ListTile(
                key: ValueKey('story-episode-$index'),
                selected: active || pending,
                selectedColor: storyAccent,
                selectedTileColor: const Color(0xFFFFF1F5),
                leading: SizedBox(
                  width: 32,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('${index + 1}'),
                  ),
                ),
                title: Text(
                  widget.episodes[index].title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: active
                    ? const Icon(Icons.graphic_eq, semanticLabel: '当前剧集')
                    : pending
                    ? const Icon(Icons.hourglass_empty, semanticLabel: '待播放')
                    : null,
                onTap: () => _select(index),
              );
            }, childCount: indexes.length),
          ),
        SliverToBoxAdapter(
          child: SizedBox(height: 16 + MediaQuery.paddingOf(context).bottom),
        ),
      ],
    );
  }

  Widget _episodeTile(int index) {
    final active = index == widget.playingIndex;
    final pending = index == widget.currentIndex && !active;
    final selected = active || pending;
    return Semantics(
      key: ValueKey('story-episode-$index'),
      label: '第 ${index + 1} 集',
      value: active
          ? (widget.playing ? '正在播放' : '当前剧集')
          : pending
          ? '已选择'
          : null,
      button: true,
      selected: selected,
      excludeSemantics: true,
      onTap: () => _select(index),
      child: Material(
        color: selected ? const Color(0xFFFFF1F5) : const Color(0xFFF5F6F8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: selected ? storyAccent : Colors.transparent),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _select(index),
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(bottom: selected ? 10 : 0),
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: selected ? storyAccent : const Color(0xFF18191C),
                      ),
                    ),
                  ),
                ),
              ),
              if (selected)
                Positioned(
                  bottom: 4,
                  left: 0,
                  right: 0,
                  child: Icon(
                    pending
                        ? Icons.hourglass_empty
                        : widget.playing
                        ? Icons.graphic_eq
                        : Icons.play_arrow_rounded,
                    size: 12,
                    color: storyAccent,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// Only hide a title when it encodes exactly the episode's ordinal. Missing,
// reordered or meaningful titles keep their list presentation.
bool _hasNumberedTitles(List<Chapter> episodes) {
  final pattern = RegExp(
    r'^(?:第|episode|ep)?([0-9零〇一二三四五六七八九十百千万两]+)(?:集|话|期)?$',
    caseSensitive: false,
  );
  for (var i = 0; i < episodes.length; i++) {
    final title = episodes[i].title.replaceAll(RegExp(r'\s+'), '');
    if (title.isEmpty) continue;
    final match = pattern.firstMatch(title);
    if (match == null || _episodeOrdinal(match.group(1)!) != i + 1) {
      return false;
    }
  }
  return true;
}

int? _episodeOrdinal(String value) {
  final number = int.tryParse(value);
  if (number != null) return number;
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  const units = {'十': 10, '百': 100, '千': 1000, '万': 10000};
  var total = 0;
  var section = 0;
  var digit = 0;
  for (final character in value.split('')) {
    if (digits.containsKey(character)) {
      digit = digit * 10 + digits[character]!;
    } else {
      final unit = units[character];
      if (unit == null) return null;
      if (unit == 10000) {
        total += (section + digit) * unit;
        section = 0;
      } else {
        section += (digit == 0 ? 1 : digit) * unit;
      }
      digit = 0;
    }
  }
  return total + section + digit;
}

class _StoryTabIndicator extends Decoration {
  const _StoryTabIndicator();
  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _StoryIndicatorPainter();
}

class _StoryIndicatorPainter extends BoxPainter {
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size!;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          offset.dx + (size.width - 16) / 2,
          offset.dy + size.height - 4,
          16,
          4,
        ),
        const Radius.circular(2),
      ),
      Paint()..color = storyAccent,
    );
  }
}
