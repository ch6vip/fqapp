import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/drama_download_store.dart';
import 'package:fqapp/services/drama_downloader.dart';
import 'package:fqapp/services/episode_source_cache.dart';

import 'support/fakes.dart';

/// 本地假 CDN：整文件 GET 与 `Range: bytes=a-` 续传都支持，并记录每次
/// 请求的区间，供断点续传断言使用。
class _FakeCdn {
  _FakeCdn(this.content);

  final List<int> content;
  final List<String> receivedRanges = [];

  /// 非空时，这个路径只提供前 [_shortLength] 字节 —— 模拟「重取地址后拿到
  /// 另一条更短的流」，用来触发续传越界（HTTP 416）。
  int? _shortLength;

  set shortLength(int? value) => _shortLength = value;

  /// 非空时，响应体只发这么多字节且不声明长度（chunked）—— 模拟「下到
  /// 一半流就没了」：客户端读到一个完整的短响应，于是按「下载不完整」重试。
  int? truncateTo;

  int get _total => _shortLength ?? content.length;
  late final HttpServer server;

  String get url => 'http://127.0.0.1:${server.port}/video.mp4';

  /// 恒 403 的路径：模拟过期的签名直链。
  String get staleUrl => 'http://127.0.0.1:${server.port}/stale';

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) async {
      // /stale 路径恒 403：模拟过期的签名直链。
      if (request.uri.path == '/stale') {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      final rangeHeader = request.headers.value('range');
      var start = 0;
      var isRange = false;
      if (rangeHeader != null) {
        final match = RegExp(r'^bytes=(\d+)-').firstMatch(rangeHeader.trim());
        if (match != null) {
          start = int.parse(match.group(1)!);
          isRange = true;
        }
      }
      receivedRanges.add(isRange ? '$start-' : 'full');
      if (start >= _total) {
        request.response.statusCode = 416;
        await request.response.close();
        return;
      }
      if (isRange) {
        request.response.statusCode = 206;
        request.response.headers.set(
          'content-range',
          'bytes $start-${_total - 1}/$_total',
        );
      } else {
        request.response.statusCode = 200;
      }
      final slice = Uint8List.sublistView(
        Uint8List.fromList(content.sublist(0, _total)),
        start,
      );
      final limit = truncateTo;
      final body = limit != null && limit < slice.length
          ? Uint8List.sublistView(slice, 0, limit)
          : slice;
      if (identical(body, slice)) request.response.contentLength = slice.length;
      request.response.add(body);
      await request.response.flush();
      await request.response.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  late MemoryDramaDownloadStore store;
  late Directory videoDir;
  late _FakeCdn cdn;

  setUpAll(() async {});

  setUp(() async {
    videoDir = await Directory.systemTemp.createTemp('fqapp-drama-dl-');
    store = MemoryDramaDownloadStore(videoDirectory: videoDir);
    cdn = _FakeCdn(List.generate(1024, (i) => i % 256));
    await cdn.start();
  });

  tearDown(() async {
    await cdn.stop();
    try {
      await videoDir.delete(recursive: true);
    } catch (_) {}
  });

  DramaDownloader buildDownloader({
    required Future<EpisodeSource> Function(Chapter episode) resolve,
    int concurrency = 3,
  }) =>
      DramaDownloader(store: store, resolve: resolve, concurrency: concurrency);

  CachedDrama drama(int count) => CachedDrama(
    id: 'series1',
    title: '测试剧',
    cover: '',
    episodes: [
      for (var i = 0; i < count; i++)
        Chapter(itemId: 'ep$i', title: '第${i + 1}集', volumeName: ''),
    ],
  );

  Future<void> settle(DramaDownloader downloader) async {
    const timeout = Duration(seconds: 10);
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final tasks = downloader.value;
      final settled = tasks.every(
        (task) =>
            task.status == DramaDownloadStatus.completed ||
            task.status == DramaDownloadStatus.failed ||
            task.status == DramaDownloadStatus.paused,
      );
      if (tasks.isNotEmpty && settled) return;
    }
    fail('下载队列没有在时限内收敛: ${downloader.value}');
  }

  test('整集下载落盘并写入 store 记录（keyHex 随记录）', () async {
    final downloader = buildDownloader(
      resolve: (episode) async => EpisodeSource(cdn.url, 'abcd', const []),
    );
    await downloader.enqueue(drama: drama(1), episodes: drama(1).episodes);
    await settle(downloader);

    final record = await store.episode('ep0');
    expect(record, isNotNull);
    expect(record!.keyHex, 'abcd');
    expect(record.bytes, 1024);
    expect(File(record.filePath).existsSync(), isTrue);
    expect(File(record.filePath).readAsBytesSync(), cdn.content);
    expect(await store.isDownloaded('ep0'), isTrue);
    expect(downloader.value.single.status, DramaDownloadStatus.completed);
    // 整文件下载：只发过一次非 Range 请求。
    expect(cdn.receivedRanges, ['full']);
  });

  test('半成品跨启动续传：从已有字节起 Range 请求，终稿完整', () async {
    final half = cdn.content.sublist(0, 512);
    final partPath = '${videoDir.path}${Platform.pathSeparator}ep0.mp4.part';
    File(partPath).writeAsBytesSync(half);
    // 半成品比记录先存在，store 里没有记录——这正是重启后的形态。
    expect(await store.isDownloaded('ep0'), isFalse);

    final downloader = buildDownloader(
      resolve: (episode) async => EpisodeSource(cdn.url, 'abcd', const []),
    );
    await downloader.enqueue(drama: drama(1), episodes: drama(1).episodes);
    await settle(downloader);

    expect(cdn.receivedRanges, ['512-']);
    final record = await store.episode('ep0');
    expect(record!.bytes, 1024);
    expect(File(record.filePath).readAsBytesSync(), cdn.content);
    expect(File(partPath).existsSync(), isFalse);
  });

  test('并发上限：被 resolver 卡住时只有 concurrency 个任务在跑', () async {
    final barrier = Completer<void>();
    var resolverCalls = 0;
    final downloader = buildDownloader(
      concurrency: 2,
      resolve: (episode) async {
        resolverCalls++;
        await barrier.future;
        return EpisodeSource(cdn.url, 'abcd', const []);
      },
    );
    await downloader.enqueue(drama: drama(4), episodes: drama(4).episodes);
    // 两个槽位都卡在 resolver：2 下载中 + 2 排队。
    await _waitFor(() {
      final statuses = downloader.value.map((task) => task.status).toList();
      return statuses
                  .where((s) => s == DramaDownloadStatus.downloading)
                  .length ==
              2 &&
          statuses.where((s) => s == DramaDownloadStatus.waiting).length == 2;
    });
    barrier.complete();
    await settle(downloader);
    expect(
      downloader.value.every((t) => t.status == DramaDownloadStatus.completed),
      isTrue,
    );
    expect(resolverCalls, 4);
  });

  test('直链失效自动重取：第一次 403、第二次成功', () async {
    var calls = 0;
    final downloader = buildDownloader(
      resolve: (episode) async {
        calls++;
        return calls == 1
            ? EpisodeSource(cdn.staleUrl, 'k', const [])
            : EpisodeSource(cdn.url, 'abcd', const []);
      },
    );
    await downloader.enqueue(drama: drama(1), episodes: drama(1).episodes);
    await settle(downloader);
    expect(calls, 2);
    expect(downloader.value.single.status, DramaDownloadStatus.completed);
  });

  test('waiting 态任务可直接暂停，恢复前不会被 pump 捡走', () async {
    final gate = Completer<void>();
    final downloader = buildDownloader(
      concurrency: 1,
      resolve: (episode) async {
        await gate.future;
        return EpisodeSource(cdn.url, 'abcd', const []);
      },
    );
    await downloader.enqueue(drama: drama(2), episodes: drama(2).episodes);
    await _waitFor(() {
      final statuses = downloader.value.map((task) => task.status).toSet();
      return statuses.contains(DramaDownloadStatus.downloading) &&
          statuses.contains(DramaDownloadStatus.waiting);
    });
    downloader.pause('ep1');
    expect(
      downloader.value.firstWhere((task) => task.itemId == 'ep1').status,
      DramaDownloadStatus.paused,
    );
    gate.complete();
    await settle(downloader);
    // ep1 保持 paused（已暂停不算终态收敛，这里手动收敛判断 ep0 完成）。
    expect(
      downloader.value.firstWhere((task) => task.itemId == 'ep0').status,
      DramaDownloadStatus.completed,
    );
    expect(
      downloader.value.firstWhere((task) => task.itemId == 'ep1').status,
      DramaDownloadStatus.paused,
    );
  });

  test('下载中暂停后「继续」会真的下完，而不是立刻又回到暂停', () async {
    // 中止标志过去是只置位、从不清除的，于是「下载中暂停」过的任务永远无法
    // 恢复：下一轮 _runOnce 一进 339 行的判空就直接返回，状态又被写回 paused。
    final gate = Completer<void>();
    var resolveCalls = 0;
    final downloader = buildDownloader(
      concurrency: 1,
      resolve: (episode) async {
        resolveCalls++;
        if (resolveCalls == 1) await gate.future;
        return EpisodeSource(cdn.url, 'abcd', const []);
      },
    );
    await downloader.enqueue(drama: drama(1), episodes: drama(1).episodes);
    await _waitFor(
      () => downloader.value.single.status == DramaDownloadStatus.downloading,
    );

    downloader.pause('ep0');
    expect(downloader.value.single.status, DramaDownloadStatus.paused);

    // 放行被卡住的那次 resolve，让暂停的那一轮收敛。
    gate.complete();
    await _waitFor(
      () => downloader.value.single.status == DramaDownloadStatus.paused,
    );

    downloader.resume('ep0');
    await _waitFor(
      () => downloader.value.single.status == DramaDownloadStatus.completed,
    );
    expect(await store.isDownloaded('ep0'), isTrue, reason: '继续之后必须真的把这一集下完');
  });

  test('断网/计费链路自动暂停全部任务', () async {
    final barrier = Completer<void>();
    final downloader = buildDownloader(
      resolve: (episode) async {
        await barrier.future;
        return EpisodeSource(cdn.url, 'abcd', const []);
      },
    );
    await downloader.enqueue(drama: drama(2), episodes: drama(2).episodes);
    await _waitFor(
      () => downloader.value.every(
        (task) => task.status == DramaDownloadStatus.downloading,
      ),
    );
    downloader.updateConnectivity(online: true, metered: true);
    await _waitFor(
      () => downloader.value.every(
        (task) => task.status == DramaDownloadStatus.paused,
      ),
    );
    // WiFi 恢复不自动续跑：恢复是用户的动作（官方弹续传确认）。
    downloader.updateConnectivity(online: true, metered: false);
    expect(
      downloader.value.every(
        (task) => task.status == DramaDownloadStatus.paused,
      ),
      isTrue,
    );
    barrier.complete();
    // 暂停在 resolver 卡住期间已即时生效：放开后任务不得继续跑。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      downloader.value.every(
        (task) => task.status == DramaDownloadStatus.paused,
      ),
      isTrue,
    );
  });

  test('discard 清任务与半成品，不影响已完成集', () async {
    final gate = Completer<void>();
    final downloader = buildDownloader(
      resolve: (episode) async {
        await gate.future;
        return EpisodeSource(cdn.url, 'abcd', const []);
      },
    );
    await downloader.enqueue(drama: drama(1), episodes: drama(1).episodes);
    await _waitFor(() => downloader.value.isNotEmpty);
    await downloader.discard('ep0');
    gate.complete();
    expect(downloader.value.where((task) => task.itemId == 'ep0'), isEmpty);
    expect(
      File(
        '${videoDir.path}${Platform.pathSeparator}ep0.mp4.part',
      ).existsSync(),
      isFalse,
    );
  });

  test('删除已缓存集后引擎忘掉 completed 任务，重新入队会再下载', () async {
    final downloader = buildDownloader(
      resolve: (episode) async => EpisodeSource(cdn.url, 'abcd', const []),
    );
    await downloader.enqueue(drama: drama(1), episodes: drama(1).episodes);
    await settle(downloader);
    expect(downloader.value.single.status, DramaDownloadStatus.completed);

    // 管理页删记录（单集删除路径）：引擎必须跟着忘掉，否则重新缓存会被
    // enqueue 的 isDownloaded 短路——用户点了「下载」没有任何反应。
    await store.removeEpisode('ep0');
    await _waitFor(() => downloader.value.isEmpty);
    expect(await store.isDownloaded('ep0'), isFalse);

    await downloader.enqueue(drama: drama(1), episodes: drama(1).episodes);
    await settle(downloader);
    expect(downloader.value.single.status, DramaDownloadStatus.completed);
    final record = await store.episode('ep0');
    expect(record, isNotNull);
    expect(File(record!.filePath).existsSync(), isTrue);
  });

  test('手动重下已自动缓存的集，记录翻成用户所有（不会被滚动清理删掉）', () async {
    // 自动缓存已经把这集下完了，记录上是 auto: true。用户在缓存面板里手动
    // 再点一次这集时 enqueue 会因「已下载」短路——旧行为下记录原封不动，
    // 播放页的滚动清理于是把这集当自动缓存删掉（文件是用户明确要留的）。
    await store.saveEpisode(
      CachedEpisode(
        seriesId: 'series1',
        itemId: 'ep0',
        title: '第1集',
        index: 0,
        keyHex: 'abcd',
        height: 720,
        variantName: '720P',
        bytes: 1024,
        filePath: '${videoDir.path}${Platform.pathSeparator}ep0.mp4',
        cachedAt: 111,
        auto: true,
      ),
    );
    var resolveCalls = 0;
    final downloader = buildDownloader(
      resolve: (episode) async {
        resolveCalls++;
        return EpisodeSource(cdn.url, 'abcd', const []);
      },
    );

    await downloader.enqueue(drama: drama(1), episodes: drama(1).episodes);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final record = await store.episode('ep0');
    expect(record?.auto, isFalse, reason: '手动重下后清理不得再碰这一集');
    expect(record?.bytes, 1024, reason: '文件已在，不重拉也不改写其他字段');
    expect(record?.cachedAt, 111);
    expect(resolveCalls, 0, reason: '已下载的集不该重新排队');
    expect(downloader.value, isEmpty);
  });

  test('自动缓存排的任务把 auto 标记写到记录上', () async {
    final downloader = buildDownloader(
      resolve: (episode) async => EpisodeSource(cdn.url, 'abcd', const []),
    );
    await downloader.enqueue(
      drama: drama(1),
      episodes: drama(1).episodes,
      auto: true,
    );
    await settle(downloader);

    expect((await store.episode('ep0'))?.auto, isTrue);
  });

  test('画质上限：挑不超过上限的最高一档，没有更低的就用最低', () {
    final source = EpisodeSource('https://example.invalid/a.mp4', '', [
      const EpisodeVariant(
        name: '1080P',
        url: 'u1080',
        keyHex: '',
        height: 1080,
      ),
      const EpisodeVariant(name: '720P', url: 'u720', keyHex: '', height: 720),
      const EpisodeVariant(name: '480P', url: 'u480', keyHex: '', height: 480),
    ]);

    // 不设上限 = 最高档（原来的行为）。
    expect(DramaDownloader.pickVariant(source)?.name, '1080P');
    // 720 上限：给 720，而不是 480。
    expect(DramaDownloader.pickVariant(source, maxHeight: 720)?.name, '720P');
    // 上限比最小档还低：退回最小档，不能因为挑不到就失败。
    expect(DramaDownloader.pickVariant(source, maxHeight: 360)?.name, '480P');
    // 上限高于所有档位：取最高。
    expect(DramaDownloader.pickVariant(source, maxHeight: 2160)?.name, '1080P');

    // 上游只给单流（没有 variants）时，任何上限都用主地址。
    final flat = EpisodeSource('https://example.invalid/b.mp4');
    expect(
      DramaDownloader.pickVariant(flat, maxHeight: 480)?.url,
      'https://example.invalid/b.mp4',
    );
  });

  test('续传越界（HTTP 416）丢掉半成品重下，不会卡在失败', () async {
    // 半成品 500 字节，但重取地址后这条流只有 100 字节：Range 起点越界。
    final part = File('${videoDir.path}${Platform.pathSeparator}ep0.mp4.part')
      ..writeAsBytesSync(List.filled(500, 7));
    cdn.shortLength = 100;

    final downloader = buildDownloader(
      resolve: (episode) async => EpisodeSource(cdn.url, 'abcd', const []),
    );
    await downloader.enqueue(drama: drama(1), episodes: drama(1).episodes);
    await settle(downloader);

    final task = downloader.value.single;
    expect(task.status, DramaDownloadStatus.completed, reason: '${task.error}');
    expect(part.existsSync(), isFalse, reason: '越界的半成品要被丢掉');
    final saved = File('${videoDir.path}${Platform.pathSeparator}ep0.mp4');
    expect(saved.lengthSync(), 100);
  });

  test('续传越界丢掉半成品时，界面上的字节数跟着归零', () async {
    // 第一次尝试下到一半断流（进度已发布为 500/1024），重取地址后拿到一条
    // 更短的流（100 字节）→ Range 越界（416）→ 半成品被丢掉。这时快照里
    // 还挂着旧字节数的话，重下期间进度条读到 100%，最后的硬失败还会带着
    // 一个已经不存在的 received。
    final part = File('${videoDir.path}${Platform.pathSeparator}ep0.mp4.part')
      ..writeAsBytesSync(List.filled(500, 7));
    cdn.truncateTo = 100;
    var resolveCalls = 0;
    final downloader = buildDownloader(
      resolve: (episode) async {
        resolveCalls++;
        // 第二轮起换一条短流 → 416；第三轮直接抛错，让任务停在失败态。
        if (resolveCalls >= 2) {
          cdn.shortLength = 100;
          cdn.truncateTo = null;
        }
        if (resolveCalls >= 3) throw const SocketException('连接被重置');
        return EpisodeSource(cdn.url, 'abcd', const []);
      },
    );

    await downloader.enqueue(drama: drama(1), episodes: drama(1).episodes);
    await settle(downloader);

    final task = downloader.value.single;
    expect(task.status, DramaDownloadStatus.failed, reason: '${task.error}');
    expect(part.existsSync(), isFalse, reason: '越界的半成品已被丢掉');
    expect(task.received, 0, reason: '半成品没了，进度不能还挂着旧字节数');
    expect(task.total, isNull);
  });

  test('取流偶发失败会自动重试，最终完成', () async {
    var calls = 0;
    final downloader = buildDownloader(
      resolve: (episode) async {
        calls++;
        // 前两次抛网络错（CDN 抽风），第三次给正常地址。
        if (calls <= 2) throw const SocketException('连接被重置');
        return EpisodeSource(cdn.url, 'abcd', const []);
      },
    );
    await downloader.enqueue(drama: drama(1), episodes: drama(1).episodes);
    await settle(downloader);

    expect(calls, 3, reason: '失败两次后第三次应成功');
    expect(downloader.value.single.status, DramaDownloadStatus.completed);
    expect(downloader.value.single.error, isNull);
  });

  test('重试用尽后标失败并把原因留在任务上', () async {
    final downloader = buildDownloader(
      resolve: (episode) async => throw const SocketException('连接被重置'),
    );
    await downloader.enqueue(drama: drama(1), episodes: drama(1).episodes);
    await settle(downloader);

    final task = downloader.value.single;
    expect(task.status, DramaDownloadStatus.failed);
    expect(task.error, contains('SocketException'));
  });

  test('删除整剧同样清掉该剧的 completed 任务', () async {
    final downloader = buildDownloader(
      resolve: (episode) async => EpisodeSource(cdn.url, 'abcd', const []),
    );
    await downloader.enqueue(drama: drama(2), episodes: drama(2).episodes);
    await settle(downloader);
    expect(downloader.value.length, 2);

    await store.removeDrama('series1');
    await _waitFor(() => downloader.value.isEmpty);
  });
}

Future<void> _waitFor(bool Function() condition) async {
  const timeout = Duration(seconds: 10);
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('条件在时限内未满足');
}
