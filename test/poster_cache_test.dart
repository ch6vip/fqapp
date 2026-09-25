import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/poster_cache.dart';

/// Creates a file with [bytes] content whose mtime is [ageMinutes] in the past.
Future<File> _file(
  Directory dir,
  String name,
  int bytes,
  int ageMinutes,
) async {
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(List.filled(bytes, 0x20));
  await file.setLastModified(
    DateTime.now().subtract(Duration(minutes: ageMinutes)),
  );
  return file;
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('fqapp-poster-cache-test-');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('the budget constants match the reference discipline', () {
    expect(PosterCache.maxEntries, 2000);
    expect(PosterCache.stalePeriod, const Duration(days: 30));
    expect(PosterCache.maxBytes, 256 << 20);
  });

  test('a store within the budget is left untouched', () async {
    await _file(root, 'a.jpg', 100, 1);
    await _file(root, 'b.jpg', 100, 2);
    final removed = await enforceImageCacheBudget(root: root, limit: 1 << 20);
    expect(removed, 0);
    expect(await root.list().length, 2);
  });

  test('the oldest files are swept until the store fits', () async {
    await _file(root, 'oldest.jpg', 600, 50);
    await _file(root, 'older.jpg', 600, 40);
    await _file(root, 'new.jpg', 600, 1);
    await _file(root, 'newer.jpg', 600, 1);

    // 2400 bytes in store, 1500 allowed: 900 bytes must go, i.e. the two
    // oldest files (sorted by mtime; equal mtimes keep listing order).
    final removed = await enforceImageCacheBudget(root: root, limit: 1500);
    expect(removed, 2);
    expect(
      await File('${root.path}${Platform.pathSeparator}oldest.jpg').exists(),
      isFalse,
    );
    expect(
      await File('${root.path}${Platform.pathSeparator}older.jpg').exists(),
      isFalse,
    );
    expect(
      await File('${root.path}${Platform.pathSeparator}new.jpg').exists(),
      isTrue,
    );
    expect(
      await File('${root.path}${Platform.pathSeparator}newer.jpg').exists(),
      isTrue,
    );
  });

  test('subdirectories are ignored, missing files do not block', () async {
    await _file(root, 'a.jpg', 900, 10);
    await Directory('${root.path}${Platform.pathSeparator}nested').create();
    final removed = await enforceImageCacheBudget(root: root, limit: 500);
    expect(removed, 1);
  });

  test('a missing root sweeps nothing', () async {
    final removed = await enforceImageCacheBudget(
      root: Directory('${root.path}${Platform.pathSeparator}absent'),
      limit: 100,
    );
    expect(removed, 0);
  });
}
