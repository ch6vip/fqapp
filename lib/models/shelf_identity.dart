// 书架条目的稳定身份键。
//
// 身份格式来自本仓库既有的 `ShelfStore.keyFor`（`shelf_v1:<kind>:<id>`），
// 并按书架移植设计扩展到能同时容纳多个数据源（番茄 / 书旗 / 本地导入 /
// 短剧 / 漫剧）：
//
//   contentKey = [source/]kind:<seriesId ?? id>
//   storageKey = 'shelf_v1:' + contentKey
//
// 书旗与番茄的 bookId 同为纯数字，去掉来源就会把两本书串成一本，因此来源
// 是身份的一部分。番茄（以及空/非法来源）省略前缀，使旧记录与既有存储键
// 逐字保持不变。
//
// Ported concept from Wenku8_Flutter (revision ebcd7f1) `book_identity.dart`
// and `local_library_preferences.dart`; fqapp adds the source-qualified key
// because its shelf mixes 番茄 / 书旗 / 本地导入 items that upstream never
// had. No upstream UI or storage constant is copied.
library;

import 'media_item.dart';

/// Parses and formats the durable identity of one shelf entry.
abstract final class ShelfIdentity {
  /// Kinds the shelf stores. Mirrors the `MediaItem.kind` values the app emits.
  static const Set<String> kinds = {'book', 'audio', 'manga', 'video', 'manju'};

  /// A data-source id: lowercase, 1–32 characters, `[a-z0-9_-]`, starting with
  /// a letter. `fanqie` and `shuqi` are the current values.
  static final RegExp sourcePattern = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');

  /// Content ids allowed through a backup round-trip. Runtime ids are not
  /// restricted by this (a malformed id still opens from its storage key), but
  /// restored ids must be printable and bounded.
  static final RegExp contentIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  /// Local imported-book ids created by `ImportedBookStore`
  /// (`local_<millis>_<hex>`). Mirrored here so the models layer does not have
  /// to import the file-import service just to answer "is this local?".
  static final RegExp localContentIdPattern = RegExp(
    r'^local_[0-9]+_[a-f0-9]+$',
  );

  static const String fanqie = 'fanqie';
  static const String storagePrefix = 'shelf_v1:';

  static bool isValidSource(String source) => sourcePattern.hasMatch(source);

  static bool isValidContentId(String id) => contentIdPattern.hasMatch(id);

  /// Empty or malformed sources degrade to the historical default. This keeps
  /// the fanqie storage key byte-identical to pre-migration records.
  static String normalizeSource(String source) =>
      isValidSource(source) ? source : fanqie;

  /// `[source/]kind:<seriesId ?? id>`; the fanqie prefix is omitted.
  static String contentKeyFor(
    String kind,
    String contentId, {
    String source = fanqie,
  }) {
    final normalized = normalizeSource(source);
    return normalized == fanqie
        ? '$kind:$contentId'
        : '$normalized/$kind:$contentId';
  }

  static String contentKeyOf(MediaItem item) =>
      contentKeyFor(item.kind, item.seriesId ?? item.id, source: item.source);

  /// `shelf_v1:` + [contentKeyFor].
  static String storageKeyFor(
    String kind,
    String contentId, {
    String source = fanqie,
  }) => '$storagePrefix${contentKeyFor(kind, contentId, source: source)}';

  static String storageKeyOf(MediaItem item) =>
      '$storagePrefix${contentKeyOf(item)}';

  /// Parses `[source/]kind:<contentId>`. Returns null for malformed keys.
  static ({String source, String kind, String contentId})? parseContentKey(
    String key,
  ) {
    var source = fanqie;
    var rest = key;
    final slash = key.indexOf('/');
    if (slash >= 0) {
      final prefix = key.substring(0, slash);
      if (!isValidSource(prefix)) return null;
      source = prefix;
      rest = key.substring(slash + 1);
    }
    final colon = rest.indexOf(':');
    if (colon <= 0) return null;
    final kind = rest.substring(0, colon);
    final contentId = rest.substring(colon + 1);
    if (!kinds.contains(kind) || !isValidContentId(contentId)) return null;
    return (source: source, kind: kind, contentId: contentId);
  }

  /// Whether a content key refers to a locally imported book. Malformed keys
  /// are treated as local so a backup never exports data it cannot account for.
  static bool isLocalContentKey(String key) {
    final parsed = parseContentKey(key);
    if (parsed == null) return true;
    return localContentIdPattern.hasMatch(parsed.contentId);
  }
}

/// Convenience wrappers for widget code, which must not depend on services.
String shelfContentKeyOf(MediaItem item) => ShelfIdentity.contentKeyOf(item);

String shelfStorageKeyOf(MediaItem item) => ShelfIdentity.storageKeyOf(item);
