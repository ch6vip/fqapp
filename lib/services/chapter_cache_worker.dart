import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:hive_ce/hive.dart';

import 'app_log.dart';
import 'chapter_cache_storage.dart';

export 'chapter_cache_storage.dart' show ChapterCacheCommand;

/// Owns one long-lived isolate; no Hive handle or secure-storage plugin crosses
/// the boundary. Replies contain only requested text or catalogue metadata.
class ChapterCacheWorker {
  ChapterCacheWorker._() {
    _responses.listen(_receive);
  }

  final _responses = ReceivePort();
  final _ready = Completer<ChapterCacheWorker>();
  final _pending = <int, Completer<dynamic>>{};
  Isolate? _isolate;
  SendPort? _commands;
  Future<void>? _closing;
  int _nextId = 0;
  bool _closed = false;
  int textEncodes = 0;

  bool get isClosed => _closed;

  static Future<ChapterCacheWorker> start({
    required String path,
    required Uint8List encryptionKey,
    required int maxEntries,
    required int maxBytes,
    required Duration catalogTtl,
  }) async {
    final worker = ChapterCacheWorker._();
    worker._ready.future.ignore();
    try {
      worker._isolate = await Isolate.spawn(
        _runCache,
        (
          replies: worker._responses.sendPort,
          path: path,
          encryptionKey: encryptionKey,
          maxEntries: maxEntries,
          maxBytes: maxBytes,
          catalogTtl: catalogTtl,
        ),
        onError: worker._responses.sendPort,
        onExit: worker._responses.sendPort,
        debugName: 'chapter-cache',
      );
      return await worker._ready.future;
    } catch (_) {
      worker._dispose();
      rethrow;
    }
  }

  Future<dynamic> request(
    ChapterCacheCommand command, [
    Map<String, dynamic> args = const {},
  ]) {
    if (_closed ||
        _commands == null ||
        (_closing != null && command != ChapterCacheCommand.close)) {
      return Future.error(StateError('Chapter cache worker is closed'));
    }
    final id = _nextId++;
    final result = Completer<dynamic>();
    _pending[id] = result;
    _commands!.send((id, command, args));
    return result.future;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    try {
      await request(ChapterCacheCommand.close);
    } finally {
      _dispose();
    }
  }

  void _receive(dynamic message) {
    if (message is LogEntry) {
      switch (message.level) {
        case LogLevel.debug:
          AppLog.d(message.tag, message.message);
        case LogLevel.info:
          AppLog.i(message.tag, message.message);
        case LogLevel.warn:
          AppLog.w(message.tag, message.message);
        case LogLevel.error:
          AppLog.e(message.tag, message.message);
      }
      return;
    }
    if (message is SendPort) {
      _commands = message;
      _ready.complete(this);
      return;
    }
    if (message is (int, dynamic, String?, String?, int)) {
      final (id, value, error, stack, encodes) = message;
      textEncodes = encodes;
      final pending = _pending.remove(id);
      if (error == null) {
        pending?.complete(value);
      } else {
        pending?.completeError(
          StateError(error),
          StackTrace.fromString(stack ?? ''),
        );
      }
      return;
    }
    final error = StateError(
      message is List && message.isNotEmpty
          ? 'Chapter cache worker failed: ${message.first}'
          : 'Chapter cache worker exited',
    );
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    _dispose();
  }

  void _dispose() {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      pending.completeError(StateError('Chapter cache worker is closed'));
    }
    _pending.clear();
    _responses.close();
    _isolate?.kill(priority: Isolate.immediate);
  }
}

typedef _CacheStart = ({
  SendPort replies,
  String path,
  Uint8List encryptionKey,
  int maxEntries,
  int maxBytes,
  Duration catalogTtl,
});

Future<void> _runCache(_CacheStart start) async {
  Hive.init(start.path);
  final log = AppLog.instance;
  void forwardLog() => start.replies.send(log.entries.last);
  log.revision.addListener(forwardLog);
  final storage = ChapterCacheStorage(
    encryptionKey: start.encryptionKey,
    maxEntries: start.maxEntries,
    maxBytes: start.maxBytes,
    catalogTtl: start.catalogTtl,
  );
  final commands = ReceivePort();
  start.replies.send(commands.sendPort);
  try {
    await for (final message in commands) {
      final (id, command, args) =
          message as (int, ChapterCacheCommand, Map<String, dynamic>);
      try {
        final value = await storage.execute(command, args);
        start.replies.send((id, value, null, null, storage.textEncodes));
      } catch (error, stack) {
        start.replies.send((
          id,
          null,
          error.toString(),
          stack.toString(),
          storage.textEncodes,
        ));
      }
      if (command == ChapterCacheCommand.close) break;
    }
  } finally {
    commands.close();
    await Hive.close();
    log.revision.removeListener(forwardLog);
  }
}
