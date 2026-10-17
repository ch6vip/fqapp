import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/quality_memory.dart';

void main() {
  setUp(QualityMemory.clearForTesting);
  tearDown(QualityMemory.clearForTesting);

  test('remembers a quality name per series key', () {
    expect(QualityMemory.nameFor('a'), isNull);
    QualityMemory.remember('a', '360P');
    expect(QualityMemory.nameFor('a'), '360P');
    expect(QualityMemory.nameFor('b'), isNull);
  });

  test('a later choice overwrites the earlier one', () {
    QualityMemory.remember('a', '360P');
    QualityMemory.remember('a', '720P');
    expect(QualityMemory.nameFor('a'), '720P');
  });

  test('clear drops every remembered choice', () {
    QualityMemory.remember('a', '360P');
    QualityMemory.clearForTesting();
    expect(QualityMemory.nameFor('a'), isNull);
  });
}
