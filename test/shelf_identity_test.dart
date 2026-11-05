import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/shelf_categories.dart';
import 'package:fqapp/models/shelf_identity.dart';

void main() {
  group('ShelfIdentity', () {
    test(
      'fanqie keys stay byte-identical to the existing storage contract',
      () {
        expect(ShelfIdentity.contentKeyFor('book', '123'), 'book:123');
        expect(ShelfIdentity.storageKeyFor('book', '123'), 'shelf_v1:book:123');
        expect(
          ShelfIdentity.contentKeyFor('book', '123', source: ''),
          'book:123',
        );
        expect(
          ShelfIdentity.contentKeyFor('book', '123', source: 'fanqie'),
          'book:123',
        );
      },
    );

    test('non-fanqie sources are qualified and unknown sources fall back', () {
      expect(
        ShelfIdentity.contentKeyFor('book', '123', source: 'shuqi'),
        'shuqi/book:123',
      );
      expect(
        ShelfIdentity.storageKeyFor('book', '123', source: 'shuqi'),
        'shelf_v1:shuqi/book:123',
      );
      // Empty / malformed sources normalize to the default and omit the
      // prefix, so a bad caller cannot create an orphan key family.
      expect(
        ShelfIdentity.contentKeyFor('book', '123', source: 'Shuqi!'),
        'book:123',
      );
      expect(
        ShelfIdentity.contentKeyFor('book', '123', source: ''),
        'book:123',
      );
    });

    test('seriesId wins over id and local ids keep their shape', () {
      final episode = _item(id: 'episode-7', kind: 'video', seriesId: '9');
      expect(ShelfIdentity.contentKeyOf(episode), 'video:9');
      expect(ShelfIdentity.storageKeyOf(episode), 'shelf_v1:video:9');

      final local = _item(id: 'local_1700000000000_ab12');
      expect(
        ShelfIdentity.contentKeyOf(local),
        'book:local_1700000000000_ab12',
      );
      expect(
        ShelfIdentity.isLocalContentKey('book:local_1700000000000_ab12'),
        isTrue,
      );
      expect(
        ShelfIdentity.isLocalContentKey('shuqi/book:local_1700000000000_ab12'),
        isTrue,
      );
      expect(ShelfIdentity.isLocalContentKey('book:123'), isFalse);
    });

    test('content keys round-trip through parse', () {
      expect(ShelfIdentity.parseContentKey('book:123'), (
        source: 'fanqie',
        kind: 'book',
        contentId: '123',
      ));
      expect(ShelfIdentity.parseContentKey('shuqi/book:123'), (
        source: 'shuqi',
        kind: 'book',
        contentId: '123',
      ));
      expect(ShelfIdentity.parseContentKey('audio/audio:abc-1'), (
        source: 'audio',
        kind: 'audio',
        contentId: 'abc-1',
      ));
    });

    test('malformed keys parse to null', () {
      for (final key in [
        '',
        'book',
        'book:',
        ':123',
        'book:has space',
        'unknownkind:1',
        'shuqi/',
        'a/b/book:1',
        'book:${'x' * 129}',
      ]) {
        expect(
          ShelfIdentity.parseContentKey(key),
          isNull,
          reason: 'expected "$key" to be rejected',
        );
      }
    });

    test('unparseable content keys are treated as local for backups', () {
      expect(ShelfIdentity.isLocalContentKey('not-a-key'), isTrue);
      expect(ShelfIdentity.isLocalContentKey('book:123'), isFalse);
    });

    test('source and content id validators match the documented ranges', () {
      expect(ShelfIdentity.isValidSource('shuqi'), isTrue);
      expect(ShelfIdentity.isValidSource('a'), isTrue);
      expect(ShelfIdentity.isValidSource('a_b-c'), isTrue);
      expect(ShelfIdentity.isValidSource(''), isFalse);
      expect(ShelfIdentity.isValidSource('1abc'), isFalse);
      expect(ShelfIdentity.isValidSource('a' * 33), isFalse);
      expect(ShelfIdentity.isValidContentId('abc-123_X'), isTrue);
      expect(ShelfIdentity.isValidContentId(''), isFalse);
      expect(ShelfIdentity.isValidContentId('a b'), isFalse);
      expect(ShelfIdentity.isValidContentId('x' * 128), isTrue);
      expect(ShelfIdentity.isValidContentId('x' * 129), isFalse);
    });

    test('widget helpers delegate to the same key', () {
      final item = _item(id: '123', source: 'shuqi');
      expect(shelfContentKeyOf(item), 'shuqi/book:123');
      expect(shelfStorageKeyOf(item), 'shelf_v1:shuqi/book:123');
    });
  });

  group('ShelfCategory', () {
    test('author names normalize whitespace and the local placeholder', () {
      expect(shelfAuthorName('  张  三 '), '张 三');
      expect(shelfAuthorName(''), ShelfCategory.unknownAuthor);
      expect(shelfAuthorName('   '), ShelfCategory.unknownAuthor);
      expect(shelfAuthorName('本地书籍'), ShelfCategory.unknownAuthor);
    });

    test('author categories round-trip, including non-ASCII names', () {
      final category = shelfAuthorCategory('张 三');
      expect(category, '${ShelfCategory.authorPrefix}%E5%BC%A0%20%E4%B8%89');
      expect(shelfCategoryAuthor(category), '张 三');
      expect(shelfCategoryAuthor(ShelfCategory.all), isNull);
      expect(shelfCategoryAuthor('${ShelfCategory.authorPrefix}%ZZ'), isNull);
    });

    test('category shape validation accepts built-ins, authors and ids', () {
      expect(isShelfCategoryWellFormed(ShelfCategory.all), isTrue);
      expect(isShelfCategoryWellFormed(ShelfCategory.unfiled), isTrue);
      expect(isShelfCategoryWellFormed(shelfAuthorCategory('张三')), isTrue);
      expect(isShelfCategoryWellFormed('g1a2-x9y8'), isTrue);
      expect(isShelfCategoryWellFormed(''), isFalse);
      expect(isShelfCategoryWellFormed('g1a2'), isFalse);
      expect(isShelfCategoryWellFormed('G1A2-X'), isFalse);
      expect(isShelfCategoryWellFormed('g' * 81), isFalse);
      expect(
        isShelfCategoryWellFormed('${ShelfCategory.authorPrefix}%ZZ'),
        isFalse,
      );
    });
  });
}

MediaItem _item({
  required String id,
  String kind = 'book',
  String? seriesId,
  String source = 'fanqie',
}) => MediaItem(
  id: id,
  title: 'T-$id',
  cover: '',
  author: 'A',
  badge: '',
  ep: '',
  kind: kind,
  seriesId: seriesId,
  source: source,
);
