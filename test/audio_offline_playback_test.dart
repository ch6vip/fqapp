import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/audio_download_store.dart';

import 'support/fakes.dart';

/// 只提供「已下载章节」查询能力的内存记录箱：离线优先这条链路不需要真实
/// Hive 箱参与。
class _MemoryAudioStore implements AudioDownloadStore {
  _MemoryAudioStore(this.dir);

  final Directory dir;
  final Map<String, CachedAudioChapter> chapters = {};

  @override
  bool isReady = true;

  @override
  final ValueNotifier<int> changes = ValueNotifier(0);

  @override
  Future<void> warmUp() async {}

  @override
  Future<Directory> directory() async => dir;

  @override
  Future<void> ensureBook(CachedAudioBook book) async {}

  @override
  Future<void> saveChapter(CachedAudioChapter chapter) async {
    chapters['${chapter.itemId}|${chapter.toneId}'] = chapter;
  }

  @override
  Future<bool> isDownloaded(String itemId, {required String toneId}) async =>
      chapters.containsKey('$itemId|$toneId');

  @override
  Future<CachedAudioChapter?> chapter(
    String itemId, {
    required String toneId,
  }) async => chapters['$itemId|$toneId'];

  @override
  Future<Set<String>> downloadedIds(
    String bookId, {
    required String toneId,
  }) async => {
    for (final entry in chapters.values)
      if (entry.bookId == bookId && entry.toneId == toneId) entry.itemId,
  };

  @override
  Future<void> removeChapter(String itemId, {required String toneId}) async {
    chapters.remove('$itemId|$toneId');
  }

  @override
  Future<void> removeBook(String bookId, {required String toneId}) async {
    chapters.removeWhere(
      (_, value) => value.bookId == bookId && value.toneId == toneId,
    );
  }

  @override
  Future<int> totalBytes() async => 0;
}

void main() {
  late Directory temp;
  late _MemoryAudioStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fqapp-audio-offline-');
    store = _MemoryAudioStore(temp);
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  CachedAudioChapter downloaded({
    String itemId = '1',
    String toneId = 'toneA',
    String keyHex = '00112233445566778899aabbccddeeff',
    bool withFile = true,
  }) {
    final file = File('${temp.path}${Platform.pathSeparator}$itemId.m4a');
    if (withFile) file.writeAsBytesSync(List<int>.filled(32, 9));
    return CachedAudioChapter(
      bookId: 'book',
      itemId: itemId,
      toneId: toneId,
      title: '第$itemId章',
      index: 0,
      keyHex: keyHex,
      bytes: 32,
      filePath: file.path,
      cachedAt: 1700000000000,
      durationMs: 90000,
    );
  }

  Widget app({required FakeNativePlayer player, required List<String> loads}) =>
      MaterialApp(
        home: AudioPage(
          bookId: 'book',
          title: '测试听书',
          chapters: [
            Chapter(itemId: '1', title: '第1章', volumeName: ''),
            Chapter(itemId: '2', title: '第2章', volumeName: ''),
          ],
          initialToneId: 'toneA',
          historyStore: MemoryReaderStore(),
          downloadStore: store,
          voicesLoader: () async => const [],
          extrasLoader: (bookId) async => const AudioExtras(),
          sourceLoader: (itemId, {toneId}) async {
            loads.add('$itemId:$toneId');
            return AudioSource(
              itemId: itemId,
              url: 'https://cdn.invalid/$itemId.m4a',
              toneId: toneId ?? 'toneA',
              keyHex: 'ffeeddccbbaa99887766554433221100',
            );
          },
          playerFactory: () => player,
        ),
      );

  testWidgets('a downloaded chapter plays the local file, not the network', (
    tester,
  ) async {
    store.chapters['1|toneA'] = downloaded();
    final player = FakeNativePlayer();
    final loads = <String>[];

    await tester.pumpWidget(app(player: player, loads: loads));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(loads, isEmpty, reason: '本地命中时不应再请求取流接口');
    expect(
      player.calls,
      contains(startsWith('create:file://')),
      reason: '播放器应拿到 file:// 地址走本地文件桥',
    );
    expect(player.createdKeys, contains('00112233445566778899aabbccddeeff'));
  });

  testWidgets('an unknown chapter still goes to the network loader', (
    tester,
  ) async {
    final player = FakeNativePlayer();
    final loads = <String>[];

    await tester.pumpWidget(app(player: player, loads: loads));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(loads, ['1:toneA']);
    expect(player.calls, contains('create:https://cdn.invalid/1.m4a'));
  });

  testWidgets('a record whose file was deleted falls back to the network', (
    tester,
  ) async {
    final cached = downloaded(withFile: false);
    store.chapters['1|toneA'] = cached;
    final player = FakeNativePlayer();
    final loads = <String>[];

    await tester.pumpWidget(app(player: player, loads: loads));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(loads, ['1:toneA']);
    expect(player.calls, contains('create:https://cdn.invalid/1.m4a'));
  });

  testWidgets('a download recorded for another tone is not reused', (
    tester,
  ) async {
    store.chapters['1|toneB'] = downloaded(toneId: 'toneB');
    final player = FakeNativePlayer();
    final loads = <String>[];

    await tester.pumpWidget(app(player: player, loads: loads));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(loads, ['1:toneA']);
    expect(player.calls, contains('create:https://cdn.invalid/1.m4a'));
  });
}
