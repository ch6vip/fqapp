import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/services/drama_download_store.dart';

/// P1-4: keyHex never persists inside the episode record; it lives in a
/// dedicated `key:<itemId>` entry in the same encrypted box, and playback
/// still gets the key back.
void main() {
  late Directory temp;
  late Directory videoDir;
  late HiveDramaDownloadStore store;

  CachedEpisode episode({
    String itemId = 'ep1',
    String seriesId = 'series1',
    String keyHex = '0102030405060708090a0b0c0d0e0f10',
  }) {
    final path = '${videoDir.path}${Platform.pathSeparator}$itemId.mp4';
    File(path).writeAsBytesSync(List.filled(64, 1));
    return CachedEpisode(
      seriesId: seriesId,
      itemId: itemId,
      title: '第1集',
      index: 0,
      keyHex: keyHex,
      height: 1080,
      variantName: '1080P',
      bytes: 64,
      filePath: path,
      cachedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fqapp-drama-key-');
    Hive.init(temp.path);
    videoDir = Directory('${temp.path}${Platform.pathSeparator}offline-video')
      ..createSync();
    store = HiveDramaDownloadStore(
      directoryResolver: () async => videoDir,
    );
  });

  tearDown(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });

  test('keyHex is stored apart from the episode record', () async {
    await store.saveEpisode(episode());
    final box = Hive.box<dynamic>('drama_download_v1');
    final raw = box.get('episode:ep1') as Map;
    expect(raw.containsKey('keyHex'), isFalse);
    expect(box.get('key:ep1'), '0102030405060708090a0b0c0d0e0f10');

    final back = await store.episode('ep1');
    expect(back, isNotNull);
    expect(back!.keyHex, '0102030405060708090a0b0c0d0e0f10');
    expect(back.toSource().keyHex, '0102030405060708090a0b0c0d0e0f10');
    expect(await store.isDownloaded('ep1'), isTrue);
  });

  test('legacy record with an embedded key migrates on open', () async {
    // Simulate a pre-P1-4 record: keyHex embedded in the episode map.
    final box = await Hive.openBox<dynamic>('drama_download_v1');
    await box.put('episode:ep1', {
      'seriesId': 'series1',
      'itemId': 'ep1',
      'title': '第1集',
      'index': 0,
      'keyHex': 'aabbccddeeff00112233445566778899',
      'height': 1080,
      'variantName': '1080P',
      'bytes': 64,
      'filePath': '/tmp/ep1.mp4',
      'cachedAt': 1,
    });
    await box.close();

    final back = await store.episode('ep1');
    expect(back, isNotNull);
    expect(back!.keyHex, 'aabbccddeeff00112233445566778899');
    final reopened = Hive.box<dynamic>('drama_download_v1');
    expect(
      (reopened.get('episode:ep1') as Map).containsKey('keyHex'),
      isFalse,
    );
    expect(reopened.get('key:ep1'), 'aabbccddeeff00112233445566778899');
  });

  test('plain streams round-trip with an empty key', () async {
    await store.saveEpisode(episode(keyHex: ''));
    expect((await store.episode('ep1'))!.keyHex, '');
    expect(await store.isDownloaded('ep1'), isTrue);
  });

  test('removing an episode or drama removes its key entry', () async {
    await store.saveEpisode(episode());
    await store.saveEpisode(episode(itemId: 'ep2'));
    await store.removeEpisode('ep1');
    final box = Hive.box<dynamic>('drama_download_v1');
    expect(box.containsKey('episode:ep1'), isFalse);
    expect(box.containsKey('key:ep1'), isFalse);
    expect(box.containsKey('key:ep2'), isTrue);

    await store.removeDrama('series1');
    expect(box.containsKey('episode:ep2'), isFalse);
    expect(box.containsKey('key:ep2'), isFalse);
    expect(await store.dramas(), isEmpty);
  });
}
