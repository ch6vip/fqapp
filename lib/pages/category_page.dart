import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/category_front.dart';
import '../services/api_client.dart';
import '../widgets/home/home_design.dart';

/// 官方分类页（`BookCategoryActivity`，7.0.9.32 实测形态）：
///
/// * 顶部横向频道 tab（男生/女生/有声书/出版…；选中黑加粗，未选灰
///   #8C8C8C），左端返回、右端搜索；
/// * 左侧 87dp 维度栏（热门标签/主题/角色/情节——首项「全部」官方显示为
///   「热门标签」），选中黑加粗；
/// * 右侧内容区：当前维度名做组头（灰 #919191 小字），瓦片为**纯文字
///   chip**（黑字、浅灰圆角底、紧凑内边距），按 Wrap 流式排列。
///
/// 数据一次 GET 一个频道（`category_tab` 不同瓦片不同），维度切换是本地
/// 过滤（`down_category[].dim` 对 `rule.dim[].value`）。
class CategoryPage extends StatefulWidget {
  const CategoryPage({super.key, this.loader});

  /// 数据源注入（生产默认 [ApiClient.categoryFront]；测试替换，同
  /// [SearchPage] 的 loader 规矩——页测不落网络）。
  final Future<CategoryFront> Function({int tab})? loader;

  @override
  State<CategoryPage> createState() => _CategoryPageState();
}

class _CategoryPageState extends State<CategoryPage> {
  CategoryFront? _front;
  String? _error;
  int _tabValue = 1;
  int _dimIndex = 0;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<CategoryFront> _fetch({required int tab}) =>
      widget.loader?.call(tab: tab) ??
      ApiClient.instance.categoryFront(tab: tab);

  Future<void> _load({int? tab}) async {
    final target = tab ?? _tabValue;
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final front = await _fetch(tab: target);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _tabValue = target;
      _dimIndex = 0;
      _front = front;
      _error = front.isEmpty ? '分类暂时没有内容，稍后再试' : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final front = _front;
    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              tabs: front?.tabs ?? const [],
              selected: _tabValue,
              onSelect: (v) => _load(tab: int.tryParse(v) ?? 1),
            ),
            if (_loading)
              Padding(
                padding: const EdgeInsets.only(top: 120),
                child: CircularProgressIndicator(color: HomePalette.accent),
              )
            else if (_error != null)
              Expanded(
                child: _ErrorView(message: _error!, onRetry: _load),
              )
            else if (front != null)
              Expanded(
                child: Row(
                  children: [
                    _DimRail(
                      dims: front.dims,
                      selectedIndex: _dimIndex,
                      onSelect: (i) => setState(() => _dimIndex = i),
                    ),
                    Expanded(
                      child: _TileArea(front: front, dimIndex: _dimIndex),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 顶栏：返回 + 横向频道 tab + 搜索。
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.tabs,
    required this.selected,
    required this.onSelect,
  });

  final List<CategoryTab> tabs;
  final int selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(
            key: const Key('category_back'),
            icon: Icon(LucideIcons.chevron_left, size: 24, color: palette.ink),
            onPressed: () => Navigator.maybePop(context),
          ),
          Expanded(
            child: tabs.isEmpty
                ? const SizedBox.shrink()
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(right: 8),
                    itemCount: tabs.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 24),
                    itemBuilder: (context, index) {
                      final tab = tabs[index];
                      final isSelected = int.tryParse(tab.value) == selected;
                      return GestureDetector(
                        key: ValueKey('category_tab_${tab.value}'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelect(tab.value),
                        child: Center(
                          child: Text(
                            tab.name,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              // 官方：选中纯黑，未选 #8C8C8C。
                              color: isSelected
                                  ? palette.ink
                                  : const Color(0xFF8C8C8C),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          IconButton(
            key: const Key('category_search'),
            icon: Icon(LucideIcons.search, size: 20, color: palette.ink),
            onPressed: () {},
          ),
        ],
      ),
    );
  }
}

/// 维度栏项的显示名：首项「全部」官方写作「热门标签」。
String _dimLabel(int index, CategoryDim dim) => index == 0 ? '热门标签' : dim.name;

/// 左侧 87dp 维度栏。
class _DimRail extends StatelessWidget {
  const _DimRail({
    required this.dims,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<CategoryDim> dims;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      width: 87,
      child: ColoredBox(
        color: palette.soft,
        child: ListView.builder(
          itemCount: dims.length,
          itemBuilder: (context, index) {
            final selected = index == selectedIndex;
            return GestureDetector(
              key: ValueKey('category_dim_$index'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(index),
              child: Container(
                height: 48,
                alignment: Alignment.center,
                color: selected ? palette.canvas : null,
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 3,
                      height: selected ? 18 : 0,
                      color: HomePalette.accent,
                    ),
                    Expanded(
                      child: Text(
                        _dimLabel(index, dims[index]),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: selected ? palette.ink : palette.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 右侧内容区：维度名组头 + Wrap 文字 chips（当前维度过滤）。
///
/// chip 规格与折叠逻辑直译 `CategoryLayoutKt`（1130-1262 / 700-800 行）：
/// 文字 14sp、圆角 6dp、内边距横 5、最小高 30dp、横向间距 7、行距上 6
/// 下 4；`tag==1` 的热门项左侧 16dp 火苗图标。标签 **>30** 才出现
/// 「展开/收起」（12sp + 12dp 箭头），收起显示前 30 个。
class _TileArea extends StatefulWidget {
  const _TileArea({required this.front, required this.dimIndex});

  final CategoryFront front;
  final int dimIndex;

  @override
  State<_TileArea> createState() => _TileAreaState();
}

class _TileAreaState extends State<_TileArea> {
  bool _expanded = false;

  static const _collapsedCount = 30;

  @override
  void didUpdateWidget(_TileArea old) {
    super.didUpdateWidget(old);
    // 换维度/换频道回到收起态。
    if (old.dimIndex != widget.dimIndex || old.front != widget.front) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final dim = widget.front.dims[widget.dimIndex];
    final isAll = widget.dimIndex == 0 || dim.value == '0';
    final all = isAll
        ? widget.front.tiles
        : widget.front.tiles.where((t) => t.dim == dim.value).toList();
    final collapsible = all.length > _collapsedCount;
    final tiles = collapsible && !_expanded
        ? all.take(_collapsedCount).toList()
        : all;

    return ListView(
      key: const ValueKey('category_tile_list'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            _dimLabel(widget.dimIndex, dim),
            // 官方组头：灰 #919191 小字（CategoryLayoutKt 700-730）。
            style: const TextStyle(fontSize: 12, color: Color(0xFF919191)),
          ),
        ),
        if (tiles.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 32),
            child: Center(
              child: Text('这个维度暂时没有标签', style: TextStyle(color: palette.muted)),
            ),
          )
        else
          // 行距 = 每颗 chip 外边距 上6/下4（官方 PaddingKt.o(0,6,0,4)）。
          Wrap(
            spacing: 7,
            runSpacing: 10,
            children: [
              for (final tile in tiles) _CategoryChip(tile: tile),
              if (collapsible)
                _ExpandToggle(
                  expanded: _expanded,
                  onTap: () => setState(() => _expanded = !_expanded),
                ),
            ],
          ),
      ],
    );
  }
}

/// 一颗分类 chip：`CategoryLayoutKt` 1135-1260。
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.tile});

  final CategoryTile tile;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      key: ValueKey('category_tile_${tile.id}_${tile.name}'),
      constraints: const BoxConstraints(minHeight: 30),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.dark ? palette.soft : const Color(0xFFF0F0F1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tile.hot) ...[
            Icon(LucideIcons.flame, size: 16, color: HomePalette.accent),
            const SizedBox(width: 2),
          ],
          Text(tile.name, style: TextStyle(fontSize: 14, color: palette.ink)),
        ],
      ),
    );
  }
}

/// 「展开/收起」：12sp 文字 + 12dp 箭头（CategoryLayoutKt 766-786）。
class _ExpandToggle extends StatelessWidget {
  const _ExpandToggle({required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return GestureDetector(
      key: const Key('category_expand_toggle'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 30),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              expanded ? '收起' : '展开',
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
            const SizedBox(width: 2),
            Icon(
              expanded ? LucideIcons.chevron_up : LucideIcons.chevron_down,
              size: 12,
              color: palette.muted,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.cloud_off, size: 40, color: palette.muted),
          const SizedBox(height: 12),
          Text(message, style: TextStyle(fontSize: 14, color: palette.muted)),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => onRetry(),
            child: const Text(
              '重试',
              style: TextStyle(color: HomePalette.accent),
            ),
          ),
        ],
      ),
    );
  }
}
