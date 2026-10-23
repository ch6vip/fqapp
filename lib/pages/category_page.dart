import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/category_front.dart';
import '../services/api_client.dart';
import '../services/app_links.dart';
import '../widgets/home/home_design.dart';

/// 官方分类页（`KmpCategoryFragment`，数据一次 GET `new_category/front` 全量）。
///
/// 结构（`CategoryLayout.kt`）：左侧频道竖列（男频/女频/出版…），右侧按
/// cell 分组的分类瓦片滚动区（`z2`：`pic_url` 图标 + name，点击走
/// `category_landpage_url`）。官方为 Compose 无 XML；尺寸按官方截屏：
/// 左列约 88dp，瓦片 3 列。
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
  int _channelIndex = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<CategoryFront> _fetch({int tab = 1}) =>
      widget.loader?.call(tab: tab) ??
      ApiClient.instance.categoryFront(tab: tab);

  Future<void> _load() async {
    final front = await _fetch();
    if (!mounted) return;
    setState(() {
      _front = front;
      _error = front.isEmpty ? '分类暂时没有内容，稍后再试' : null;
    });
  }

  void _openTile(CategoryTile tile) {
    final url = tile.url;
    if (url.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${tile.name} 的详情页还在接入中')));
      return;
    }
    openAppLink(context, url);
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final front = _front;
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        title: Text('分类', style: TextStyle(color: palette.ink, fontSize: 17)),
        leading: IconButton(
          icon: Icon(LucideIcons.chevron_left, color: palette.ink, size: 22),
          onPressed: () => Navigator.maybePop(context),
        ),
      ),
      body: front == null
          ? Center(child: CircularProgressIndicator(color: HomePalette.accent))
          : _error != null
          ? _ErrorView(message: _error!, onRetry: _load)
          : Row(
              children: [
                _ChannelRail(
                  channels: front.channels,
                  selectedIndex: _channelIndex,
                  onSelect: (i) => setState(() => _channelIndex = i),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 32),
                    itemCount: front.channels[_channelIndex].groups.length,
                    itemBuilder: (context, index) => _GroupSection(
                      group: front.channels[_channelIndex].groups[index],
                      onOpenTile: _openTile,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 左侧频道竖列：选中项竖条 + 加粗，其余灰。
class _ChannelRail extends StatelessWidget {
  const _ChannelRail({
    required this.channels,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<CategoryChannel> channels;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      width: 88,
      child: ColoredBox(
        color: palette.soft,
        child: ListView.builder(
          itemCount: channels.length,
          itemBuilder: (context, index) {
            final selected = index == selectedIndex;
            return GestureDetector(
              key: ValueKey('category_channel_$index'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(index),
              child: Container(
                height: 48,
                alignment: Alignment.center,
                color: selected ? palette.canvas : null,
                child: Row(
                  children: [
                    // 官方选中态：左侧品牌橙竖条。
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 3,
                      height: selected ? 20 : 0,
                      color: HomePalette.accent,
                    ),
                    Expanded(
                      child: Text(
                        channels[index].name,
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

/// 右侧一组：分组名 + 3 列瓦片（图标 + 名称）。
class _GroupSection extends StatelessWidget {
  const _GroupSection({required this.group, required this.onOpenTile});

  final CategoryGroup group;
  final void Function(CategoryTile) onOpenTile;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (group.name.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              group.name,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: palette.ink,
              ),
            ),
          ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.92,
          ),
          itemCount: group.tiles.length,
          itemBuilder: (context, index) {
            final tile = group.tiles[index];
            return GestureDetector(
              key: ValueKey('category_tile_${tile.id}_${tile.name}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onOpenTile(tile),
              child: Column(
                children: [
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: palette.soft,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: tile.icon.isEmpty
                            ? Icon(
                                LucideIcons.book_open,
                                size: 28,
                                color: palette.muted,
                              )
                            : Image.network(
                                tile.icon,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Icon(
                                  LucideIcons.book_open,
                                  size: 28,
                                  color: palette.muted,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tile.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: palette.ink),
                  ),
                ],
              ),
            );
          },
        ),
      ],
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
