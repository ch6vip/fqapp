import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/library_backup.dart';

void main() {
  test('v1 backup still decodes and v2 keeps the AI segment', () {
    final v1 = LibraryBackup.capture(shelf: [], history: [], watched: {});
    final decodedV1 = LibraryBackup.decode(v1.encode());
    expect(decodedV1.aiData, isNull);
    expect(decodedV1.shelf, isEmpty);

    final v2 = LibraryBackup.capture(
      shelf: [],
      history: [],
      watched: {},
      aiData: 'ZmFrZS1haS1zZWdtZW50',
    );
    final decodedV2 = LibraryBackup.decode(v2.encode());
    expect(decodedV2.aiData, 'ZmFrZS1haS1zZWdtZW50');
  });

  test('v2 without a usable AI section is rejected', () {
    final v2 = LibraryBackup.capture(
      shelf: [],
      history: [],
      watched: {},
      aiData: 'ZmFrZS1haS1zZWdtZW50',
    );
    final json = jsonDecode(utf8.decode(v2.encode())) as Map<String, dynamic>;
    json['ai'] = null;
    expect(
      () => LibraryBackup.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(json))),
      ),
      throwsFormatException,
    );
    json['ai'] = '';
    expect(
      () => LibraryBackup.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(json))),
      ),
      throwsFormatException,
    );
  });
}
