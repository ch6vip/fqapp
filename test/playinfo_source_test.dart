import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/chapter_media.dart';

const _base = 'http://localhost:8080';
const _firstUrl = 'https://cdn.example/first.m4a';
const _secondUrl = 'https://cdn.example/second.m4a?sign=a%2fb+xyz&x=%7e';
const _firstKey = '11111111111111111111111111111111';
const _secondKey = 'abcdef0123456789abcdef0123456789';

void main() {
  test('preferred URL uses the key belonging to that exact model stream', () {
    final source = _source(
      _payload([
        _encrypted(_firstUrl, _firstKey),
        _encrypted(_secondUrl, _secondKey.toUpperCase()),
      ], mainUrl: _secondUrl),
    );

    expect(source.url, _secondUrl);
    expect(source.keyHex, _secondKey);
    expect(source.itemId, 'chapter');
    expect(source.toneId, '57');
  });

  test('a preferred backup URL keeps its own stream encryption metadata', () {
    const backup = 'https://backup.example/audio.m4a?sign=%2f+abc';
    final source = _source(
      _payload(
        [
          _encrypted(_firstUrl, _firstKey),
          {..._encrypted(_secondUrl, _secondKey), 'backup_url': backup},
        ],
        mainUrl: 'file:///invalid',
        backupUrl: backup,
      ),
    );

    expect(source.url, backup);
    expect(source.keyHex, _secondKey);
  });

  test('an unmatched outer URL cannot borrow an unrelated content key', () {
    final source = _source(
      _payload([
        _encrypted(_firstUrl, _firstKey),
      ], mainUrl: 'https://cdn.example/unmatched.m4a'),
    );

    expect(source.url, _firstUrl);
    expect(source.keyHex, _firstKey);
  });

  test('plain preferred stream does not inherit a later encrypted key', () {
    final source = _source(
      _payload([
        {'main_url': _firstUrl},
        _encrypted(_secondUrl, _secondKey),
      ]),
    );

    expect(source.url, _firstUrl);
    expect(source.keyHex, isEmpty);
  });

  for (final invalid in [
    (name: 'missing key', info: <String, dynamic>{'encrypt': true}),
    (
      name: 'short key',
      info: <String, dynamic>{'encrypt': true, 'key_hex': 'abcdef'},
    ),
    (
      name: 'non-hex key',
      info: <String, dynamic>{
        'encrypt': true,
        'key_hex': 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz',
      },
    ),
    (
      name: 'unsupported encryption',
      info: <String, dynamic>{
        'encrypt': true,
        'key_hex': _firstKey,
        'encryption_method': 'cbcs',
      },
    ),
  ]) {
    test('${invalid.name} falls back to the next usable stream', () {
      final source = _source(
        _payload([
          {'main_url': _firstUrl, 'encrypt_info': invalid.info},
          _encrypted(_secondUrl, _secondKey),
        ]),
      );

      expect(source.url, _secondUrl);
      expect(source.keyHex, _secondKey);
    });

    test('${invalid.name} without a usable fallback is an explicit error', () {
      expect(
        () => _source(
          _payload([
            {'main_url': _firstUrl, 'encrypt_info': invalid.info},
          ]),
        ),
        throwsFormatException,
      );
    });
  }

  test('a model fallback may be a plain stream without a key', () {
    final source = _source(
      _payload([
        {
          'main_url': _firstUrl,
          'encrypt_info': {'encrypt': true},
        },
        {'backup_url': _secondUrl},
      ]),
    );

    expect(source.url, _secondUrl);
    expect(source.keyHex, isEmpty);
  });

  test('invalid main URL can use the same model stream backup', () {
    final source = _source(
      _payload([
        {..._encrypted('file:///invalid', _firstKey), 'backup_url': _secondUrl},
      ], mainUrl: 'file:///invalid'),
    );

    expect(source.url, _secondUrl);
    expect(source.keyHex, _firstKey);
  });

  for (final malformed in ['{invalid-json', '[]', '']) {
    test('a malformed model ($malformed) cannot become a plain stream', () {
      expect(
        () => _source({
          'code': 0,
          'data': [
            {'main_url': _firstUrl, 'video_model': malformed},
          ],
        }),
        throwsFormatException,
      );
    });
  }

  test('an unusable model row falls through to a later usable row', () {
    final valid = _payload([_encrypted(_secondUrl, _secondKey)]);
    final source = _source({
      'code': 0,
      'data': [
        {'main_url': _firstUrl, 'video_model': '{invalid-json'},
        ...(valid['data'] as List),
      ],
    });

    expect(source.url, _secondUrl);
    expect(source.keyHex, _secondKey);
  });

  test('a direct plain response without a model remains playable', () {
    final source = _source({
      'code': 0,
      'data': [
        {'main_url': '/audio.mp3?sign=a%2fb+xyz'},
      ],
    });

    expect(source.url, '$_base/audio.mp3?sign=a%2Fb+xyz');
    expect(source.keyHex, isEmpty);
    expect(source.duration, isNull);
  });

  test('indate is not the duration of a direct plain stream', () {
    final source = _source({
      'code': 0,
      'data': [
        {'main_url': _firstUrl, 'indate': 86400},
      ],
    });
    expect(source.duration, isNull);
  });

  test('indate does not fill in missing model duration', () {
    final source = _source(
      _payload([
        {'main_url': _firstUrl},
      ], duration: null),
    );
    expect(source.duration, isNull);
  });

  test('model duration in seconds is retained with subsecond precision', () {
    final source = _source(_payload([_encrypted(_firstUrl, _firstKey)]));
    expect(source.duration, const Duration(milliseconds: 664741));
  });

  test(
    'a row for another item cannot be returned as the requested chapter',
    () {
      final wrong = _payload([
        _encrypted(_firstUrl, _firstKey),
      ], itemId: 'other');
      final right = _payload([_encrypted(_secondUrl, _secondKey)]);
      final source = _source({
        'code': 0,
        'data': [...(wrong['data'] as List), ...(right['data'] as List)],
      });
      expect(source.url, _secondUrl);
    },
  );

  test(
    'a failed row keeps its business error instead of using a valid URL',
    () {
      expect(
        () => _source({
          'code': 0,
          'data': [
            {'code': 101000, 'message': 'NO_THIS_TONE', 'main_url': _firstUrl},
          ],
        }),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'NO_THIS_TONE',
          ),
        ),
      );
    },
  );

  test('a failed envelope cannot be hidden by otherwise valid media rows', () {
    expect(
      () => _source({
        ..._payload([_encrypted(_firstUrl, _firstKey)]),
        'code': 403,
        'message': '章节暂不可用',
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          '章节暂不可用',
        ),
      ),
    );
  });

  test('an unavailable audio model keeps its business error', () {
    expect(
      () => _source(
        _payload([_encrypted(_firstUrl, _firstKey)], modelStatus: 403),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          '音频资源暂不可用',
        ),
      ),
    );
  });

  test('a non-audio model is not returned as a playable audio chapter', () {
    expect(
      () => _source(
        _payload([_encrypted(_firstUrl, _firstKey)], mediaType: 'video'),
      ),
      throwsFormatException,
    );
  });
}

AudioSource _source(Map<String, dynamic> payload) => parsePlayinfoSource(
  payload,
  itemId: 'chapter',
  toneId: '57',
  baseUrl: _base,
);

Map<String, dynamic> _encrypted(String url, String key) => {
  'main_url': url,
  'encrypt_info': {
    'encrypt': true,
    'encryption_method': 'cenc-aes-ctr',
    'key_hex': key,
  },
};

Map<String, dynamic> _payload(
  List<Map<String, dynamic>> streams, {
  String mainUrl = _firstUrl,
  String? backupUrl,
  Object? duration = 664.741,
  String itemId = 'chapter',
  int modelStatus = 10,
  String mediaType = 'audio',
}) => {
  'code': 0,
  'data': [
    {
      'main_url': mainUrl,
      'backup_url': ?backupUrl,
      'item_id': itemId,
      'indate': 86400,
      'video_model': jsonEncode({
        'status': modelStatus,
        'media_type': mediaType,
        'video_duration': duration,
        'video_list': streams,
      }),
    },
  ],
};
