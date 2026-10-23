import 'media_item.dart';

/// One block of the bookstore feed, kept as the upstream shaped it.
///
/// The official client renders the bookstore as a single recycler view whose
/// rows are picked by `show_type` (see `ShowType.java`, dispatched through
/// `showType.ordinal()` in `bookmall/f0.java:159`). fqapp used to flatten every
/// block into one `List<MediaItem>`, which is why the homepage could only ever
/// be a grid: the block boundaries — what a "排行榜" row is, where a section
/// starts — were gone before the UI ever saw them.
///
/// This model keeps the boundaries. A cell may carry its own cards
/// ([items]), nested cells ([children]), or both; the renderer decides what a
/// given [showType] means.
class HomeCell {
  /// Upstream render code (`show_type`). 0 when the block did not declare one.
  final int showType;

  /// Section title, e.g.「排行榜」「猜你喜欢」. Empty for anonymous cards.
  final String name;

  /// Stable upstream id (`cell_id_str`). Numeric `cell_id` is a JSON double
  /// and loses precision, so only the string form is kept.
  final String id;

  /// Per-block style switches (`style`). Left as raw data: the renderer reads
  /// the few keys it understands and ignores the rest.
  final Map<String, dynamic> style;

  /// Block-level payload that is not a card list, e.g. the rank board names in
  /// `rank_with_category_data` (see [HomeCell.showType] 511). Same policy as
  /// [style]: kept raw, read by the renderer that understands it.
  final Map<String, dynamic> extra;

  /// Cards directly under this block.
  final List<MediaItem> items;

  /// Nested blocks, for containers such as `MultiTabMixedUnlimitedV2`, which
  /// wraps the actual cards one level down.
  final List<HomeCell> children;

  /// Topic rows of a 书荒广场 card (`topic_data[]`). Empty for book cards.
  ///
  /// This card carries no `book_data` at all — `m0.java:1501` turns it into a
  /// `StaggeredUgcModel` instead of a book model — so without this field the
  /// card has no identity and would be dropped by [isEmpty].
  final List<HomeTopic> topics;

  /// Upstream jump target (`cell_url`). The 书荒广场 card is the only card in
  /// this feed that uses it: it is the 「更多」/pill target.
  final String url;

  const HomeCell({
    required this.showType,
    required this.name,
    required this.id,
    required this.style,
    required this.items,
    required this.children,
    this.topics = const [],
    this.url = '',
    this.extra = const {},
  });

  bool get isEmpty =>
      items.isEmpty && topics.isEmpty && children.every((c) => c.isEmpty);

  /// Every card under this block, in document order.
  ///
  /// Lets the untouched grid path keep working while blocks are adopted one
  /// type at a time. Books only — see [homeCellEntries] for the stream that
  /// also carries topic cards.
  List<MediaItem> flatten() {
    final out = <MediaItem>[...items];
    for (final child in children) {
      out.addAll(child.flatten());
    }
    return out;
  }
}

/// One topic row of a 书荒广场 card (`topic_data[]`, row layout `bdr.xml`).
class HomeTopic {
  const HomeTopic({
    required this.id,
    required this.title,
    required this.tips,
    required this.cover,
    required this.url,
  });

  /// `topic_data.topic_id`, falling back to `topic_desc.topic_id`.
  final String id;

  /// Row title (12sp, up to two lines in `bdr.xml` `ibg`).
  final String title;

  /// `topic_desc.card_tips` — the grey 「拯救了30万人的书荒」 line (`htk`).
  final String tips;

  /// `topic_desc.topic_cover` — the 40×56 thumbnail.
  final String cover;

  /// Jump target; a `dragon1967://webview` link that wraps an https page.
  final String url;

  bool get isEmpty => title.isEmpty && cover.isEmpty && url.isEmpty;

  static HomeTopic? fromRaw(dynamic value) {
    if (value is! Map) return null;
    final desc = value['topic_desc'];
    final topicData = value['topic_data'];
    final topic = HomeTopic(
      id: (topicData is Map ? topicData['topic_id'] : null)?.toString() ??
          (desc is Map ? desc['topic_id'] : null)?.toString() ??
          '',
      title: (value['title'] ?? '').toString(),
      tips: desc is Map ? (desc['card_tips'] ?? '').toString() : '',
      cover: desc is Map ? (desc['topic_cover'] ?? '').toString() : '',
      url: (value['url'] ?? '').toString(),
    );
    return topic.isEmpty ? null : topic;
  }
}

/// One card of a stream block, in document order.
///
/// [HomeCell.flatten] can only express books, so the 385 stream — which mixes
/// book cards with one 书荒广场 topic card — needs this sequence: dropping the
/// topic card would also shift every later book one slot to the left.
class HomeCardEntry {
  const HomeCardEntry.book(MediaItem this.item) : cell = null;
  const HomeCardEntry.topics(HomeCell this.cell) : item = null;

  final MediaItem? item;

  /// The card owning [topics]; its [HomeCell.url] backs the 「更多」 target.
  final HomeCell? cell;

  bool get isBook => item != null;

  List<HomeTopic> get topics => cell?.topics ?? const [];
}

/// Every card under [cell] in document order, books and topic cards alike.
List<HomeCardEntry> homeCellEntries(HomeCell cell) {
  final out = <HomeCardEntry>[];
  for (final item in cell.items) {
    out.add(HomeCardEntry.book(item));
  }
  if (cell.topics.isNotEmpty) out.add(HomeCardEntry.topics(cell));
  for (final child in cell.children) {
    out.addAll(homeCellEntries(child));
  }
  return out;
}

/// Parses the bookstore feed into blocks.
///
/// Starts at `data.tab_item[<selected>].cell_data[]` when present — that is
/// where `/api/v1/recommend/homepage` keeps the rows — and falls back to
/// `data.cell_data[]` for the second-stage video flow
/// (`bookmall/cell/change`), which nests one `cell_view` deeper.
///
/// Returns an empty list when the payload has no recognisable blocks; callers
/// then keep using the flat item list, so an upstream shape change degrades to
/// the previous behaviour instead of blanking the page.
List<HomeCell> parseHomeCells(Map<String, dynamic> payload) {
  final data = payload['data'] ?? payload;
  if (data is! Map) return const [];

  dynamic blocks;
  final tabItem = data['tab_item'];
  if (tabItem is List) {
    final index = _intOf(data['tab_index']) ?? 0;
    if (index >= 0 && index < tabItem.length) {
      final selected = tabItem[index];
      if (selected is Map) blocks = selected['cell_data'];
    }
    if (blocks == null) {
      for (final entry in tabItem) {
        if (entry is Map && entry['cell_data'] is List) {
          blocks = entry['cell_data'];
          break;
        }
      }
    }
  }
  // A single tab object — what the client passes after picking the tab whose
  // `tab_type` the caller asked for — carries `cell_data` at its own top level,
  // with no wrapping `data`/`tab_item`.
  blocks ??= data['cell_data'];
  if (blocks == null) {
    final cellView = data['cell_view'];
    if (cellView is Map) blocks = cellView['cell_data'];
  }

  final cells = _parseCellList(blocks);
  return cells;
}

List<HomeCell> _parseCellList(dynamic value, [int depth = 0]) {
  // The audio feed nests book_data four cell_data levels deep; stay generous
  // enough to reach it without risking unbounded recursion on a hostile body.
  if (depth > 12 || value is! List) return const [];
  final out = <HomeCell>[];
  for (final entry in value) {
    if (entry is! Map) continue;
    final cell = _parseCell(Map<String, dynamic>.from(entry), depth);
    if (!cell.isEmpty) out.add(cell);
  }
  return out;
}

HomeCell _parseCell(Map<String, dynamic> raw, int depth) {
  final items = <MediaItem>[];
  // A block's own cards. `book_data` holds the book and can be either a single
  // map (the usual case one level down) or a list; both shapes appear in the
  // same feed. Anything else carrying an identity at this level counts too.
  // Nested blocks are parsed separately below, so this must not descend into
  // `cell_data`.
  final ownData = raw['book_data'];
  if (ownData is List) {
    for (final entry in ownData) {
      final item = _itemFrom(entry);
      if (item != null) items.add(item);
    }
  } else if (ownData is Map) {
    final item = _itemFrom(raw);
    if (item != null) items.add(item);
  } else if (_hasIdentity(raw)) {
    final item = _itemFrom(raw);
    if (item != null) items.add(item);
  }

  final children = _parseCellList(raw['cell_data'], depth + 1);

  // A 书荒广场 card (`dynamic_card_type=3`) ships `topic_data[]` instead of
  // `book_data`; without it the card has no identity and is dropped.
  final topics = <HomeTopic>[];
  final rawTopics = raw['topic_data'];
  if (rawTopics is List) {
    for (final entry in rawTopics) {
      final topic = HomeTopic.fromRaw(entry);
      if (topic != null) topics.add(topic);
    }
  }

  // Keys that describe the block rather than its cards. The rank block keeps
  // its board list and categories here; the renderer that knows `show_type`
  // 511 reads it, everything else ignores it.
  Map<String, dynamic>? blockExtra;
  for (final key in _extraKeys) {
    final value = raw[key];
    if (value is Map) {
      (blockExtra ??= <String, dynamic>{})[key] = Map<String, dynamic>.from(
        value,
      );
    }
  }

  return HomeCell(
    showType: _intOf(raw['show_type']) ?? 0,
    name: (raw['cell_name'] ?? '').toString(),
    id: (raw['cell_id_str'] ?? '').toString(),
    style: raw['style'] is Map
        ? Map<String, dynamic>.from(raw['style'] as Map)
        : const {},
    items: items,
    children: children,
    topics: topics,
    url: (raw['cell_url'] ?? '').toString(),
    extra: blockExtra ?? const {},
  );
}

const _extraKeys = <String>['rank_with_category_data'];

const _identityKeys = <String>[
  'book_id',
  'video_id',
  'vid',
  'series_id',
  'pseries_id',
  'manga_id',
  'comic_id',
  'audio_book_id',
  'audio_id',
  'item_id',
];

bool _hasIdentity(Map<String, dynamic> map) {
  for (final key in _identityKeys) {
    final value = map[key];
    if (value != null && value.toString().isNotEmpty) return true;
  }
  return false;
}

MediaItem? _itemFrom(dynamic value) {
  if (value is! Map) return null;
  final item = MediaItem.fromRaw(Map<String, dynamic>.from(value));
  return item.id.isEmpty ? null : item;
}

int? _intOf(dynamic value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
