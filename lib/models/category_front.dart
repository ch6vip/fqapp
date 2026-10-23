/// The category front page model (`/reading/bookapi/new_category/front/v`).
///
/// One GET returns the whole page (the official `KmpCategoryFragment` renders
/// straight from it): a tab list down the left, and per tab a stack of cells
/// whose atoms carry the category tiles.
library;

/// One category tile: name + icon + the landing schema.
class CategoryTile {
  const CategoryTile({
    required this.name,
    this.icon = '',
    this.id = '',
    this.url = '',
    this.isViewAll = false,
  });

  final String name;
  final String icon;

  /// `category_data.category_id`.
  final String id;

  /// `category_landpage_url`（dragon1967:// schema）.
  final String url;

  /// `is_view_all` — the「查看全部」tile.
  final bool isViewAll;

  static CategoryTile? fromRaw(dynamic value) {
    if (value is! Map) return null;
    final name = (value['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    return CategoryTile(
      name: name,
      icon: (value['pic_url'] ?? '').toString(),
      id: (value['category_id'] ?? '').toString(),
      url: (value['category_landpage_url'] ?? '').toString(),
      isViewAll: value['is_view_all'] == true,
    );
  }
}

/// One cell of a tab: a titled group of tiles.
class CategoryGroup {
  const CategoryGroup({required this.name, required this.tiles});

  final String name;
  final List<CategoryTile> tiles;

  static CategoryGroup? fromRaw(dynamic value) {
    if (value is! Map) return null;
    final tiles = <CategoryTile>[];
    final atoms = value['atom_data'];
    if (atoms is List) {
      for (final atom in atoms) {
        if (atom is! Map) continue;
        final tile = CategoryTile.fromRaw(atom['category_data']);
        if (tile != null) tiles.add(tile);
      }
    }
    if (tiles.isEmpty) return null;
    return CategoryGroup(name: (value['cell_name'] ?? '').toString(), tiles: tiles);
  }
}

/// One left-rail channel, e.g. 男频 / 女频 / 出版.
class CategoryChannel {
  const CategoryChannel({
    required this.name,
    required this.tab,
    required this.groups,
  });

  final String name;

  /// `category_tab` (NewCategoryTabType)，回传刷新用。
  final int tab;

  final List<CategoryGroup> groups;

  static CategoryChannel? fromRaw(dynamic value) {
    if (value is! Map) return null;
    final name = (value['tab_name'] ?? '').toString().trim();
    final tab = int.tryParse('${value['category_tab']}');
    if (name.isEmpty || tab == null) return null;
    final groups = <CategoryGroup>[];
    final cells = value['cell_data'];
    if (cells is List) {
      for (final cell in cells) {
        final group = CategoryGroup.fromRaw(cell);
        if (group != null) groups.add(group);
      }
    }
    if (groups.isEmpty) return null;
    return CategoryChannel(name: name, tab: tab, groups: groups);
  }
}

/// The whole front page: the left-rail channels.
class CategoryFront {
  const CategoryFront({required this.channels});

  static const empty = CategoryFront(channels: []);

  final List<CategoryChannel> channels;

  bool get isEmpty => channels.isEmpty;

  static CategoryFront fromPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) return empty;
    final data = payload['data'];
    if (data is! Map) return empty;
    final config = data['category_tab_config'];
    final tabList = config is Map ? config['tab_list'] : null;
    if (tabList is! List) return empty;
    final channels = <CategoryChannel>[];
    for (final raw in tabList) {
      final channel = CategoryChannel.fromRaw(raw);
      if (channel != null) channels.add(channel);
    }
    if (channels.isEmpty) return empty;
    return CategoryFront(channels: List.unmodifiable(channels));
  }
}
