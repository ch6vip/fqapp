import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/media_item.dart';

/// Where a finished export landed, as the platform reported it.
@immutable
class ExportTarget {
  const ExportTarget({required this.path, required this.isPublic});

  /// Path shown to the user. Either the shared Downloads entry or, on Android
  /// 9 and older, the app's own external directory.
  final String path;

  /// Whether [path] is the shared Downloads collection instead of app-private
  /// storage. The completion message has to tell the two apart: a private file
  /// is not where the file manager looks.
  final bool isPublic;
}

/// Thrown when the platform could not store the exported text.
class ExportWriteException implements Exception {
  const ExportWriteException([this.message = '写入失败']);

  final String message;

  @override
  String toString() => 'ExportWriteException: $message';
}

/// Stores a finished TXT somewhere the user can reach. Abstracted so tests can
/// capture the text without a platform channel.
abstract class TxtSink {
  Future<ExportTarget> saveText({
    required String fileName,
    required String text,
  });
}

/// The system Downloads collection through the `fqapp/downloads` channel.
///
/// Android 10 (API 29) and newer insert into `MediaStore.Downloads`, which
/// needs no storage permission; older devices fall back to the app's external
/// directory and report `public: false` so the caller does not claim the file
/// is in Downloads. See `.agents/notes/implemented/feature/`.
class PlatformTxtSink implements TxtSink {
  const PlatformTxtSink() : _channel = _channelName;

  static const _channelName = MethodChannel('fqapp/downloads');

  final MethodChannel _channel;

  @override
  Future<ExportTarget> saveText({
    required String fileName,
    required String text,
  }) async {
    final Map<String, Object?>? result;
    try {
      result = await _channel.invokeMapMethod<String, Object?>('saveText', {
        'fileName': fileName,
        'text': text,
      });
    } on PlatformException catch (error) {
      throw ExportWriteException(error.message ?? '写入失败');
    } on MissingPluginException {
      // Desktop and test hosts have no Android plugin: never report success.
      throw const ExportWriteException('当前平台不支持导出到 Downloads');
    }
    final path = result?['path'];
    if (path is! String || path.isEmpty) {
      throw const ExportWriteException('系统未返回导出路径');
    }
    return ExportTarget(path: path, isPublic: result?['public'] == true);
  }
}

/// Progress of one whole-book export, in the shape the cache page renders.
@immutable
class BookTxtExportState {
  const BookTxtExportState({
    this.running = false,
    this.completed = 0,
    this.total = 0,
    this.failed = 0,
    this.target,
    this.message,
  });

  final bool running;
  final int completed;
  final int total;

  /// Chapters whose body could not be fetched. They keep their `# 标题` line so
  /// the file still shows the book's shape, and the final message says how many
  /// they were instead of quietly shipping a shorter book.
  final int failed;

  /// Set only after a successful write.
  final ExportTarget? target;

  /// Final report, or the stop notice. Null while the export runs.
  final String? message;

  double get fraction => total == 0 ? 0 : completed / total;
}

/// Whole-book TXT export: a fresh directory plus every chapter re-fetched from
/// the network, assembled in the same shape the backend's `/api/download`
/// serves (`# 标题` line, body, blank line).
///
/// Nothing is written until the last chapter is in hand: a cancelled or failed
/// export must not leave a half book in Downloads that looks complete.
///
/// Chapter bodies are fetched through [chapterLoader], which production wires to
/// `ApiClient.contentText` — the single request funnel CRIT-005 requires.
class BookTxtExport extends ValueNotifier<BookTxtExportState> {
  BookTxtExport({
    required this.directoryLoader,
    required this.chapterLoader,
    required this.sink,
    this.timeout = const Duration(seconds: 30),
  }) : super(const BookTxtExportState());

  /// Fresh directory per export: chapters added since the book was cached must
  /// make it into the file.
  final Future<List<Chapter>> Function(String bookId) directoryLoader;

  final Future<String> Function(Chapter chapter) chapterLoader;
  final TxtSink sink;
  final Duration timeout;

  int _job = 0;
  bool _disposed = false;

  /// Runs one export. Ignored while another is in flight, so a double tap
  /// cannot start two of them.
  Future<void> start({required String bookId, required String title}) async {
    if (_disposed || value.running) return;
    final job = ++_job;
    value = const BookTxtExportState(running: true);

    final List<Chapter> chapters;
    try {
      chapters = await directoryLoader(bookId).timeout(timeout);
    } catch (_) {
      if (_alive(job)) {
        value = const BookTxtExportState(message: '导出失败：目录获取失败，请检查网络后重试');
      }
      return;
    }
    if (!_alive(job)) return;
    if (chapters.isEmpty) {
      value = const BookTxtExportState(message: '导出失败：这本书没有可导出的章节');
      return;
    }

    final buffer = StringBuffer();
    var completed = 0;
    var failed = 0;
    value = BookTxtExportState(running: true, total: chapters.length);
    for (final chapter in chapters) {
      if (!_alive(job)) return;
      buffer.write('# ${chapter.title}\n');
      try {
        final body = (await chapterLoader(chapter).timeout(timeout)).trim();
        if (!_alive(job)) return;
        if (body.isNotEmpty) {
          buffer.write(body);
          buffer.write('\n');
        }
      } catch (_) {
        if (!_alive(job)) return;
        // One dead chapter must not cost the user the other 999.
        failed++;
      }
      buffer.write('\n');
      completed++;
      value = BookTxtExportState(
        running: true,
        completed: completed,
        total: chapters.length,
        failed: failed,
      );
    }
    if (!_alive(job)) return;

    final ExportTarget target;
    try {
      target = await sink.saveText(
        fileName: exportFileName(title),
        text: buffer.toString(),
      );
    } catch (_) {
      if (_alive(job)) {
        value = const BookTxtExportState(message: '导出失败：写入 Downloads 失败，请重试');
      }
      return;
    }
    if (!_alive(job)) return;
    value = BookTxtExportState(
      completed: completed,
      total: chapters.length,
      failed: failed,
      target: target,
      message: _report(title, target, completed, failed),
    );
  }

  /// Stops the running export. Nothing was written yet, so nothing is left
  /// behind in Downloads.
  void cancel() {
    ++_job;
    final state = value;
    value = BookTxtExportState(
      completed: state.completed,
      total: state.total,
      failed: state.failed,
      message: '已取消导出，未写入文件',
    );
  }

  @override
  void dispose() {
    _disposed = true;
    ++_job;
    super.dispose();
  }

  bool _alive(int job) => !_disposed && job == _job;
}

String _report(String title, ExportTarget target, int completed, int failed) {
  final where = target.isPublic ? target.path : '${target.path}（应用私有目录）';
  final missing = failed == 0 ? '' : '，$failed 章取文失败，已保留标题';
  return '已导出《$title》$completed 章$missing\n$where';
}

/// `<书名>.txt`, folded into a name a Downloads entry accepts: separators and
/// other reserved characters become `_`, control characters are dropped, and
/// the stem is capped so no file manager sees a truncated extension.
String exportFileName(String title) {
  var name = title
      .replaceAll(_unsafe, '_')
      .replaceAll(_control, '')
      .replaceAll(_whitespace, ' ')
      .trim();
  name = name.replaceAll(_edgeDots, '');
  if (name.isEmpty) name = 'book';
  // Cap by runes: cutting a surrogate pair would produce an invalid name.
  final runes = name.runes.toList();
  if (runes.length > _maxStem) {
    name = String.fromCharCodes(runes.take(_maxStem)).trimRight();
  }
  return '$name.txt';
}

final _unsafe = RegExp(r'[\\/:*?"<>|]');
final _control = RegExp(r'[\x00-\x1f\x7f]');
final _whitespace = RegExp(r'\s+');
final _edgeDots = RegExp(r'^[.\s]+|[.\s]+$');
const _maxStem = 80;
