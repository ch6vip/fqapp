import '../models/book_detail.dart' show formatWordCount;
import '../models/media_item.dart';

/// Kind labels shared by the detail page and the search result rows.
///
/// The old `MediaCard` tile lived here too; the author page was its last
/// caller and now renders `HomeMediaCard` like every other grid, so the tile
/// (and its grid delegates) are gone. The two helpers below still drive the
/// detail page's tab label and the search row's length caption, which are
/// outside this change.
const kindLabels = {
  'book': '小说',
  'video': '短剧',
  'manju': '漫剧',
  'manga': '漫画',
  'audio': '听书',
};

/// Compact length caption for a search card: 「共93集」 for dramas/manju,
/// 「216万字」 for novels. Empty when the card carries neither, so callers can
/// drop the segment instead of rendering a dangling separator.
///
/// Search responses ship the length inside the nested card record: novels put
/// `word_number` on `book_data`, dramas put `episode_cnt` on `video_data`.
/// Both are real values in the captured payloads, not guesses — see
/// docs/validation/issue90-search-length-and-score-20261020.md.
String mediaLengthLabel(MediaItem item) {
  switch (item.kind) {
    case 'book':
      final words = formatWordCount(item.wordNumber);
      if (words.isNotEmpty) return words;
    case 'video':
    case 'manju':
      final episodes = int.tryParse(item.ep.trim());
      if (episodes != null && episodes > 0) return '共$episodes集';
  }
  return '';
}
