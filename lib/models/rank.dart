/// Rank catalogue and rank entries.
///
/// The catalogue (which ranks exist, and their sub-categories) is not an
/// endpoint of its own: the upstream ships it inside the novel homepage
/// response under `rank_with_category_data`. The entries come from
/// `/api/v1/rank/{id}?algo_type=&rank_sub_info_id=`.
///
/// Note: how the catalogue and `algo_type` were established — see
/// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
library;

/// One rank in the catalogue, e.g. 巅峰榜.
class RankTab {
  const RankTab({
    required this.name,
    required this.algo,
    this.subCategories = const [],
  });

  final String name;

  /// `rank_algo` upstream, passed back as `algo_type`.
  final int algo;
  final List<RankCategory> subCategories;

  bool get isEmpty => name.isEmpty;
}

/// A rank sub-category, e.g. 全部 / 穿越 / 系统.
class RankCategory {
  const RankCategory({required this.name, required this.id});

  final String name;

  /// `info_id` upstream, passed back as `rank_sub_info_id`.
  final int id;
}

/// One ranked work.
class RankEntry {
  const RankEntry({
    required this.position,
    this.id = '',
    this.title = '',
    this.cover = '',
    this.author = '',
    this.abstract = '',
    this.category = '',
    this.creationStatus = -1,
    this.wordNumber = 0,
    this.readCount = '',
  });

  /// 1-based place in the list.
  final int position;
  final String id;
  final String title;
  final String cover;
  final String author;
  final String abstract;
  final String category;
  final int creationStatus;
  final int wordNumber;
  final String readCount;

  bool get isEmpty => id.isEmpty && title.isEmpty;

  String get statusLabel => switch (creationStatus) {
    0 => '完结',
    1 => '连载中',
    4 => '停更',
    _ => '',
  };

  String get metaLabel => [
    if (author.isNotEmpty) author,
    if (category.isNotEmpty) category,
    if (statusLabel.isNotEmpty) statusLabel,
  ].join(' · ');
}

/// A page of ranked works.
class RankBoard {
  const RankBoard({this.entries = const [], this.hasMore = false});

  static const empty = RankBoard();

  final List<RankEntry> entries;
  final bool hasMore;

  bool get isEmpty => entries.isEmpty;
}

/// The catalogue of available ranks plus their sub-categories.
class RankCatalog {
  const RankCatalog({
    this.rankId = '',
    this.tabs = const [],
    this.categories = const [],
  });

  static const empty = RankCatalog();

  /// The rank list id, taken from the rank card's `cell_id_str`. The entries
  /// endpoint requires it in its path: `algo` and `categoryId` alone are not
  /// enough, and a placeholder id returns an empty list rather than an error.
  final String rankId;
  final List<RankTab> tabs;

  /// Sub-categories that apply to every rank.
  final List<RankCategory> categories;

  bool get isEmpty => tabs.isEmpty && rankId.isEmpty;

  /// Pulls the catalogue out of a novel homepage payload.
  ///
  /// The upstream ships it inside a rank card: the card's `cell_id_str` is the
  /// rank list id and `rank_with_category_data` holds `rank_algo_list` (the
  /// ranks) plus `sub_info_list` (their categories). The card can be nested
  /// anywhere in the page, so the tree is searched for the first map carrying
  /// `rank_with_category_data`.
  static RankCatalog fromHomepagePayload(Map<String, dynamic> payload) {
    final card = _findRankCard(payload, 0);
    if (card == null) return empty;
    final data = card['rank_with_category_data'];
    if (data is! Map) return empty;
    final tabs = <RankTab>[];
    final rawTabs = data['rank_algo_list'];
    if (rawTabs is List) {
      for (final entry in rawTabs) {
        if (entry is! Map) continue;
        final name = _string(entry['rank_name']);
        final algo = _int(entry['rank_algo'], fallback: -1);
        if (name.isEmpty || algo < 0) continue;
        tabs.add(RankTab(name: name, algo: algo));
      }
    }
    final categories = <RankCategory>[];
    final rawCats = data['sub_info_list'];
    if (rawCats is List) {
      for (final entry in rawCats) {
        if (entry is! Map) continue;
        final name = _string(entry['info_name']);
        if (name.isEmpty) continue;
        categories.add(
          RankCategory(name: name, id: _int(entry['info_id'], fallback: 0)),
        );
      }
    }
    final rankId = _string(
      card['cell_id_str'],
    ).ifEmpty(_string(card['cell_id']));
    if (tabs.isEmpty && rankId.isEmpty) return empty;
    return RankCatalog(
      rankId: rankId,
      tabs: List.unmodifiable(tabs),
      categories: List.unmodifiable(categories),
    );
  }

  /// Reads the rank entries payload.
  static RankBoard parsePage(Map<String, dynamic> payload, {int startAt = 1}) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) return RankBoard.empty;
    final data = payload['data'];
    if (data is! Map) return RankBoard.empty;
    final cellView = data['cell_view'];
    if (cellView is! Map) return RankBoard.empty;
    final cells = cellView['cell_data'];
    if (cells is! List) return RankBoard.empty;

    final entries = <RankEntry>[];
    final seenIds = <String>{};
    void addBook(Map<String, dynamic> book) {
      final entry = _entry(book, startAt + entries.length);
      if (entry == null) return;
      // A group cell can carry both an inline work and nested cells; keep the
      // first occurrence of every work instead of duplicating it. Some cells
      // have no book_id, so the title backs the key up.
      final key = entry.id.isEmpty ? 't:${entry.title}' : entry.id;
      if (!seenIds.add(key)) return;
      entries.add(entry);
    }

    for (final cell in cells) {
      if (cell is! Map) continue;
      // The board's cells are GROUP cells (月榜 / 男生榜 / …) whose own
      // `cell_data` holds the ranked works one level down. A work may also
      // arrive directly under the group, so try both shapes for every cell.
      final book = _firstBook(cell);
      if (book != null) addBook(book);
      final nested = cell['cell_data'];
      if (nested is! List) continue;
      for (final sub in nested) {
        if (sub is! Map) continue;
        final subBook = _firstBook(sub);
        if (subBook == null) continue;
        addBook(subBook);
      }
    }
    return RankBoard(
      entries: List.unmodifiable(entries),
      hasMore: data['has_more'] == true,
    );
  }

  /// Rank cells wrap the work in `book_data` (a list), sometimes with the book
  /// fields inline instead.
  static Map<String, dynamic>? _firstBook(Map<dynamic, dynamic> cell) {
    final raw = cell['book_data'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map) return Map<String, dynamic>.from(entry);
      }
    } else if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    if (cell['book_name'] != null) return Map<String, dynamic>.from(cell);
    return null;
  }

  static RankEntry? _entry(Map<String, dynamic> book, int position) {
    final id = _string(book['book_id']);
    final title = _string(book['book_name']);
    if (id.isEmpty && title.isEmpty) return null;
    final category = _string(book['category']);
    return RankEntry(
      position: position,
      id: id,
      title: title,
      cover: _string(book['thumb_url']),
      author: _string(book['author']),
      abstract: _string(book['abstract']),
      category: category.isEmpty
          ? ''
          : category.split(RegExp('[,，]')).first.trim(),
      creationStatus: _int(book['creation_status'], fallback: -1),
      wordNumber: _int(book['word_number']),
      readCount: _string(book['read_count']),
    );
  }

  /// Depth-first search for the first card that carries `rank_with_category_data`.
  static Map<String, dynamic>? _findRankCard(dynamic node, int depth) {
    if (depth > 12 || node == null) return null;
    if (node is List) {
      for (final child in node) {
        final found = _findRankCard(child, depth + 1);
        if (found != null) return found;
      }
      return null;
    }
    if (node is! Map) return null;
    if (node['rank_with_category_data'] is Map) {
      return Map<String, dynamic>.from(node);
    }
    for (final value in node.values) {
      final found = _findRankCard(value, depth + 1);
      if (found != null) return found;
    }
    return null;
  }
}

String _string(dynamic value) => value == null ? '' : '$value'.trim();

int _int(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

extension _IfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
