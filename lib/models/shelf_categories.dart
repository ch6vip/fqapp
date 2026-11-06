// 书架分类（全部 / 未分类 / 作者自动分类 / 具名分组）的纯函数与匹配接口。
//
// 作者分类的语义逐字移植自 Wenku8_Flutter (revision ebcd7f1)
// `local_library_preferences.dart` 的 `authorName` / `authorCategory` /
// `categoryAuthor` / `matchesCategory`。fqapp 的差异：
// - 分组 id 由 `ShelfGroupStore` 生成，这里只做形状校验；
// - 分类匹配以源限定 contentKey（`ShelfIdentity.contentKeyOf`）为准，
//   不存在"作品数字 id"这一层。
//
// Mechanical substitutions: `Novel.book.id` -> contentKey; `LocalLibraryPreferences`
// fields -> pure functions. No persistence logic lives here.
library;

/// The three built-in categories and the author-category prefix.
abstract final class ShelfCategory {
  static const String all = '_all';
  static const String unfiled = '_unfiled';
  static const String authorPrefix = '_author:';
  static const String unknownAuthor = '未知作者';
}

final RegExp _whitespace = RegExp(r'\s+');
final RegExp _groupPattern = RegExp(r'^g[0-9a-z]+-[0-9a-z]+$');

/// Normalizes an author for display and category identity: trim, collapse
/// whitespace, and map the placeholder used by imported books to 未知作者.
String shelfAuthorName(String value) {
  final name = value.trim().replaceAll(_whitespace, ' ');
  return name.isEmpty || name == '本地书籍' ? ShelfCategory.unknownAuthor : name;
}

/// `_author:<percent-encoded name>`; the encoding survives any author string.
String shelfAuthorCategory(String author) =>
    '${ShelfCategory.authorPrefix}${Uri.encodeComponent(shelfAuthorName(author))}';

/// The decoded author of an author category, or null when [category] is not a
/// well-formed author category.
String? shelfCategoryAuthor(String category) {
  if (!category.startsWith(ShelfCategory.authorPrefix)) return null;
  try {
    final name = Uri.decodeComponent(
      category.substring(ShelfCategory.authorPrefix.length),
    );
    return name.isEmpty ? null : name;
  } on FormatException {
    return null;
  } on ArgumentError {
    // `Uri.decodeComponent` reports malformed escapes as ArgumentError on
    // some SDKs and FormatException on others; both mean "not a category".
    return null;
  }
}

/// Category shape accepted by persistence and assignment: `_all`, `_unfiled`,
/// a decodable author category, or a generated group id, all bounded to 80
/// characters. Whether a group id still exists is the store's concern.
bool isShelfCategoryWellFormed(String value) {
  if (value == ShelfCategory.all || value == ShelfCategory.unfiled) return true;
  if (value.isEmpty || value.length > 80) return false;
  if (value.startsWith(ShelfCategory.authorPrefix)) {
    return shelfCategoryAuthor(value) != null;
  }
  return _groupPattern.hasMatch(value);
}

/// Matches a shelf row against a selected category without materializing the
/// whole group map for every row.
abstract interface class ShelfCategoryMatcher {
  bool matchesKey(String contentKey, String author, String category);
}
