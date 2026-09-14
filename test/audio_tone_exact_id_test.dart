import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/audio_extra.dart';

/// Live `/api/v1/books/7579131399576226841/tones` shape (一听入睡).
///
/// `abook_id` is a 19-digit int64 that the backend JSON round-trip has already
/// rounded to ...227000; the exact value only survives in `book_infos.book_id`
/// (a string). The model must recover it, otherwise a hearing-native album has
/// no selectable narrator at all.
Map<String, dynamic> _payload() => {
  'code': 0,
  'data': {
    'audio_tones': [
      {
        'abook_id': 7579131399576227000,
        'icon_url':
            'https://lf3-reading.fqnovelstatic.com/obj/novel-common/img_5.png',
        'title': '主播：佚名',
      },
    ],
    'book_infos': [
      {
        'book_id': '7579131399576226841',
        'author': '佚名',
        'book_name': '一听入睡',
        'book_type': '1',
        'chapter_number': '34',
      },
    ],
    'tts_tones': <Object>[],
  },
};

void main() {
  test('recovers the exact narrator id for a 19-digit abook_id', () {
    final tones = AudioToneSet.fromPayload(_payload());
    expect(tones.ttsTones, isEmpty);
    expect(tones.narratorTones, hasLength(1));
    expect(tones.narratorTones.single.id, '7579131399576226841');
    expect(tones.narratorTones.single.title, '主播：佚名');
  });

  test('prefers an exact abook_id_str when the backend provides one', () {
    final payload = _payload();
    final data = payload['data']! as Map<String, dynamic>;
    ((data['audio_tones']! as List).first as Map)['abook_id_str'] =
        '7579131399576226841';
    final tones = AudioToneSet.fromPayload(payload);
    expect(tones.narratorTones.single.id, '7579131399576226841');
  });
}
