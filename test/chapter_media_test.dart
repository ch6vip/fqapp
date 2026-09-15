import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/chapter_media.dart';

import 'support/audio_play_fixture.dart';

void main() {
  const base = 'http://127.0.0.1:8080';

  test(
    'real audio playback shape yields a plain URL and duration in seconds',
    () {
      final source = parseAudioSource(
        audioPlayFixture(),
        itemId: 'chapter',
        baseUrl: base,
      );
      expect(source.url, 'https://cdn.example/audio.m4a?sign=a%2fb+xyz');
      expect(source.duration, const Duration(milliseconds: 664741));
      expect(source.toneId, '0');
    },
  );

  test('audio playback keeps only the requested chapter and audio media', () {
    for (final payload in [
      audioPlayFixture(itemId: 'different-chapter'),
      audioPlayFixture(mediaType: 'video'),
      {
        'code': 200,
        'data': {'speech_text': '[2060,0]字幕文本'},
      },
    ]) {
      expect(
        () => parseAudioSource(payload, itemId: 'chapter', baseUrl: base),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test(
    'audio playback skips encrypted streams that carry no derived key',
    () {
      final encrypted = <String, dynamic>{
        'main_url': 'https://cdn.example/encrypted.m4a',
        'encrypt_info': {'encrypt': true, 'encryption_method': 'cenc-aes-ctr'},
      };
      final source = parseAudioSource(
        audioPlayFixture(
          streams: [
            encrypted,
            {'backup_url': 'https://cdn.example/plain.m4a'},
          ],
        ),
        itemId: 'chapter',
        toneId: '2',
        baseUrl: base,
      );
      expect(source.url, 'https://cdn.example/plain.m4a');
      expect(source.toneId, '2');
      expect(source.keyHex, isEmpty);
      expect(
        () => parseAudioSource(
          audioPlayFixture(streams: [encrypted]),
          itemId: 'chapter',
          baseUrl: base,
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('encrypted audio plays once the backend derives its content key', () {
    final source = parseAudioSource(
      audioPlayFixture(
        streams: [
          {
            'main_url': 'https://cdn.example/encrypted.m4a',
            'backup_url': 'https://cdn.example/encrypted-backup.m4a',
            'encrypt_info': {
              'encrypt': true,
              'kid': '692e7c06f8818b927094fff40092363a',
              'spade_a': 'l7wZ+1azG8pUsS7NVIcYzWKCGvlWhCrVV5sa1lWsK+NnqC+2tg==',
              'encryption_method': 'cenc-aes-ctr',
              'key_hex': '61826B7ECEB342A9AD4FD9D7556BE625',
            },
          },
        ],
      ),
      itemId: 'chapter',
      baseUrl: base,
    );
    expect(source.url, 'https://cdn.example/encrypted.m4a');
    expect(source.keyHex, '61826b7eceb342a9ad4fd9d7556be625');
  });

  test('an unusable content key still skips the stream', () {
    for (final info in <Map<String, dynamic>>[
      // No key at all.
      {'encrypt': true, 'encryption_method': 'cenc-aes-ctr'},
      // Wrong key length.
      {
        'encrypt': true,
        'encryption_method': 'cenc-aes-ctr',
        'key_hex': '61826b7e',
      },
      // Not hex.
      {
        'encrypt': true,
        'encryption_method': 'cenc-aes-ctr',
        'key_hex': 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz',
      },
      // A scheme the native core does not implement.
      {
        'encrypt': true,
        'encryption_method': 'cbcs',
        'key_hex': '61826b7eceb342a9ad4fd9d7556be625',
      },
    ]) {
      expect(
        () => parseAudioSource(
          audioPlayFixture(
            streams: [
              {
                'main_url': 'https://cdn.example/encrypted.m4a',
                'encrypt_info': info,
              },
            ],
          ),
          itemId: 'chapter',
          baseUrl: base,
        ),
        throwsA(isA<FormatException>()),
        reason: 'encrypt_info $info must not be treated as playable',
      );
    }
  });

  test('a stream without encrypt_info stays plain', () {
    final source = parseAudioSource(
      audioPlayFixture(
        streams: [
          {'main_url': 'https://cdn.example/plain.m4a', 'encrypt_info': null},
        ],
      ),
      itemId: 'chapter',
      baseUrl: base,
    );
    expect(source.url, 'https://cdn.example/plain.m4a');
    expect(source.keyHex, isEmpty);
  });

  test('invalid and overflowing playback durations remain unknown', () {
    for (final duration in [null, -1, 0, 'unknown', 1e308, 1e20]) {
      final source = parseAudioSource(
        audioPlayFixture(duration: duration),
        itemId: 'chapter',
        baseUrl: base,
      );
      expect(source.duration, isNull);
    }
  });

  test('audio playback detects a failure inside the video_info wrapper', () {
    expect(
      () => parseAudioSource(
        {
          'code': 0,
          'message': 'success',
          'video_info': {'code': 403, 'message': 'invalid aid'},
        },
        itemId: 'chapter',
        baseUrl: base,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'invalid aid',
        ),
      ),
    );
  });

  test('audio resolves backend paths and preserves the requested identity', () {
    final source = parseAudioSource(
      {
        'code': 200,
        'data': {
          'audio_url': '/src/chapter.mp3?token=a%2Fb+xyz',
          // No stable duration unit is specified by the backend.
          'duration': 123,
        },
      },
      itemId: '7491705434915488318',
      toneId: '99',
      baseUrl: base,
    );
    expect(source.itemId, '7491705434915488318');
    expect(source.toneId, '99');
    expect(source.url, '$base/src/chapter.mp3?token=a%2Fb+xyz');
    expect(source.duration, isNull);
  });

  test('audio keeps the original bytes of an absolute signed URL', () {
    const signed = 'https://cdn.example/audio.mp3?sign=a%2fb+xyz&x=%7e';
    final source = parseAudioSource(
      {
        'code': 200,
        'data': {
          'code': 0,
          'data': {'audio_url': ' $signed '},
        },
      },
      itemId: 'chapter',
      baseUrl: base,
    );
    expect(source.url, signed);
    expect(source.toneId, '0');
  });

  test('audio does not mistake unrelated URLs for a playable source', () {
    for (final data in [
      <String, dynamic>{},
      {'url': 'https://cdn.example/unrelated'},
      {'audio_url': ''},
      {'audio_url': 123},
      {'audio_url': 'file:///tmp/chapter.mp3'},
      {'audio_url': 'javascript:play()'},
      {'audio_url': 'https://'},
    ]) {
      expect(
        () => parseAudioSource({'data': data}, itemId: 'c', baseUrl: base),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '未获取到音频地址',
          ),
        ),
      );
    }
  });

  test('voice CSV keeps default, trims entries, and removes duplicate IDs', () {
    final voices = parseAudioVoices({
      'code': 200,
      'data': {'tones': ' 99,2, 99 , ,1,2,0 '},
    });
    expect(voices.map((voice) => voice.id), ['0', '99', '2', '1']);
    expect(voices.map((voice) => voice.label), [
      '默认音色',
      '音色 99',
      '音色 2',
      '音色 1',
    ]);
  });

  test('missing or non-CSV voice metadata retains a usable default', () {
    for (final tones in [
      null,
      '',
      ' , ',
      2,
      ['2'],
    ]) {
      final voices = parseAudioVoices({
        'data': {'tones': tones},
      });
      expect(voices.single.id, '0');
      expect(voices.single.label, '默认音色');
    }
  });

  test('comic URL arrays preserve order and repeated pages', () {
    const signed = 'https://cdn.example/a.jpg?sign=a%2fb+xyz';
    final pages = parseComicImages({
      'code': 200,
      'data': {
        'images': [
          '/src/page-b.jpg',
          ' $signed ',
          '/src/page-b.jpg',
          '//cdn.example/page-c.jpg',
          '',
          null,
          123,
          {'unknown_url': '/src/not-a-page.jpg'},
          'data:image/png;base64,AAAA',
        ],
      },
    }, baseUrl: base);
    expect(pages.map((page) => page.url), [
      '$base/src/page-b.jpg',
      signed,
      '$base/src/page-b.jpg',
      'http://cdn.example/page-c.jpg',
    ]);
    for (final page in pages) {
      expect(page.width, isNull);
      expect(page.height, isNull);
      expect(page.headers, isEmpty);
    }
  });

  test('comic arrays take precedence over legacy content markup', () {
    final pages = parseComicImages({
      'data': {
        'images': ['/src/current.jpg'],
        'content': '<img src="/src/old.jpg">',
      },
    }, baseUrl: base);
    expect(pages.single.url, '$base/src/current.jpg');
  });

  test('comic HTML fallback uses src order and the backend origin', () {
    final pages = parseComicImages({
      'data': {
        'images': [],
        'content': '''
          <base href="https://unrelated.example/">
          <img src="/src/a.jpg?token=a%2Fb&amp;page=1">
          <img src="src/b.jpg">
          <img src="javascript:invalid()">
          <img data-src="/src/not-loaded.jpg">
          <img src="/src/a.jpg?token=a%2Fb&amp;page=1">
        ''',
      },
    }, baseUrl: base);
    expect(pages.map((page) => page.url), [
      '$base/src/a.jpg?token=a%2Fb&page=1',
      '$base/src/b.jpg',
      '$base/src/a.jpg?token=a%2Fb&page=1',
    ]);
  });

  test('comic accepts legacy images HTML inside a data wrapper', () {
    final pages = parseComicImages({
      'code': 200,
      'data': {
        'code': 0,
        'data': {'images': '<IMG SRC="/src/legacy.webp">'},
      },
    }, baseUrl: base);
    expect(pages.single.url, '$base/src/legacy.webp');
  });

  test('empty or unsupported comic content is an explicit error', () {
    for (final data in [
      <String, dynamic>{},
      {'images': []},
      {
        'images': [' ', 'file:///tmp/image.jpg'],
      },
      {'content': '<p>没有图片</p>'},
      {'images': '<img src="data:image/png;base64,AAAA">'},
    ]) {
      expect(
        () => parseComicImages({'data': data}, baseUrl: base),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '未获取到漫画图片',
          ),
        ),
      );
    }
  });

  test('inner business errors win over otherwise valid media fields', () {
    for (final error in [
      {'code': 101000, 'message': '章节暂不可用'},
      {'success': false, 'error': '章节暂不可用'},
    ]) {
      final payload = {
        'code': 200,
        'data': {
          'audio_url': 'https://cdn.example/audio.mp3',
          'images': ['/src/page.jpg'],
          'tones': '2,3',
          'data': error,
        },
      };
      final expected = throwsA(
        isA<FormatException>().having(
          (exception) => exception.message,
          'message',
          '章节暂不可用',
        ),
      );
      expect(
        () => parseAudioSource(payload, itemId: 'c', baseUrl: base),
        expected,
      );
      expect(() => parseComicImages(payload, baseUrl: base), expected);
      expect(() => parseAudioVoices(payload), expected);
    }
  });
}
