import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/audio_download_store.dart';
import 'package:fqapp/services/secure_key_provider.dart';

void main() {
  late Directory temp;
  late Directory audioDir;
  late HiveAudioDownloadStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fqapp-audio-store-');
    Hive.init(temp.path);
    audioDir = Directory('${temp.path}${Platform.pathSeparator}offline-audio')
      ..createSync();
    store = HiveAudioDownloadStore(
      keys: SecureKeyProvider(storage: InMemorySecureKeyStorage()),
      directoryResolver: () async => temp,
    );
    await store.warmUp();
  });

  tearDown(() async {
    await Hive.close();
    try {
      await Hive.deleteBoxFromDisk('audio_download_v1_enc');
    } catch (_) {}
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  CachedAudioChapter chapter({
    String bookId = 'book1',
    String itemId = 'ch1',
    String toneId = 'toneA',
    String keyHex = 'aabbccdd00112233445566778899aabb',
    int bytes = 2048,
    String? filePath,
    int? durationMs = 61000,
  }) {
    final file = File(
      filePath ?? '${audioDir.path}${Platform.pathSeparator}$itemId.m4a',
    );
    if (filePath == null) {
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(List<int>.filled(16, 7));
    }
    return CachedAudioChapter(
      bookId: bookId,
      itemId: itemId,
      toneId: toneId,
      title: '第 $itemId 章',
      index: 0,
      keyHex: keyHex,
      bytes: bytes,
      filePath: file.path,
      cachedAt: 1700000000000,
      durationMs: durationMs,
    );
  }

  test('records a chapter and reassembles the separated content key', () async {
    await store.saveChapter(chapter());
    final cached = await store.chapter('ch1', toneId: 'toneA');
    expect(cached, isNotNull);
    expect(cached!.keyHex, 'aabbccdd00112233445566778899aabb');
    expect(cached.bytes, 2048);
    expect(cached.durationMs, 61000);
    expect(await store.isDownloaded('ch1', toneId: 'toneA'), isTrue);
  });

  test('the chapter record itself never carries keyHex', () async {
    await store.saveChapter(chapter());
    final box = Hive.box<dynamic>('audio_download_v1_enc');
    final raw = box.get('chapter:ch1|toneA');
    expect(raw, isA<Map>());
    expect((raw as Map).containsKey('keyHex'), isFalse);
    // 密钥在独立条目里。
    expect(box.get('key:ch1|toneA'), 'aabbccdd00112233445566778899aabb');
  });

  test('downloads are scoped by tone', () async {
    await store.saveChapter(chapter(toneId: 'toneA'));
    await store.saveChapter(chapter(toneId: 'toneB', keyHex: 'ff00' * 8));
    expect(await store.downloadedIds('book1', toneId: 'toneA'), {'ch1'});
    expect(await store.downloadedIds('book1', toneId: 'toneB'), {'ch1'});
    // 别的音色下没有这一章。
    expect(await store.downloadedIds('book1', toneId: 'toneC'), isEmpty);
    expect(await store.isDownloaded('ch1', toneId: 'toneC'), isFalse);
    expect(await store.chapter('ch1', toneId: 'toneC'), isNull);
  });

  test('tone B does not read tone A key', () async {
    await store.saveChapter(chapter(toneId: 'toneA', keyHex: 'aa' * 16));
    await store.saveChapter(chapter(toneId: 'toneB', keyHex: 'bb' * 16));
    expect((await store.chapter('ch1', toneId: 'toneA'))!.keyHex, 'aa' * 16);
    expect((await store.chapter('ch1', toneId: 'toneB'))!.keyHex, 'bb' * 16);
  });

  test('removeChapter deletes the file and both records', () async {
    final cached = chapter();
    await store.saveChapter(cached);
    await store.removeChapter('ch1', toneId: 'toneA');
    expect(File(cached.filePath).existsSync(), isFalse);
    expect(await store.chapter('ch1', toneId: 'toneA'), isNull);
    final box = Hive.box<dynamic>('audio_download_v1_enc');
    expect(box.get('key:ch1|toneA'), isNull);
  });

  test('removeBook only touches its own book and tone', () async {
    final mine = chapter(itemId: 'ch1', bookId: 'book1', toneId: 'toneA');
    final otherBook = chapter(itemId: 'ch2', bookId: 'book2', toneId: 'toneA');
    final otherTone = chapter(itemId: 'ch3', bookId: 'book1', toneId: 'toneB');
    for (final entry in [mine, otherBook, otherTone]) {
      await store.saveChapter(entry);
    }
    await store.removeBook('book1', toneId: 'toneA');
    expect(File(mine.filePath).existsSync(), isFalse);
    expect(File(otherBook.filePath).existsSync(), isTrue);
    expect(File(otherTone.filePath).existsSync(), isTrue);
    expect(await store.downloadedIds('book1', toneId: 'toneA'), isEmpty);
    expect(await store.downloadedIds('book2', toneId: 'toneA'), {'ch2'});
  });

  test('a tampered path outside the audio root keeps the file', () async {
    // 记录被改成指向目录外：只删记录，绝不删那个文件（否则就是任意文件
    // 删除）。
    final outside = File('${temp.path}${Platform.pathSeparator}secret.txt')
      ..writeAsStringSync('keep me');
    await store.saveChapter(chapter(filePath: outside.path));
    await store.removeChapter('ch1', toneId: 'toneA');
    expect(outside.existsSync(), isTrue);
    expect(await store.chapter('ch1', toneId: 'toneA'), isNull);
  });

  test('totalBytes sums only valid finite records', () async {
    await store.saveChapter(chapter(itemId: 'ch1', bytes: 1000));
    await store.saveChapter(chapter(itemId: 'ch2', bytes: 2500));
    expect(await store.totalBytes(), 3500);
    await store.removeChapter('ch1', toneId: 'toneA');
    expect(await store.totalBytes(), 2500);
  });

  test('ensureBook stores the catalogue without inventing chapters', () async {
    await store.ensureBook(
      CachedAudioBook(
        bookId: 'book1',
        title: '测试书',
        cover: 'https://example.invalid/c.jpg',
        toneId: 'toneA',
        chapters: [
          Chapter(itemId: 'ch1', title: '一', volumeName: ''),
          Chapter(itemId: 'ch2', title: '二', volumeName: ''),
        ],
      ),
    );
    final box = Hive.box<dynamic>('audio_download_v1_enc');
    final raw = box.get('book:book1|toneA');
    expect(raw, isA<Map>());
    expect((raw as Map)['title'], '测试书');
    expect((raw['chapters'] as List).length, 2);
  });

  test('toSource points the player at the local file with the key', () async {
    await store.saveChapter(chapter());
    final cached = await store.chapter('ch1', toneId: 'toneA');
    final source = cached!.toSource();
    expect(source.url, startsWith('file://'));
    expect(source.url, endsWith('ch1.m4a'));
    expect(source.keyHex, cached.keyHex);
    expect(source.toneId, 'toneA');
    expect(source.duration, const Duration(milliseconds: 61000));
  });
}
