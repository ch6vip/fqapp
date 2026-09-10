import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/book_detail.dart';

/// Field names and value shapes mirror a live `/api/v1/books/{id}/detail`
/// response, where every numeric value arrives as a string.
void main() {
  Map<String, dynamic> payload({Map<String, dynamic>? overrides}) => {
    'data': {
      'book_id': '7491705400958405694',
      'book_name': '霸凌？穿书黄毛！学霸也是霸！',
      'author': '七彩虹桥的吕师傅',
      'author_id': '2_7195859804600931643',
      'authorize_type': '1',
      'creation_status': '0',
      'word_number': '1328318',
      'serial_count': '592',
      'read_count': '79528',
      'score': '8.9',
      'category': '都市脑洞',
      'tags': '都市脑洞,都市,多女主,穿书,开局,搞笑轻松',
      'sub_info': '8万人在读',
      'thumb_url': 'https://example.test/cover.jpg',
      'abstract': '【日常轻松】正文',
      'author_info': {
        'user_name': '七彩虹桥的吕师傅',
        'user_avatar': 'https://example.test/avatar.jpg',
        'can_follow': true,
        'user_title_infos': [
          {'title': 'author_level_5', 'title_text': '作家Lv.5'},
        ],
      },
      ...?overrides,
    },
  };

  test('reads the string-typed counters and metadata', () {
    final detail = BookDetail.fromPayload(payload());
    expect(detail.bookId, '7491705400958405694');
    expect(detail.title, '霸凌？穿书黄毛！学霸也是霸！');
    expect(detail.creationStatus, 0);
    expect(detail.wordNumber, 1328318);
    expect(detail.serialCount, 592);
    expect(detail.score, '8.9');
    expect(detail.category, '都市脑洞');
    expect(detail.cover, 'https://example.test/cover.jpg');
  });

  test('splits the comma separated tag string', () {
    final detail = BookDetail.fromPayload(payload());
    expect(detail.tags, ['都市脑洞', '都市', '多女主', '穿书', '开局', '搞笑轻松']);
  });

  test('derives the display labels used by the masthead and stats row', () {
    final detail = BookDetail.fromPayload(payload());
    expect(detail.finished, isTrue);
    expect(detail.statusLabel, '完结');
    expect(detail.wordLabel, '132.8万字');
    expect(detail.readLabel, '8万');
    expect(detail.scoreLabel, '8.9');
    expect(detail.scoreValue, 8.9);
    expect(detail.original, isTrue);
    expect(detail.metaParts, ['都市脑洞', '完结', '132.8万字']);
  });

  test('reads the author level badge from user_title_infos', () {
    final detail = BookDetail.fromPayload(payload());
    expect(detail.author.name, '七彩虹桥的吕师傅');
    expect(detail.author.title, '作家Lv.5');
    expect(detail.author.avatar, 'https://example.test/avatar.jpg');
    expect(detail.author.canFollow, isTrue);
  });

  test('falls back to the plain author fields without author_info', () {
    final detail = BookDetail.fromPayload(
      payload(overrides: {'author_info': null}),
    );
    expect(detail.author.name, '七彩虹桥的吕师傅');
    expect(detail.author.id, '2_7195859804600931643');
    expect(detail.author.title, '');
  });

  test('treats a serializing book as unfinished', () {
    final detail = BookDetail.fromPayload(
      payload(overrides: {'creation_status': '1'}),
    );
    expect(detail.finished, isFalse);
    expect(detail.statusLabel, '连载中');
  });

  test('ignores an out-of-range rating', () {
    expect(
      BookDetail.fromPayload(payload(overrides: {'score': '0'})).scoreValue,
      isNull,
    );
    expect(
      BookDetail.fromPayload(payload(overrides: {'score': ''})).scoreLabel,
      '',
    );
  });

  test('uses the first tag as the category when category is absent', () {
    final detail = BookDetail.fromPayload(payload(overrides: {'category': ''}));
    expect(detail.category, '都市脑洞');
  });

  test('falls back to sub_info when there is no raw read count', () {
    final detail = BookDetail.fromPayload(
      payload(overrides: {'read_count': ''}),
    );
    expect(detail.readLabel, '8万人在读');
  });

  test('prefers the detail cover over the list thumbnail', () {
    final detail = BookDetail.fromPayload(
      payload(overrides: {'detail_page_thumb_url': 'https://x.test/big.jpg'}),
    );
    expect(detail.cover, 'https://x.test/big.jpg');
  });

  test('accepts a doubly nested data wrapper and a bare object', () {
    final nested = BookDetail.fromPayload({'data': payload()});
    expect(nested.title, '霸凌？穿书黄毛！学霸也是霸！');
    final bare = BookDetail.fromPayload(
      payload()['data'] as Map<String, dynamic>,
    );
    expect(bare.title, '霸凌？穿书黄毛！学霸也是霸！');
  });

  test('returns an empty model for a missing payload', () {
    expect(BookDetail.fromPayload(const {}).isEmpty, isTrue);
    expect(BookDetail.fromPayload(const {}).metaParts, isEmpty);
  });

  test('collects the rank list and drops empty entries', () {
    final detail = BookDetail.fromPayload(
      payload(
        overrides: {
          'book_rank_info': [
            {'text': '历史上榜3次', 'url': 'https://x.test/rank'},
            {'text': ''},
          ],
        },
      ),
    );
    expect(detail.rank, hasLength(1));
    expect(detail.rank.first.text, '历史上榜3次');
    expect(detail.rank.first.url, 'https://x.test/rank');
  });

  group('formatWordCount', () {
    test('formats 万 and 亿 and keeps small counts in characters', () {
      expect(formatWordCount(0), '');
      expect(formatWordCount(999), '999字');
      expect(formatWordCount(10000), '1万字');
      expect(formatWordCount(1328318), '132.8万字');
      expect(formatWordCount(130000000), '1.3亿字');
    });
  });

  group('formatCounter', () {
    test('formats raw counters and leaves display strings alone', () {
      expect(formatCounter('79528'), '8万');
      expect(formatCounter('31.4万人'), '31.4万人');
      expect(formatCounter('5252634'), '525.3万');
      expect(formatCounter('9999'), '9999');
      expect(formatCounter(''), '');
    });
  });
}
