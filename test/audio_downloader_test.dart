import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/audio_download_store.dart';
import 'package:fqapp/services/audio_download_transfer.dart';
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

  /// 非空时把它当作服务器的「文件总长」：Range 起点越界就回 416（模拟重取
  /// 地址后拿到另一条更短的流）。
  int? shortLength;

  /// 非空时第一次请求回这个状态码（模拟 5xx 抖动）。
  int? failFirstStatus;

  /// 非空时第一次请求先发 [stallBytes] 字节再挂起，等完成才把剩余部分发完。
  /// 一段要够大，客户端才会在响应结束前把字节交给下载循环（dart:io 的
  /// HttpClient 对小段响应有缓冲）。
  Completer<void>? stallFirstResponse;
  static const int stallBytes = 32 * 1024;

  /// true 时每一次请求都按 [stallFirstResponse] 挂起，而不是只在第一次。
  bool stallAllResponses = false;

  /// 挂起前先发出的字节数；0 表示只发响应头就停住。
  int stallAfter = stallBytes;

  int get requestCount => _served;

  int get _total => shortLength ?? content.length;

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
      if (failFirstStatus != null && _served == 1) {
        request.response.statusCode = failFirstStatus!;
        await request.response.close();
        return;
      }
      var start = 0;
      if (range != null && !ignoreRange) {
        final match = RegExp(r'^bytes=(\d+)-$').firstMatch(range);
        if (match != null) start = int.parse(match.group(1)!);
      }
      if (start >= _total) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await request.response.close();
        return;
      }
      final body = content.sublist(start, _total);
      if (start > 0) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${_total - 1}/$_total',
        );
      }
      request.response.contentLength = body.length;
      final stall = (stallAllResponses || _served == 1)
          ? stallFirstResponse
          : null;
      if (stall != null && body.length > stallAfter) {
        request.response.add(body.sublist(0, stallAfter));
        await request.response.flush();
        await stall.future;
        request.response.add(body.sublist(stallAfter));
      } else {
        request.response.add(body);
      }
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
    HttpClient Function()? clientFactory,
    Duration connectTimeout = audioDownloadConnectTimeout,
    Duration readTimeout = audioDownloadReadTimeout,
  }) => AudioDownloader(
    store: store,
    concurrency: concurrency,
    clientFactory: clientFactory,
    connectTimeout: connectTimeout,
    readTimeout: readTimeout,
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
    // 引擎在后台跑；等所有任务离开等待/下载态。失败会自动重试（最多三次，
    // 退避 0.9s + 1.8s），窗口要留够。
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(end)) {
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

  test('a failing resolve is retried, then failed, then resume works', () async {
    var attempts = 0;
    var offline = true;
    final engine = downloader(
      resolve: (bookId, itemId, toneId) async {
        attempts++;
        if (offline) throw const SocketException('offline');
        return AudioSource(itemId: itemId, url: cdn.url, toneId: toneId);
      },
    );
    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    await settle(engine);
    expect(engine.value.single.status, AudioDownloadStatus.failed);
    expect(attempts, 3, reason: '首次 + 自动重试两次后放弃');

    offline = false;
    engine.resume('ch1', toneId: 'toneA');
    await settle(engine);
    expect(engine.value.single.status, AudioDownloadStatus.completed);
    expect(store.chapters.containsKey('ch1|toneA'), isTrue);
  });

  test('a 5xx is retried automatically and the chapter still completes', () async {
    cdn.failFirstStatus = HttpStatus.serviceUnavailable;
    final engine = downloader();
    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    await settle(engine);

    final task = engine.value.single;
    expect(task.status, AudioDownloadStatus.completed, reason: '${task.error}');
    expect(cdn.requestCount, 2, reason: '第一次 503 后应自动再试一次');
    expect(store.chapters.containsKey('ch1|toneA'), isTrue);
  });

  test('a 4xx other than 408/429 is not retried', () async {
    cdn.failFirstStatus = HttpStatus.notFound;
    final engine = downloader();
    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    await settle(engine);

    final task = engine.value.single;
    expect(task.status, AudioDownloadStatus.failed);
    expect(task.error, contains('404'));
    expect(cdn.requestCount, 1, reason: '404 重试也是同一个结果');
  });

  test('续传越界（HTTP 416）丢掉半成品重下，不会卡在失败', () async {
    // 半成品 500 字节，但重取地址后这条流只有 100 字节：Range 起点越界。
    final part = File(
      '${temp.path}${Platform.pathSeparator}ch1__toneA.m4a.part',
    )..writeAsBytesSync(List.filled(500, 7));
    cdn.shortLength = 100;

    final engine = downloader();
    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    await settle(engine);

    final task = engine.value.single;
    expect(task.status, AudioDownloadStatus.completed, reason: '${task.error}');
    expect(part.existsSync(), isFalse, reason: '越界的半成品要被丢掉');
    final cached = store.chapters['ch1|toneA'];
    expect(cached, isNotNull);
    expect(File(cached!.filePath).readAsBytesSync(), content.sublist(0, 100));
  });

  test(
    '服务器接了连接却不发正文时按超时重试，而不是永远挂着',
    () async {
      // 只发响应头就停住；客户端必须在读超时后自己收尾，别把 `_active` 的
      // 槽位和协程永远占住。
      cdn.stallFirstResponse = Completer<void>();
      cdn.stallAllResponses = true;
      cdn.stallAfter = 0;

      final engine = downloader(
        readTimeout: const Duration(milliseconds: 120),
      );
      await engine.enqueue(book: book(), chapters: [chapterOne()]);
      await settle(engine);

      final task = engine.value.single;
      expect(task.status, AudioDownloadStatus.failed);
      expect(task.error, '下载超时');
      expect(cdn.requestCount, 3, reason: '超时按可重试的网络故障处理');
    },
  );

  test('每次下载都给 HttpClient 设连接超时', () async {
    final clients = <HttpClient>[];
    final engine = downloader(
      connectTimeout: const Duration(seconds: 3),
      clientFactory: () {
        final client = HttpClient();
        clients.add(client);
        return client;
      },
    );
    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    await settle(engine);

    expect(engine.value.single.status, AudioDownloadStatus.completed);
    expect(clients, isNotEmpty);
    for (final client in clients) {
      expect(client.connectionTimeout, const Duration(seconds: 3));
    }
  });

  test('discard 后立刻重下不会和旧协程并发写同一个 .part', () async {
    final gate = Completer<void>();
    cdn.stallFirstResponse = gate;
    final part = File(
      '${temp.path}${Platform.pathSeparator}ch1__toneA.m4a.part',
    );
    final engine = downloader();

    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    // 旧协程已经收到第一段字节并且卡在收流上。
    await _waitFor(
      () => part.existsSync() && part.lengthSync() >= _FakeCdn.stallBytes,
    );

    await engine.discard('ch1', toneId: 'toneA');
    await engine.enqueue(book: book(), chapters: [chapterOne()]);
    // 旧协程还没收尾：同 key 的新一轮此时绝不能已经发请求（否则两个循环
    // 会同时往同一个 `.part` 里写）。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(cdn.requestCount, 1, reason: '旧协程收尾前不得为同一章再起一轮');

    gate.complete();
    await settle(engine);

    final task = engine.value.single;
    expect(task.status, AudioDownloadStatus.completed, reason: '${task.error}');
    final cached = store.chapters['ch1|toneA'];
    expect(cached, isNotNull);
    expect(File(cached!.filePath).readAsBytesSync(), content);
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

Future<void> _waitFor(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(end)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('条件在时限内未满足');
}
