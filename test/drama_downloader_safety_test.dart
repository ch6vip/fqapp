import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/drama_download_store.dart';
import 'package:fqapp/services/drama_downloader.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'support/fakes.dart';

void main() {
  test('拒绝不安全的 episode itemId，且 discard 在任何文件操作前失败', () async {
    final root = await Directory.systemTemp.createTemp('drama-id-check-');
    final directory = Directory('${root.path}/offline')..createSync();
    addTearDown(() => root.delete(recursive: true));
    final store = MemoryDramaDownloadStore(videoDirectory: directory);
    final downloader = DramaDownloader(store: store);
    final unsafe = Chapter(itemId: '../outside', title: '越界', volumeName: '');
    final drama = CachedDrama(
      id: 'series',
      title: '测试剧',
      cover: '',
      episodes: [unsafe],
    );

    await expectLater(
      downloader.enqueue(drama: drama, episodes: [unsafe]),
      throwsArgumentError,
    );
    await expectLater(downloader.discard('../outside'), throwsArgumentError);
    expect(downloader.value, isEmpty);
    expect(await store.hasCatalogue('series'), isFalse);
    expect(await File('${root.path}/outside.mp4.part').exists(), isFalse);
  });

  test('拒绝 Content-Range 起始偏移与本地续传长度不符的响应', () async {
    final directory = await Directory.systemTemp.createTemp('drama-range-check-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    server.listen((request) async {
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 2-5/6');
      request.response.contentLength = 4;
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });

    final store = MemoryDramaDownloadStore(videoDirectory: directory);
    await File('${directory.path}/ep1.mp4.part').writeAsBytes([9, 8, 7]);
    final downloader = DramaDownloader(
      store: store,
      resolve: (_) async => EpisodeSource(
        'http://${InternetAddress.loopbackIPv4.address}:${server.port}/video',
        'key',
        const [],
      ),
    );
    await downloader.enqueue(
      drama: CachedDrama(
        id: 'series',
        title: '测试剧',
        cover: '',
        episodes: [Chapter(itemId: 'ep1', title: '第 1 集', volumeName: '')],
      ),
      episodes: [Chapter(itemId: 'ep1', title: '第 1 集', volumeName: '')],
    );

    final task = await _waitForTerminalTask(downloader);
    expect(task.status, DramaDownloadStatus.failed);
    expect(await store.isDownloaded('ep1'), isFalse);
    expect(await File('${directory.path}/ep1.mp4').exists(), isFalse);
  });

  test('未知总长度的响应不会登记为完整下载', () async {
    final directory = await Directory.systemTemp.createTemp('drama-unknown-size-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    server.listen((request) async {
      request.response.headers.chunkedTransferEncoding = true;
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });

    final store = MemoryDramaDownloadStore(videoDirectory: directory);
    final downloader = DramaDownloader(
      store: store,
      resolve: (_) async => EpisodeSource(
        'http://${InternetAddress.loopbackIPv4.address}:${server.port}/video',
        'key',
        const [],
      ),
    );
    await downloader.enqueue(
      drama: CachedDrama(
        id: 'series',
        title: '测试剧',
        cover: '',
        episodes: [Chapter(itemId: 'ep2', title: '第 2 集', volumeName: '')],
      ),
      episodes: [Chapter(itemId: 'ep2', title: '第 2 集', volumeName: '')],
    );

    final task = await _waitForTerminalTask(downloader);
    expect(task.status, DramaDownloadStatus.failed);
    expect(await store.isDownloaded('ep2'), isFalse);
    expect(await File('${directory.path}/ep2.mp4').exists(), isFalse);
    expect(await File('${directory.path}/ep2.mp4.part').exists(), isTrue);
  });
}

Future<DramaDownloadTask> _waitForTerminalTask(DramaDownloader downloader) async {
  for (var i = 0; i < 300; i++) {
    final tasks = downloader.value;
    if (tasks.isNotEmpty &&
        (tasks.single.status == DramaDownloadStatus.completed ||
            tasks.single.status == DramaDownloadStatus.failed)) {
      return tasks.single;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('download task did not finish');
}
