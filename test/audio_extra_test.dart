import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/audio_extra.dart';

void main() {
  group('AudioToneSet', () {
    /// `/api/v1/books/{id}/tones` uses lowercase keys, unlike the PascalCase
    /// ToneInfo RPC model, and narrators identify themselves with `abook_id`.
    final payload = {
      'data': {
        'tts_tones': [
          {
            'id': 90,
            'title': '多角色对话配乐版',
            'description': '声临其境',
            'badge': '升级',
            'is_multi_tone': true,
            'tone_gender': 0,
          },
          {
            'id': 74,
            'title': '成熟大叔音升级版',
            'description': '超自然',
            'badge': '',
            'tone_gender': 1,
          },
        ],
        'audio_tones': [
          {'abook_id': 7521039556003499, 'title': '主播：水丘声工厂'},
        ],
        'offline_tts_tones': [
          {'id': 118, 'title': '成熟大叔离线版', 'description': '经典'},
        ],
      },
    };

    test('reads named 智能朗读 voices', () {
      final tones = AudioToneSet.fromPayload(payload);
      expect(tones.ttsTones, hasLength(2));
      expect(tones.ttsTones.first.title, '多角色对话配乐版');
      expect(tones.ttsTones.first.description, '声临其境');
      expect(tones.ttsTones.first.badge, '升级');
      expect(tones.ttsTones.first.isMultiTone, isTrue);
      expect(tones.ttsTones[1].isMultiTone, isFalse);
      expect(tones.ttsTones[1].gender, 1);
    });

    test('reads 真人讲书 narrators from abook_id', () {
      final tones = AudioToneSet.fromPayload(payload);
      expect(tones.narratorTones, hasLength(1));
      expect(tones.narratorTones.single.id, '7521039556003499');
      expect(tones.narratorTones.single.title, '主播：水丘声工厂');
    });

    test('recovers an exact narrator id from book_infos', () {
      final tones = AudioToneSet.fromPayload({
        'data': {
          'audio_tones': [
            {'abook_id': 7239243941252599000, 'title': '主播：水丘声工厂'},
          ],
          'book_infos': [
            {
              'book_id': '7239243941252598845',
              'author': '主播：水丘声工厂',
              'book_type': 1,
            },
            // The upstream payload repeats the same audio book.
            {
              'book_id': '7239243941252598845',
              'author': '主播：水丘声工厂',
              'book_type': 1,
            },
            {
              'book_id': '7180279419959774247',
              'author': '钢铁洪流',
              'book_type': 0,
            },
          ],
        },
      });
      expect(tones.narratorTones, hasLength(1));
      expect(tones.narratorTones.single.id, '7239243941252598845');
      expect(tones.narratorTones.single.title, '主播：水丘声工厂');
    });

    test('prefers an explicit string id when upstream provides one', () {
      final tones = AudioToneSet.fromPayload({
        'data': {
          'audio_tones': [
            {
              'abook_id': 7239243941252599000,
              'abook_id_str': '7239243941252598845',
              'title': '主播：水丘声工厂',
            },
          ],
        },
      });
      expect(tones.narratorTones.single.id, '7239243941252598845');
    });

    test('drops a unique numeric candidate whose narrator does not match', () {
      final tones = AudioToneSet.fromPayload({
        'data': {
          'audio_tones': [
            {'abook_id': 7239243941252599000, 'title': '主播：真实主播'},
          ],
          'book_infos': [
            {
              'book_id': '7239243941252598845',
              'author': '完全不同',
              'book_type': 1,
            },
          ],
        },
      });
      expect(tones.narratorTones, isEmpty);
    });

    test('drops a name match that does not share the rounded value', () {
      final tones = AudioToneSet.fromPayload({
        'data': {
          'audio_tones': [
            {'abook_id': 7239243941252599000, 'title': '主播：水丘声工厂'},
          ],
          'book_infos': [
            {
              'book_id': '7651059634186243134',
              'author': '主播：水丘声工厂',
              'book_type': 1,
            },
          ],
        },
      });
      expect(tones.narratorTones, isEmpty);
    });

    test('narrows a shared double bucket by name and string book_type', () {
      final tones = AudioToneSet.fromPayload({
        'data': {
          'audio_tones': [
            {'abook_id': 7239243941252599000, 'title': '主播：甲'},
          ],
          'book_infos': [
            {
              'book_id': '7239243941252598845',
              'author': '主播：甲',
              'book_type': '1',
            },
            {
              'book_id': '7239243941252598846',
              'author': '主播：乙',
              'book_type': '1',
            },
          ],
        },
      });
      expect(tones.narratorTones.single.id, '7239243941252598845');
    });

    test('drops an unresolvable rounded narrator id', () {
      final tones = AudioToneSet.fromPayload({
        'data': {
          'audio_tones': [
            {'abook_id': 7521039556003499000, 'title': '主播：水丘声工厂'},
          ],
        },
      });
      expect(tones.narratorTones, isEmpty);
    });

    test('drops a narrator whose exact id is ambiguous', () {
      final tones = AudioToneSet.fromPayload({
        'data': {
          'audio_tones': [
            {'abook_id': 7239243941252599000, 'title': '主播：水丘声工厂'},
          ],
          'book_infos': [
            {'book_id': '7239243941252598845', 'author': '甲', 'book_type': 1},
            {'book_id': '7239243941252598846', 'author': '乙', 'book_type': 1},
          ],
        },
      });
      expect(tones.narratorTones, isEmpty);
    });

    test('reads offline voices', () {
      expect(
        AudioToneSet.fromPayload(payload).offlineTones.single.title,
        '成熟大叔离线版',
      );
    });

    test('recommends the first multi-role voice', () {
      expect(AudioToneSet.fromPayload(payload).recommended?.title, '多角色对话配乐版');
    });

    test('degrades to an empty set', () {
      expect(AudioToneSet.fromPayload(const {}).isEmpty, isTrue);
      expect(AudioToneSet.fromPayload(const {}).recommended, isNull);
      expect(
        AudioToneSet.fromPayload({
          'data': {
            'tts_tones': [
              null,
              'x',
              {'id': '', 'title': ''},
            ],
          },
        }).ttsTones,
        isEmpty,
      );
    });
  });

  group('SubtitleTrack', () {
    /// The backend returns `data.speech_text` as `[startMs,?]<a,b,c>text` lines.
    const speech =
        '[0,0]<0,0,0>第一章合着，我是出生头子\n'
        '[3025,0]<3025,0,0>对不起\n'
        '[4400,0]<4400,0,0>老子是兔子啊，特么全是素\n'
        '[7555,0]<7555,0,0>耳边传来稀奇古怪的声音，张晨缓缓睁开眼\n';

    test('parses the offset and text of every cue', () {
      final track = SubtitleTrack.parse(speech);
      expect(track.cues, hasLength(4));
      expect(track.cues.first.startMs, 0);
      expect(track.cues[1].startMs, 3025);
      expect(track.cues[1].text, '对不起');
      expect(track.cues.last.text, '耳边传来稀奇古怪的声音，张晨缓缓睁开眼');
    });

    test('locates the active cue by position', () {
      final track = SubtitleTrack.parse(speech);
      expect(track.cueAt(Duration.zero)?.text, '第一章合着，我是出生头子');
      expect(track.cueAt(const Duration(milliseconds: 3025))?.text, '对不起');
      expect(
        track.cueAt(const Duration(milliseconds: 7000))?.text,
        '老子是兔子啊，特么全是素',
      );
      expect(
        track.cueAt(const Duration(seconds: 30))?.text,
        '耳边传来稀奇古怪的声音，张晨缓缓睁开眼',
      );
    });

    test('reports the current and next line for the two-line display', () {
      final track = SubtitleTrack.parse(speech);
      final (current, next) = track.windowAt(
        const Duration(milliseconds: 4400),
      );
      expect(current?.text, '老子是兔子啊，特么全是素');
      expect(next?.text, '耳边传来稀奇古怪的声音，张晨缓缓睁开眼');
    });

    test(
      'has no current line before the first cue but still shows a next one',
      () {
        final track = SubtitleTrack.parse('[5000,0]<5000,0,0>稍后');
        final (current, next) = track.windowAt(Duration.zero);
        expect(current, isNull);
        expect(next?.text, '稍后');
      },
    );

    test('ends cleanly after the final cue', () {
      final track = SubtitleTrack.parse(speech);
      final (current, next) = track.windowAt(const Duration(hours: 1));
      expect(current?.text, '耳边传来稀奇古怪的声音，张晨缓缓睁开眼');
      expect(next, isNull);
    });

    test('ignores unparseable lines and empty input', () {
      final track = SubtitleTrack.parse('garbage\n\n[100,0]<100,0,0>好');
      expect(track.cues, hasLength(1));
      expect(track.cues.single.text, '好');
      expect(SubtitleTrack.parse('').isEmpty, isTrue);
      expect(SubtitleTrack.parse('no available speech text').isEmpty, isTrue);
      expect(SubtitleTrack.fromPayload(const {}).isEmpty, isTrue);
    });

    test('sorts cues that arrive out of order', () {
      final track = SubtitleTrack.parse('[900,0]<900,0,0>二\n[100,0]<100,0,0>一');
      expect(track.cues.map((cue) => cue.text).toList(), ['一', '二']);
    });

    test('reads speech_text from the envelope', () {
      final track = SubtitleTrack.fromPayload({
        'code': 0,
        'data': {'speech_text': speech},
      });
      expect(track.cues, hasLength(4));
    });
  });

  group('RelatedWork', () {
    final payload = {
      'data': {
        'cell_data': [
          {
            'cell_name': '关联作品',
            'book_data': [
              {
                'book_id': '7521039556003499070',
                'book_name': '穿书黄毛？！我真没想当渣男啊！',
                'thumb_url': 'https://example.test/b.jpg',
              },
            ],
            'video_data': [
              {'series_id': '7599595550698114073', 'title': '黄毛穿书，学霸也是霸'},
            ],
          },
        ],
      },
    };

    test('labels novels and adaptations separately', () {
      final works = RelatedWork.fromPayload(payload);
      expect(works, hasLength(2));
      expect(works[0].kind, 'book');
      expect(works[0].label, '原著小说');
      expect(works[0].id, '7521039556003499070');
      expect(works[0].title, '穿书黄毛？！我真没想当渣男啊！');
      expect(works[0].cover, 'https://example.test/b.jpg');
      expect(works[1].kind, 'video');
      expect(works[1].label, '改编短剧');
      expect(works[1].id, '7599595550698114073');
    });

    test('degrades to an empty list', () {
      expect(RelatedWork.fromPayload(const {}), isEmpty);
      expect(
        RelatedWork.fromPayload({
          'data': {'cell_data': []},
        }),
        isEmpty,
      );
      expect(
        RelatedWork.fromPayload({
          'data': {
            'cell_data': [
              {
                'book_data': [
                  null,
                  {'book_id': ''},
                ],
              },
            ],
          },
        }),
        isEmpty,
      );
    });

    test('accepts a fallback cover field', () {
      final works = RelatedWork.fromPayload({
        'data': {
          'cell_data': [
            {
              'book_data': [
                {
                  'book_id': '1',
                  'book_name': 'a',
                  'cover_url': 'https://c.test',
                },
              ],
            },
          ],
        },
      });
      expect(works.single.cover, 'https://c.test');
    });
  });
}
