// NOTE(U4): this is a duplicate of the frozen U1 implementation
// (`lib/models/shelf_identity.dart`, design §2.1). It is added on the
// shelf/u4-carousel branch only so `ArchiveShelfEntry.identity` compiles before
// U1 lands. Integration must keep U1's file; delete this copy then. The public
// API is byte-for-byte the frozen signature.

import 'media_item.dart';

/// The single source of truth for shelf/history identity.
///
/// `contentKey` is `[source/]kind:<seriesId ?? id>`, where the `source/`
/// prefix is omitted for the default `fanqie` source. `storageKey` is
/// `shelf_v1:` + `contentKey`.
abstract final class ShelfIdentity {
  static const Set<String> kinds = {'book', 'audio', 'manga', 'video', 'manju'};
  static final RegExp sourcePattern = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');
  static final RegExp contentIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  static bool isValidSource(String source) => sourcePattern.hasMatch(source);

  static bool isValidContentId(String id) => contentIdPattern.hasMatch(id);

  static String normalizeSource(String source) =>
      isValidSource(source) ? source : 'fanqie';

  /// `[source/]kind:<seriesId ?? id>`；source 为空或 fanqie 时省略前缀。
  static String contentKeyFor(
    String kind,
    String contentId, {
    String source = 'fanqie',
  }) {
    final normalized = normalizeSource(source);
    final prefix = normalized == 'fanqie' ? '' : '$normalized/';
    return '$prefix$kind:$contentId';
  }

  static String contentKeyOf(MediaItem item) =>
      contentKeyFor(item.kind, item.seriesId ?? item.id, source: item.source);

  /// `shelf_v1:` + contentKey，即 ShelfStore 的存储键。
  static String storageKeyFor(
    String kind,
    String contentId, {
    String source = 'fanqie',
  }) => 'shelf_v1:${contentKeyFor(kind, contentId, source: source)}';

  static String storageKeyOf(MediaItem item) =>
      storageKeyFor(item.kind, item.seriesId ?? item.id, source: item.source);

  /// 解析失败返回 null。
  static ({String source, String kind, String contentId})? parseContentKey(
    String key,
  ) {
    final colon = key.indexOf(':');
    if (colon <= 0 || colon == key.length - 1) return null;
    var prefix = key.substring(0, colon);
    final contentId = key.substring(colon + 1);
    var source = 'fanqie';
    final slash = prefix.indexOf('/');
    if (slash >= 0) {
      source = prefix.substring(0, slash);
      prefix = prefix.substring(slash + 1);
      if (!isValidSource(source)) return null;
    }
    if (!kinds.contains(prefix) || !isValidContentId(contentId)) return null;
    return (source: source, kind: prefix, contentId: contentId);
  }

  /// 解析失败也按 local 处理（备份时排除）。
  static bool isLocalContentKey(String key) {
    final parsed = parseContentKey(key);
    if (parsed == null) return true;
    return parsed.contentId.startsWith('local_');
  }
}

/// 顶层便捷函数，供 widgets 层直接使用，避免 widgets -> services 依赖。
String shelfContentKeyOf(MediaItem item) => ShelfIdentity.contentKeyOf(item);

String shelfStorageKeyOf(MediaItem item) => ShelfIdentity.storageKeyOf(item);
