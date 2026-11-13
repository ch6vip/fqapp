import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/webdav_ai_payload.dart';

String encoded(Map<String, Object?> payload) =>
    base64Encode(gzip.encode(utf8.encode(jsonEncode(payload))));

void main() {
  final payload = <String, Object?>{
    'format': 'fqapp.ai-backup',
    'version': 1,
    'createdAt': 1,
    'feedback': [],
    'prompts': [],
    'candidates': [],
  };

  test(
    'background decoder validates payload and ignores export timestamp in fingerprint',
    () async {
      final first = await decodeWebDavAi(encoded(payload));
      final later = await decodeWebDavAi(encoded({...payload, 'createdAt': 2}));
      expect(first.payload.feedback, isEmpty);
      expect(first.fingerprint, later.fingerprint);
      final changed = await decodeWebDavAi(
        encoded({
          ...payload,
          'promptState': {'global': 'new'},
        }),
      );
      expect(first.fingerprint, isNot(changed.fingerprint));
    },
  );

  test(
    'rejects corrupt gzip and structurally invalid AI before restoration',
    () async {
      await expectLater(
        decodeWebDavAi(base64Encode([1, 2, 3])),
        throwsA(anything),
      );
      await expectLater(
        decodeWebDavAi(encoded({'format': 'unknown'})),
        throwsFormatException,
      );
    },
  );

  test('caps expanded data even when the compressed input is small', () async {
    final large = encoded({...payload, 'padding': 'a' * 100000});
    expect(large.length, lessThan(1024));
    await expectLater(
      decodeWebDavAi(large, maxBytes: 1024),
      throwsFormatException,
    );
  });
}
