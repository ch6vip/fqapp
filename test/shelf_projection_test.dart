import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/shelf_categories.dart';
import 'package:fqapp/models/shelf_view_state.dart';
import 'package:fqapp/services/shelf_projection.dart';

void main() {
  group('ShelfProjection.compare', () {
    test('recentRead is readTime desc, then addedAt desc, then key asc', () {
      final older = _row('book:b', readTime: 100, addedAt: 10);
      final newer = _row('book:a', readTime: 200, addedAt: 5);
      final unread = _row('book:c', readTime: null, addedAt: 99);
      final zero = _row('book:d', readTime: 0, addedAt: 98);

      final sorted = [older, newer, unread, zero]
        ..sort((a, b) => ShelfProjection.compare(ShelfSort.recentRead, a, b));
      expect(sorted.map((row) => row.contentKey), [
        'book:a',
        'book:b',
        'book:c',
        'book:d',
      ]);
    });

    test('equal readTime falls back to addedAt then contentKey', () {
      final a = _row('book:a', readTime: 100, addedAt: 10);
      final b = _row('book:b', readTime: 100, addedAt: 20);
      final c = _row('book:c', readTime: 100, addedAt: 10);

      final sorted = [c, b, a]
        ..sort((x, y) => ShelfProjection.compare(ShelfSort.recentRead, x, y));
      expect(sorted.map((row) => row.contentKey), [
        'book:b',
        'book:a',
        'book:c',
      ]);
    });

    test('recentAdded and title share the contentKey tie-break', () {
      final first = _row('book:b', addedAt: 20, title: '同');
      final second = _row('book:a', addedAt: 20, title: '同');
      final older = _row('book:z', addedAt: 10, title: '同');

      final byAdded = [older, first, second]
        ..sort((a, b) => ShelfProjection.compare(ShelfSort.recentAdded, a, b));
      expect(byAdded.map((row) => row.contentKey), [
        'book:a',
        'book:b',
        'book:z',
      ]);

      final byTitle = [_row('book:b', title: '乙'), _row('book:a', title: '甲')]
        ..sort((a, b) => ShelfProjection.compare(ShelfSort.title, a, b));
      // UTF-16 order, not pinyin: 乙 (U+4E59) sorts before 甲 (U+7532).
      expect(byTitle.map((row) => row.contentKey), ['book:b', 'book:a']);
    });
  });

  group('ShelfProjection reading filter', () {
    test('unread means no readTime at all', () {
      final unread = _row('book:a', readTime: null);
      final zero = _row('book:b', readTime: 0);
      final read = _row('book:c', readTime: 100);
      expect(
        ShelfProjection.matchesReading(ShelfReadingFilter.unread, unread),
        isTrue,
      );
      expect(
        ShelfProjection.matchesReading(ShelfReadingFilter.unread, zero),
        isFalse,
      );
      expect(
        ShelfProjection.matchesReading(ShelfReadingFilter.unread, read),
        isFalse,
      );
    });

    test('reading is started but not finished; finished follows the flag', () {
      final reading = _row('book:a', readTime: 1);
      final finished = _row('book:b', readTime: 1, finished: true);
      expect(
        ShelfProjection.matchesReading(ShelfReadingFilter.reading, reading),
        isTrue,
      );
      expect(
        ShelfProjection.matchesReading(ShelfReadingFilter.reading, finished),
        isFalse,
      );
      expect(
        ShelfProjection.matchesReading(ShelfReadingFilter.finished, finished),
        isTrue,
      );
      expect(
        ShelfProjection.matchesReading(ShelfReadingFilter.all, reading),
        isTrue,
      );
    });
  });

  group('ShelfProjection source filter', () {
    test('local is derived from the source-qualified key', () {
      final local = _row('book:local_1700000000000_ab');
      final online = _row('book:123');
      expect(
        ShelfProjection.matchesSource(
          ShelfSourceFilter.local,
          local,
          const ShelfFilterFacts(),
        ),
        isTrue,
      );
      expect(
        ShelfProjection.matchesSource(
          ShelfSourceFilter.online,
          local,
          const ShelfFilterFacts(),
        ),
        isFalse,
      );
      expect(
        ShelfProjection.matchesSource(
          ShelfSourceFilter.online,
          online,
          const ShelfFilterFacts(),
        ),
        isTrue,
      );
    });

    test('cached waits for the scan, then requires fanqie book rows', () {
      final fanqie = _row('book:123');
      final shuqi = _row('shuqi/book:123', source: 'shuqi');
      final manga = _row('manga:123', kind: 'manga');
      const facts = ShelfFilterFacts(
        cachedContentKeys: {'book:123'},
        cacheScanComplete: true,
      );
      expect(
        ShelfProjection.matchesSource(ShelfSourceFilter.cached, fanqie, facts),
        isTrue,
      );
      expect(
        ShelfProjection.matchesSource(ShelfSourceFilter.cached, shuqi, facts),
        isFalse,
        reason: 'same numeric id from another source must not match',
      );
      expect(
        ShelfProjection.matchesSource(ShelfSourceFilter.cached, manga, facts),
        isFalse,
      );
      expect(
        ShelfProjection.matchesSource(
          ShelfSourceFilter.cached,
          fanqie,
          const ShelfFilterFacts(cachedContentKeys: {'book:123'}),
        ),
        isFalse,
        reason: 'an incomplete scan must not claim "not cached"',
      );
      expect(
        ShelfProjection.matchesSource(
          ShelfSourceFilter.cached,
          _row('book:local_1_ab'),
          const ShelfFilterFacts(
            cachedContentKeys: {'book:local_1_ab'},
            cacheScanComplete: true,
          ),
        ),
        isFalse,
      );
    });
  });

  group('ShelfProjection.apply', () {
    test('filters by category, reading and source, then sorts', () {
      final rows = [
        _row('book:a', readTime: 100, addedAt: 1, author: '张三'),
        _row('book:b', readTime: null, addedAt: 2, author: '张三'),
        _row('shuqi/book:c', readTime: 300, addedAt: 3, author: '李四'),
      ];
      final result = ShelfProjection.apply(
        rows,
        sort: ShelfSort.recentRead,
        reading: ShelfReadingFilter.all,
        source: ShelfSourceFilter.online,
        category: shelfAuthorCategory('张三'),
        facts: const ShelfFilterFacts(),
        categories: _AuthorMatcher(_AuthorMatcher.byAuthor),
      );
      expect(result.map((row) => row.contentKey), ['book:a', 'book:b']);
    });

    test('an empty input yields an empty list before any matcher work', () {
      final result = ShelfProjection.apply<_Row>(
        const [],
        sort: ShelfSort.title,
        reading: ShelfReadingFilter.all,
        source: ShelfSourceFilter.all,
        category: ShelfCategory.all,
        facts: const ShelfFilterFacts(),
        categories: _AuthorMatcher(_AuthorMatcher.byAuthor),
      );
      expect(result, isEmpty);
    });
  });
}

class _AuthorMatcher implements ShelfCategoryMatcher {
  _AuthorMatcher(this._match);

  final bool Function(String contentKey, String author, String category) _match;

  static bool byAuthor(String contentKey, String author, String category) {
    final selected = shelfCategoryAuthor(category);
    if (selected != null) return shelfAuthorName(author) == selected;
    return category == ShelfCategory.all;
  }

  @override
  bool matchesKey(String contentKey, String author, String category) =>
      _match(contentKey, author, category);
}

class _Row implements ShelfProjectable {
  _Row(
    this.contentKey, {
    this.kind = 'book',
    this.source = 'fanqie',
    this.author = '',
    this.title = '',
    this.readTime,
    this.addedAt = 0,
    this.finished = false,
  }) : contentId = contentKey.split(':').last;

  @override
  final String contentKey;
  @override
  final String contentId;
  @override
  final String kind;
  @override
  final String source;
  @override
  final String author;
  @override
  final String title;
  @override
  final int? readTime;
  @override
  final int addedAt;
  @override
  final bool finished;
}

_Row _row(
  String contentKey, {
  String kind = 'book',
  String source = 'fanqie',
  String author = '',
  String title = '',
  int? readTime,
  int addedAt = 0,
  bool finished = false,
}) => _Row(
  contentKey,
  kind: kind,
  source: source,
  author: author,
  title: title,
  readTime: readTime,
  addedAt: addedAt,
  finished: finished,
);
