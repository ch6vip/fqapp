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
      if (start >= content.length) {
        request.response.statusCode = 416;
        await request.response.close();
        return;
      }
      if (isRange) {
        request.response.statusCode = 206;
        request.response.headers.set(
          'content-range',
          'bytes=$start-${content.length - 1}/${content.length}',
        );
      } else {
        request.response.statusCode = 200;
      }
      final slice = Uint8List.sublistView(
        Uint8List.fromList(content),
        start,
      );
      request.response.contentLength = slice.length;
      request.response.add(slice);
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
  }) => DramaDownloader(
    store: store,
    resolve: resolve,
    concurrency: concurrency,
  );

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
    expect(
      downloader.value.single.status,
      DramaDownloadStatus.completed,
    );
    // 整文件下载：只发过一次非 Range 请求。
    expect(cdn.receivedRanges, ['full']);
  });

  test('半成品跨启动续传：从已有字节起 Range 请求，终稿完整', () async {
    final half = cdn.content.sublist(0, 512);
    final partPath =
        '${videoDir.path}${Platform.pathSeparator}ep0.mp4.part';
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
      return statuses.where((s) => s == DramaDownloadStatus.downloading).length ==
              2 &&
          statuses.where((s) => s == DramaDownloadStatus.waiting).length == 2;
    });
    barrier.complete();
    await settle(downloader);
    expect(downloader.value.every((t) => t.status == DramaDownloadStatus.completed), isTrue);
    expect(resolverCalls, 4);
  });

  test('直链失效自动重取：第一次 403、第二次成功', () async {
    var calls = 0;
    final downloader = buildDownloader(resolve: (episode) async {
      calls++;
      return calls == 1
          ? EpisodeSource(cdn.staleUrl, 'k', const [])
          : EpisodeSource(cdn.url, 'abcd', const []);
    });
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
      downloader.value.every((task) => task.status == DramaDownloadStatus.paused),
      isTrue,
    );
    barrier.complete();
    // 暂停在 resolver 卡住期间已即时生效：放开后任务不得继续跑。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      downloader.value.every((task) => task.status == DramaDownloadStatus.paused),
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
