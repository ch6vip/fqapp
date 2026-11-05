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
}
