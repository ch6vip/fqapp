import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/author_profile.dart';

/// Shapes recorded from a live `/api/v1/authors/{id}` response.
Map<String, dynamic> _payload({
  String name = '七彩虹桥的吕师傅',
  String description = '人生是旷野呀朋友！',
  List<dynamic>? works,
}) => {
  'code': 0,
  'data': {
    'user_id': '1988336383174046',
    'user_name': name,
    'user_avatar': 'https://example.test/avatar.heic',
    'description': description,
    'author_desc': '',
    'fans_num': 20905,
    'author_book_num': 5,
    'can_follow': true,
    'user_title_infos': [
      {
        'title': 'author_level_5',
        'title_text': '作家Lv.5',
        'is_author_title': true,
      },
    ],
    'author_book_info':
        works ??
        [
          {
            'book_id': '7676082357077543960',
            'book_name': '发现青梅真香且喜欢我，我重生了',
            'author': '七彩虹桥的吕师傅',
            'thumb_url': 'https://example.test/a.jpg',
            'abstract': '【轻松校园，多女主】',
            'category': '都市脑洞,重生',
            'creation_status': 1,
            'word_number': 115815,
            'read_count': 4747,
          },
          {
            'book_id': '7491705400958405694',
            'book_name': '霸凌？穿书黄毛！学霸也是霸！',
            'author': '七彩虹桥的吕师傅',
            'thumb_url': 'https://example.test/b.jpg',
            'abstract': '【穿书】',
            'category': '都市脑洞',
            'creation_status': 0,
            'word_number': 1328318,
            'read_count': 74966,
          },
        ],
  },
};

void main() {
  group('AuthorProfile', () {
    test('reads the identity, bio and level badge', () {
      final author = AuthorProfile.fromPayload(_payload());
      expect(author.id, '1988336383174046');
      expect(author.name, '七彩虹桥的吕师傅');
      expect(author.description, '人生是旷野呀朋友！');
      expect(author.level, '作家Lv.5');
      expect(author.followerCount, 20905);
      expect(author.workCount, 5);
    });

    test('falls back to author_desc when description is empty', () {
      final author = AuthorProfile.fromPayload({
        'code': 0,
        'data': {'user_name': 'x', 'description': '', 'author_desc': '备用简介'},
      });
      expect(author.description, '备用简介');
    });

    test('formats the follower count the way the rest of the app does', () {
      final author = AuthorProfile.fromPayload(_payload());
      expect(author.followerLabel, '2.1万粉丝');
      expect(author.workCountLabel, '5 部作品');
    });

    test('a zero follower count produces no label', () {
      final author = AuthorProfile.fromPayload({
        'code': 0,
        'data': {'user_name': 'x', 'fans_num': 0},
      });
      expect(author.followerLabel, '');
      expect(author.workCountLabel, '');
    });

    test('reads the works catalogue', () {
      final author = AuthorProfile.fromPayload(_payload());
      expect(author.works, hasLength(2));
      final first = author.works.first;
      expect(first.id, '7676082357077543960');
      expect(first.title, '发现青梅真香且喜欢我，我重生了');
      expect(first.cover, 'https://example.test/a.jpg');
      // Only the primary category is shown, not the whole comma list.
      expect(first.category, '都市脑洞');
      expect(first.finished, isFalse);
      expect(first.statusLabel, '连载中');
    });

    test('the finished flag follows creation_status', () {
      final author = AuthorProfile.fromPayload(_payload());
      expect(author.works[1].finished, isTrue);
      expect(author.works[1].statusLabel, '完结');
    });

    test('the meta line joins category, status and word count', () {
      final author = AuthorProfile.fromPayload(_payload());
      expect(author.works.first.metaLabel, '都市脑洞 · 连载中 · 11.6万字');
      expect(author.works[1].metaLabel, '都市脑洞 · 完结 · 132.8万字');
    });

    test('a work without an id or title is dropped', () {
      final author = AuthorProfile.fromPayload(
        _payload(
          works: [
            {'book_id': '', 'book_name': ''},
            {'book_id': '1', 'book_name': '保留'},
          ],
        ),
      );
      expect(author.works, hasLength(1));
      expect(author.works.single.title, '保留');
    });

    test('a business error yields the empty profile', () {
      final author = AuthorProfile.fromPayload({'code': 100001, 'data': null});
      expect(author.isEmpty, isTrue);
      expect(author.works, isEmpty);
    });

    test('a missing payload yields the empty profile', () {
      expect(AuthorProfile.fromPayload({'code': 0}).isEmpty, isTrue);
      expect(AuthorProfile.empty.isEmpty, isTrue);
      expect(AuthorProfile.empty.followerLabel, '');
    });

    test('a profile without a level badge is fine', () {
      final author = AuthorProfile.fromPayload({
        'code': 0,
        'data': {'user_name': 'x', 'user_title_infos': []},
      });
      expect(author.level, '');
      expect(author.name, 'x');
    });
  });
}
