/// The category page model (`/reading/bookapi/new_category/front/v`).
///
/// The 7.x upstream answers with the legacy schema, which carries everything
/// the official page renders: `rule.tab` (top channels), `rule.dim` (the left
/// rail dimensions, 全部/主题/角色/情节) and `down_category[]` (flat tiles,
/// each tagged with its `dim`). Tiles differ per `category_tab` request, so
/// one fetch renders one channel; switching channels refetches.
library;

/// One left-rail dimension, e.g. 全部 / 主题 / 角色 / 情节.
class CategoryDim {
  const CategoryDim({required this.name, required this.value});

  final String name;

  /// `dim.value` — matches [CategoryTile.dim].
  final String value;

  static CategoryDim? fromRaw(dynamic value) {
    if (value is! Map) return null;
    final name = (value['name'] ?? '').toString().trim();
    final v = (value['value'] ?? '').toString();
    if (name.isEmpty) return null;
    return CategoryDim(name: name, value: v);
  }
}

/// One top channel, e.g. 男生 / 女生 / 有声书 / 出版.
class CategoryTab {
  const CategoryTab({required this.name, required this.value});

  final String name;

  /// `tab.value` — passed back as `category_tab` on refetch.
  final String value;

  static CategoryTab? fromRaw(dynamic value) {
    if (value is! Map) return null;
    final name = (value['name'] ?? '').toString().trim();
    final v = (value['value'] ?? '').toString();
    if (name.isEmpty || v.isEmpty) return null;
    return CategoryTab(name: name, value: v);
  }
}

/// One tile: a bare text chip in the content area.
class CategoryTile {
  const CategoryTile({
    required this.name,
    this.dim = '',
    this.id = '',
    this.hot = false,
  });

  final String name;

  /// The dimension this tile belongs to（`down_category[].dim`）.
  final String dim;

  final String id;

  /// `tag == 1` — the hot tiles carry a leading flame icon
  /// （`CategoryLayoutKt` z2.f() → 16dp「热门标签的图片」）.
  final bool hot;

  static CategoryTile? fromRaw(dynamic value) {
    if (value is! Map) return null;
    final name = (value['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    return CategoryTile(
      name: name,
      dim: (value['dim'] ?? '').toString(),
      id: (value['id'] ?? '').toString(),
      hot: value['tag'] == 1 || value['tag'] == '1',
    );
  }
}

/// One fetch: the channels, the dimensions and this channel's tiles.
class CategoryFront {
  const CategoryFront({
    required this.tabs,
    required this.dims,
    required this.tiles,
  });

  static const empty = CategoryFront(tabs: [], dims: [], tiles: []);

  final List<CategoryTab> tabs;
  final List<CategoryDim> dims;
  final List<CategoryTile> tiles;

  bool get isEmpty => tiles.isEmpty;

  static CategoryFront fromPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) return empty;
    final data = payload['data'];
    if (data is! Map) return empty;
    final rule = data['rule'];
    if (rule is! Map) return empty;

    // 顶部频道：rule.tab[]（按 value 数值排序 → 男生/女生/有声书/出版）。
    final tabs = <CategoryTab>[];
    final rawTabs = rule['tab'];
    if (rawTabs is List) {
      for (final raw in rawTabs) {
        final tab = CategoryTab.fromRaw(raw);
        if (tab != null) tabs.add(tab);
      }
      tabs.sort(
        (a, b) => (int.tryParse(a.value) ?? 99) - (int.tryParse(b.value) ?? 99),
      );
    }

    // 左侧维度：rule.dim[]（首项是「全部」，value 0）。
    final dims = <CategoryDim>[];
    final rawDims = rule['dim'];
    if (rawDims is List) {
      for (final raw in rawDims) {
        final dim = CategoryDim.fromRaw(raw);
        if (dim != null) dims.add(dim);
      }
    }

    // 当前频道的瓦片：down_category[] 平铺。
    final tiles = <CategoryTile>[];
    final down = data['down_category'];
    if (down is List) {
      for (final raw in down) {
        final tile = CategoryTile.fromRaw(raw);
        if (tile != null) tiles.add(tile);
      }
    }
    if (dims.isEmpty || tiles.isEmpty) return empty;

    // 官方顶栏还有「短剧/漫画」两个频道（NewCategoryTabType Comic=5/
    // ShortSeries=6，客户端写死）；这套身份的 rule.tab 只下发 4 个，按
    // 官方顺序在尾部补齐，点击仍走同一端点。上游对 5/6 暂不响应时，页面
    // 落到错误重试态——入口与形态先对齐官方。
    const officialTail = [
      CategoryTab(name: '短剧', value: '6'),
      CategoryTab(name: '漫画', value: '5'),
    ];
    final values = tabs.map((t) => t.value).toSet();
    tabs.addAll(officialTail.where((t) => !values.contains(t.value)));

    return CategoryFront(
      tabs: List.unmodifiable(tabs),
      dims: List.unmodifiable(dims),
      tiles: List.unmodifiable(tiles),
    );
  }
}
