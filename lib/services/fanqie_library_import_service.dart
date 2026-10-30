import 'platform_channel.dart';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/fanqie_library_capture.dart';
import '../models/fanqie_library_import.dart';
import '../models/media_item.dart';
import 'api_client.dart';
import 'backend_transport.dart';
import 'library_store.dart';
import 'shelf_store.dart';

class FanqieImportPreview {
  final List<Map<String, dynamic>> records;
  final int matched;
  final int unresolved;
  final int skipped;
  const FanqieImportPreview(
    this.records,
    this.matched,
    this.unresolved,
    this.skipped,
  );
}

class FanqieLibraryImportService {
  static const _files = AppMethodChannel('fqapp/library_backup');

  Future<FanqieImportPreview> prepare(
    FanqieLibraryCapture capture,
    BackendRequest request,
    void Function(String) progress, {
    // 仅测试注入；生产缺省走 ApiClient.directoryChapters。
    Future<List<List<Chapter>>> Function(String bookId)? directoryLoader,
  }) async {
    final parser = FanqieLibraryImport();
    void checkCancelled() {
      if (request.isCancelled) throw BackendRequestAborted('请求已取消');
    }

    if (capture.parts.isEmpty) {
      for (final source in capture.sources) {
        parser.addSource(source);
      }
    } else {
      var totalBytes = 0;
      for (final name in capture.parts.toSet()) {
        checkCancelled();
        final bytes = await _files.invokeMethod<Uint8List>(
          'readFanqieCapturePart',
          {'name': name},
        );
        if (bytes == null) throw const FormatException('原始分卷缺失，未导入');
        totalBytes += bytes.length;
        if (totalBytes > 128 * 1024 * 1024) {
          throw const FormatException('采集分卷总量超过 128 MB，未导入');
        }
        final part = jsonDecode(utf8.decode(bytes));
        if (part is! Map ||
            part['format'] != 'fqapp.fanqie-library-part' ||
            part['version'] != 1 ||
            part['sources'] is! List) {
          throw const FormatException('原始分卷格式不兼容，未导入');
        }
        for (final source in part['sources'] as List) {
          if (source is! Map<String, dynamic>) {
            throw const FormatException('原始响应格式不兼容，未导入');
          }
          parser.addSource(source);
        }
      }
    }
    final records = parser.records;
    if (records.length > 10000) throw const FormatException('小说超过 10000 本，未导入');
    var matched = 0;
    var unresolved = 0;
    var done = 0;
    final load = directoryLoader ?? ApiClient.instance.directoryChapters;
    await ApiClient.instance.withCancellation(request, () async {
      // 有界并发：最多 4 个目录请求同时在途，避免对一万本书一次性发起请求
      // 风暴，同时比原来的串行快一个数量级。第一个请求失败（取消或超时）后
      // 不再领取新书，等在途请求收尾再把错误抛给调用方。
      const maxConcurrent = 4;
      var next = 0;
      (Object, StackTrace)? failure;
      Future<void> worker() async {
        while (failure == null) {
          final index = next++;
          if (index >= records.length) return;
          try {
            checkCancelled();
            final record = records[index];
            progress('解析小说 ${++done}/${records.length}，已匹配 $matched 个章节');
            final chapterId = record['chapterId'];
            if (chapterId == null) continue;
            final chapters = (await load(
              record['id'] as String,
            )).expand((volume) => volume).toList();
            if (resolveFanqieChapter(record, chapters)) {
              matched++;
            } else {
              unresolved++;
            }
          } on BackendRequestAborted catch (error, stack) {
            failure ??= (error, stack);
            return;
          } on Exception {
            // Keep the stable chapter ID. The normal reader resolves it again
            // against the current directory when this book is opened.
            unresolved++;
          }
        }
      }

      await Future.wait([for (var i = 0; i < maxConcurrent; i++) worker()]);
      if (failure case (final error, final stack)) {
        Error.throwWithStackTrace(error, stack);
      }
    });
    checkCancelled();
    return FanqieImportPreview(records, matched, unresolved, parser.skipped);
  }

  Future<({int shelf, int history})> merge(FanqieImportPreview preview) async {
    if (!ShelfStore.instance.isReady) throw StateError('书架尚未初始化');
    final history = await LibraryStore.instance.mergeFanqie(preview.records);
    final shelf = await ShelfStore.instance.mergeFanqie([
      for (final record in preview.records)
        ShelfRecord(
          item: MediaItem(
            id: record['id'] as String,
            title: (record['title'] as String).isEmpty
                ? '未知作品'
                : record['title'] as String,
            cover: record['cover'] as String,
            author: record['author'] as String,
            ep: record['ep'] as String? ?? '',
            kind: 'book',
            badge: '',
          ),
          addedAt: DateTime.fromMillisecondsSinceEpoch(record['time'] as int),
        ),
    ]);
    return (shelf: shelf, history: history);
  }
}
