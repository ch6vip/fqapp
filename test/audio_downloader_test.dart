import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/audio_download_store.dart';
import 'package:fqapp/services/audio_downloader.dart';

/// 本地假 CDN：整文件 GET 与 `Range: bytes=a-` 续传都支持，并记录每次请求
/// 的 Range 头，供断点续传断言使用。
class _FakeCdn {
  _FakeCdn(this.content);

  final List<int> content;
  final List<String?> receivedRanges = [];
  late final HttpServer server;

  /// 第一次请求回 403（模拟过期的签名直链），之后再正常服务。
  bool expireOnce = false;
  int _served = 0;

  /// 忽略 Range 的响应：始终 200 全量。
  bool ignoreRange = false;

  String get url => 'http://127.0.0.1:${server.port}/audio.m4a';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      receivedRanges.add(range);
      _served++;
      if (expireOnce && _served == 1) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      var start = 0;
      if (range != null && !ignoreRange) {
        final match = RegExp(r'^bytes=(\d+)-$').firstMatch(range);
        if (match != null) start = int.parse(match.group(1)!);
      }
      final body = content.sublist(start);
      if (start > 0) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${content.length - 1}/${content.length}',
        );
      }
      request.response.contentLength = body.length;
      request.response.add(body);
      await request.response.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

/// 内存版记录箱：只保留下载引擎需要的那部分语义。
class _MemoryStore implements AudioDownloadStore {
  _MemoryStore(this.dir);

  final Directory dir;
  final Map<String, CachedAudioChapter> chapters = {};
  final ValueNotifier<int> _changes = ValueNotifier(0);

  @override
  bool isReady = true;

  @override
  ValueListenable<int> get changes => _changes;

  @override
  Future<void> warmUp() async {}

  @override
  Future<Directory> directory() async => dir;

  @override
  Future<void> ensureBook(CachedAudioBook book) async {}

  @override
  Future<void> saveChapter(CachedAudioChapter chapter) async {
    chapters['${chapter.itemId}|${chapter.toneId}'] = chapter;
    _changes.value++;
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
    _changes.value++;
  }

  @override
  Future<void> removeBook(String bookId, {required String toneId}) async {
    chapters.removeWhere(
      (_, value) => value.bookId == bookId && value.toneId == toneId,
    );
    _changes.value++;
  }

  @override
  Future<int> totalBytes() async =>
      chapters.values.fold<int>(0, (sum, chapter) => sum + chapter.bytes);
}

void main() {
  late Directory temp;
  late _MemoryStore store;
  late _FakeCdn cdn;
  final content = List<int>.generate(64 * 1024, (index) => index % 251);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fqapp-audio-dl-');
    store = _MemoryStore(temp);
    cdn = _FakeCdn(content);
    await cdn.start();
  });

  tearDown(() async {
    await cdn.stop();
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  AudioDownloader downloader({
    Future<AudioSource> Function(String, String, String)? resolve,
    int concurrency = 2,
  }) => AudioDownloader(
    store: store,
    concurrency: concurrency,
    resolve:
        resolve ??
        (bookId, itemId, toneId) async => AudioSource(
          itemId: itemId,
          url: cdn.url,
          toneId: toneId,
          keyHex: '00112233445566778899aabbccddeeff',
          duration: const Duration(seconds: 42),
        ),
  );

  CachedAudioBook book({String toneId = 'toneA'}) => CachedAudioBook(
    bookId: 'book1',
    title: '测试书',
    cover: '',
    toneId: toneId,
    chapters: [
      Chapter(itemId: 'ch1', title: '一', volumeName: ''),
      Chapter(itemId: 'ch2', title: '二', volumeName: ''),
    ],
  );

  Chapter chapterOne() =>
      Chapter(itemId: 'ch1', title: '一', volumeName: '');

  Future<void> settle(AudioDownloader engine) async {
    // 引擎在后台跑；等所有任务离开等待/下载态。
    for (var i = 0; i < 300; i++) {
      final busy = engine.value.any(
        (task) =>
            task.status == AudioDownloadStatus.waiting ||
            task.status == AudioDownloadStatus.downloading,
      );
      if (!busy) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('download did not settle: ${engine.value.map((t) => t.status)}');
  }

  test('downloads a chapter, writes the file and records the key', () async {
    final engine = downloader();
    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    await settle(engine);

    final task = engine.value.single;
    expect(task.status, AudioDownloadStatus.completed);
    expect(task.received, content.length);
    final cached = store.chapters['ch1|toneA'];
    expect(cached, isNotNull);
    expect(cached!.bytes, content.length);
    expect(cached.keyHex, '00112233445566778899aabbccddeeff');
    expect(cached.durationMs, 42000);
    expect(File(cached.filePath).readAsBytesSync(), content);
    expect(cached.filePath, endsWith('ch1__toneA.m4a'));
  });

  test('resumes a half-written part file with a Range request', () async {
    final engine = downloader();
    final partFile = File(
      '${temp.path}${Platform.pathSeparator}ch1__toneA.m4a.part',
    );
    final half = content.sublist(0, 20 * 1024);
    partFile.writeAsBytesSync(half);

    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    await settle(engine);

    expect(cdn.receivedRanges, contains('bytes=${half.length}-'));
    final cached = store.chapters['ch1|toneA'];
    expect(cached, isNotNull);
    expect(File(cached!.filePath).readAsBytesSync(), content);
    expect(partFile.existsSync(), isFalse);
  });

  test('an expired direct link is refreshed once and then succeeds', () async {
    cdn.expireOnce = true;
    var resolves = 0;
    final engine = downloader(
      resolve: (bookId, itemId, toneId) async {
        resolves++;
        return AudioSource(itemId: itemId, url: cdn.url, toneId: toneId);
      },
    );
    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    await settle(engine);

    expect(resolves, 2);
    expect(engine.value.single.status, AudioDownloadStatus.completed);
    expect(store.chapters.containsKey('ch1|toneA'), isTrue);
  });

  test('a server that ignores Range restarts from zero', () async {
    cdn.ignoreRange = true;
    final engine = downloader();
    File(
      '${temp.path}${Platform.pathSeparator}ch1__toneA.m4a.part',
    ).writeAsBytesSync(content.sublist(0, 1024));

    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    await settle(engine);

    expect(engine.value.single.status, AudioDownloadStatus.completed);
    final cached = store.chapters['ch1|toneA'];
    expect(File(cached!.filePath).readAsBytesSync(), content);
  });

  test('a failing resolve marks the chapter failed and resume retries', () async {
    var attempts = 0;
    final engine = downloader(
      resolve: (bookId, itemId, toneId) async {
        attempts++;
        if (attempts == 1) throw const SocketException('offline');
        return AudioSource(itemId: itemId, url: cdn.url, toneId: toneId);
      },
    );
    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    await settle(engine);
    expect(engine.value.single.status, AudioDownloadStatus.failed);

    engine.resume('ch1', toneId: 'toneA');
    await settle(engine);
    expect(engine.value.single.status, AudioDownloadStatus.completed);
    expect(store.chapters.containsKey('ch1|toneA'), isTrue);
  });

  test('the same chapter in two tones becomes two files', () async {
    final engine = downloader();
    for (final tone in ['toneA', 'toneB']) {
      await engine.enqueue(
        book: book(toneId: tone),
        chapters: [chapterOne()],
      );
    }
    await settle(engine);

    expect(store.chapters.keys, containsAll(['ch1|toneA', 'ch1|toneB']));
    expect(
      store.chapters['ch1|toneA']!.filePath,
      isNot(store.chapters['ch1|toneB']!.filePath),
    );
  });

  test('skips chapters that are already downloaded', () async {
    final engine = downloader();
    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    await settle(engine);
    final firstCount = engine.value.length;

    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    await settle(engine);
    expect(engine.value.length, firstCount);
  });
}
