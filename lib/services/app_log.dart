import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// 日志级别（从轻到重）。
enum LogLevel {
  debug,
  info,
  warn,
  error;

  String get label => switch (this) {
    LogLevel.debug => '调试',
    LogLevel.info => '资讯',
    LogLevel.warn => '警告',
    LogLevel.error => '错误',
  };

  String get token => switch (this) {
    LogLevel.debug => 'D',
    LogLevel.info => 'I',
    LogLevel.warn => 'W',
    LogLevel.error => 'E',
  };
}

/// 单条日志。
///
/// 隐私纪律沿用 `PlayerLoadSample` 的契约：只记方法/状态/耗时/标签，
/// **绝不记录 URL 中的参数、秘钥、请求体或任何敏感字段**。
class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  const LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });

  String format() =>
      '[${level.token}] ${time.toIso8601String()} $tag: $message';
}

/// 应用内日志核心：内存环形缓冲 + 捕获框架/未捕获异步异常 + 文件轮换持久化。
///
/// 使用方式：
/// - `AppLog.instance.install()` 在 `main()` 尽早调用一次，接管 `debugPrint`
///   与 `FlutterError.onError`；
/// - `AppLog.instance.startPersistence()` 异步开启文件轮换（失败只退回内存模式，
///   不阻塞启动）；
/// - 通过 `static` 助手 `d/i/w/e` 记录业务日志。
class AppLog with WidgetsBindingObserver {
  AppLog._();

  static final AppLog instance = AppLog._();

  static const int defaultCapacity = 1000;
  static const String logDirName = 'logs';
  static const String logFileName = 'app.log';

  final List<LogEntry> _entries = <LogEntry>[];

  /// 上次会话从落盘文件回读的条目：只用于查看与导出，不再写回文件（避免重复）。
  final List<LogEntry> _history = <LogEntry>[];
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  int _capacity = defaultCapacity;
  LogLevel _minLevel = LogLevel.debug;
  FileLogWriter? _file;

  /// 定时 flush 句柄；只在开启落盘后存在。
  Timer? _flushTimer;

  /// 自上次 flush 以来是否有新条目（无新条目时定时器不空转写盘）。
  bool _dirty = false;

  /// 串行化落盘，避免多条日志并发 append 造成交错。
  Future<void> _pendingWrite = Future<void>.value();
  DebugPrintCallback? _previousDebugPrint;
  FlutterExceptionHandler? _previousOnError;
  bool _observing = false;

  /// 当前可查看的日志 = 上次会话回读 + 本次会话内存缓冲（只读视图）。
  List<LogEntry> get entries => List.unmodifiable([..._history, ..._entries]);

  /// 是否已被 [install] 接管（用于测试与幂等保护）。
  bool installed = false;

  int get capacity => _capacity;
  LogLevel get minLevel => _minLevel;

  // ── 安装与捕获 ─────────────────────────────────────────────────────────

  /// 接管 [debugPrint] 与 [FlutterError.onError]，把框架与业务打印收进环形缓冲。
  ///
  /// 安全：始终链到上一层实现，保证原有控制台输出不被吞掉。
  void install({
    int capacity = defaultCapacity,
    LogLevel minLevel = LogLevel.debug,
  }) {
    if (installed) return;
    installed = true;
    _capacity = capacity;
    _minLevel = minLevel;

    final previousDebugPrint = debugPrint;
    _previousDebugPrint = previousDebugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      // 链到旧实现，保持原有控制台行为。
      previousDebugPrint(message, wrapWidth: wrapWidth);
      if (message == null || message.isEmpty) return;
      if (levelThreshold(LogLevel.debug)) {
        _emit(LogLevel.debug, 'flutter', message);
      }
    };

    final previousError = FlutterError.onError;
    _previousOnError = previousError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _emit(LogLevel.error, 'framework', details.toString());
      previousError?.call(details);
    };

    _attachLifecycle();
  }

  /// 还原被接管的 [debugPrint] 与 [FlutterError.onError]。
  ///
  /// 生产不需要（进程结束即还原），主要为测试与热重启后的卫生服务。
  void uninstall() {
    _detachLifecycle();
    _stopFlushTimer();
    if (!installed) return;
    if (_previousDebugPrint != null) debugPrint = _previousDebugPrint!;
    FlutterError.onError = _previousOnError;
    _previousDebugPrint = null;
    _previousOnError = null;
    installed = false;
  }

  /// 监听应用生命周期，退到后台/被杀前把缓冲刷进文件。
  ///
  /// 纯 Dart 单测没有 WidgetsBinding，此时静默跳过。
  void _attachLifecycle() {
    if (_observing) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    } catch (_) {
      // 无 binding 的环境（单元测试）：不影响内存日志与落盘。
    }
  }

  void _detachLifecycle() {
    if (!_observing) return;
    _observing = false;
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(flush());
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// 判定某个级别是否应当被记录（相对 `_minLevel`）。
  bool levelThreshold(LogLevel level) => level.index >= _minLevel.index;

  // ── 记录 ───────────────────────────────────────────────────────────────

  static void d(String tag, String message) =>
      instance._emit(LogLevel.debug, tag, message);
  static void i(String tag, String message) =>
      instance._emit(LogLevel.info, tag, message);
  static void w(
    String tag,
    String message, {
    Object? error,
    StackTrace? stack,
  }) => instance._emit(LogLevel.warn, tag, message, error: error, stack: stack);
  static void e(
    String tag,
    String message, {
    Object? error,
    StackTrace? stack,
  }) =>
      instance._emit(LogLevel.error, tag, message, error: error, stack: stack);

  void _emit(
    LogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    if (level.index < _minLevel.index) return;
    final entry = LogEntry(
      time: DateTime.now(),
      level: level,
      tag: tag,
      message: _compose(message, error, stack),
    );
    _entries.add(entry);
    if (_entries.length > _capacity) _entries.removeAt(0);
    revision.value++;
    // 不 await：落盘失败只丢该条，不影响内存日志；但写入串行，保证文件内不交错。
    final writer = _file;
    if (writer != null) {
      _dirty = true;
      _pendingWrite = _pendingWrite
          .then((_) => writer.append(entry.format()))
          .catchError((Object _) {});
      // 警告/错误是事后排障最需要的几条，不等定时窗口，立刻落盘。
      if (level.index >= LogLevel.warn.index) unawaited(flush());
    }
  }

  String _compose(String message, Object? error, StackTrace? stack) {
    final buf = StringBuffer(message);
    if (error != null) buf.write('\n  error: $error');
    if (stack != null) buf.write('\n  ${stack.toString().trimRight()}');
    return buf.toString();
  }

  /// 清空当前可查看的日志（历史 + 本次会话）；不删除落盘文件。
  void clear() {
    _history.clear();
    _entries.clear();
    revision.value++;
  }

  // ── 文件持久化 ─────────────────────────────────────────────────────────

  /// 开启文件轮换持久化。`directory` 仅供测试注入；生产用应用私有目录。
  ///
  /// 任何失败都只退化为「内存模式」，绝不抛给调用方（启动路径）。
  Future<void> startPersistence({
    Directory? directory,
    Duration flushInterval = const Duration(seconds: 5),
  }) async {
    if (_file != null) return;
    Directory? dir = directory;
    if (dir == null) {
      try {
        final support = await getApplicationSupportDirectory();
        dir = Directory('${support.path}/$logDirName');
      } catch (_) {
        return; // 拿不到私有目录：纯内存模式。
      }
    }
    try {
      final writer = FileLogWriter(dir);
      await writer.open();
      // 回读上次会话：文件只追加，但**只有回读**才能让重启/崩溃后在日志页
      // 看到上一次运行；历史单独存放，不参与下面的写回，避免重复落盘。
      await _loadHistory(dir);
      // 把开启前已缓冲的条目先写进去，再从当前尾部续写。
      for (final entry in List.of(_entries)) {
        await writer.append(entry.format());
      }
      await writer.flush();
      _file = writer;
      _startFlushTimer(flushInterval);
    } catch (_) {
      _file = null;
    }
  }

  /// 回读上次会话落盘日志（含崩溃前没来得及走生命周期回调的那部分）。
  ///
  /// 回读失败只意味着看不到历史，不影响本次会话继续落盘。
  Future<void> _loadHistory(Directory dir) async {
    final file = File('${dir.path}/$logFileName');
    if (!file.existsSync()) return;
    try {
      final parsed = parseLogLines(await file.readAsLines());
      if (parsed.isEmpty) return;
      _history
        ..clear()
        ..addAll(
          parsed.length > _capacity
              ? parsed.sublist(parsed.length - _capacity)
              : parsed,
        );
    } catch (_) {
      // 回读失败只丢历史视图。
    }
  }

  /// 解析落盘行：形态是 `[级别] ISO 标签: 消息`。消息可以多行，匹配不上的行
  /// 按「上一条的续行」处理，多行异常栈回读后仍是同一条。
  static List<LogEntry> parseLogLines(List<String> lines) {
    final result = <LogEntry>[];
    LogLevel? level;
    DateTime? time;
    String? tag;
    final message = StringBuffer();

    void flushEntry() {
      final l = level;
      final t = time;
      final g = tag;
      if (l == null || t == null || g == null) return;
      result.add(
        LogEntry(time: t, level: l, tag: g, message: message.toString()),
      );
    }

    for (final line in lines) {
      final match = _entryPattern.firstMatch(line);
      if (match == null) {
        // 续行接到上一条；文件开头的无主续行直接忽略。
        if (level != null) {
          if (message.isNotEmpty) message.write('\n');
          message.write(line);
        }
        continue;
      }
      flushEntry();
      level = _levelFromToken(match.group(1)!);
      time = DateTime.tryParse(match.group(2)!) ?? DateTime.now();
      tag = match.group(3)!;
      message
        ..clear()
        ..write(match.group(4)!);
    }
    flushEntry();
    return result;
  }

  static final RegExp _entryPattern = RegExp(
    r'^\[([DIWE])\] (\S+) ([^:]*): (.*)$',
  );

  static LogLevel _levelFromToken(String token) => switch (token) {
    'E' => LogLevel.error,
    'W' => LogLevel.warn,
    'I' => LogLevel.info,
    _ => LogLevel.debug,
};

  /// 当前落盘日志文件路径（未开启持久化为 null）。
  String? get filePath => _file?.currentPath;

  /// 等待已排队的落盘写入真正落到文件（退出前、导出与测试断言时用）。
  ///
  /// flush 本身也排进 `_pendingWrite` 这条串行链：`IOSink.flush()` **不可并发**
  /// 调用，重叠时会抛 `StateError: StreamSink is bound to a stream`（告警/错误的
  /// 「立即落盘」与定时 flush 很容易撞上）。
  Future<void> flush() async {
    final writer = _file;
    final step = _pendingWrite
        .then((_) => writer?.flush())
        .catchError((Object _) {});
    _pendingWrite = step;
    await step;
    // 本步执行期间若又有新条目排队，保持脏标记让下一轮继续刷。
    if (identical(step, _pendingWrite)) _dirty = false;
  }

  /// 定时把缓冲刷到磁盘。
  ///
  /// 前台硬崩溃（native crash / OOM / SIGKILL）拿不到生命周期回调，只靠退后台
  /// flush 会丢掉整段会话日志；定时窗口即最大丢失窗口。
  void _startFlushTimer(Duration interval) {
    _stopFlushTimer();
    _flushTimer = Timer.periodic(interval, (_) {
      if (_dirty) unawaited(flush());
    });
  }

  void _stopFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  // ── 导出与分享 ─────────────────────────────────────────────────────────

  /// 导出为纯文本（可用作剪贴板/分享正文）。覆盖上次会话回读 + 本次会话。
  String exportText({int? maxLines}) =>
      formatLogLines(entries, maxLines: maxLines);

  @visibleForTesting
  Future<void> resetForTest() async {
    uninstall();
    // 先让落盘队列跑完再 close：close 与在途 flush 并发同样会抛 StreamSink 错误。
    await _pendingWrite.catchError((Object _) {});
    await _file?.close();
    _file = null;
    _pendingWrite = Future<void>.value();
    _dirty = false;
    _history.clear();
    _entries.clear();
    revision.value++;
    _capacity = defaultCapacity;
    _minLevel = LogLevel.debug;
  }
}

/// 追加式日志文件写入 + 大小轮换。
///
/// 单文件超过 [maxBytes] 时把 `app.log` 改名为 `app.log.1`（保留 [maxBackups]
/// 份备份），再新建一个空文件继续写。只追加，不覆盖旧内容。
class FileLogWriter {
  FileLogWriter(this.dir, {this.maxBytes = 1 << 20, this.maxBackups = 1});

  final Directory dir;
  final int maxBytes;
  final int maxBackups;

  File? _current;
  IOSink? _sink;
  int _size = 0;

  String get currentPath => _current?.path ?? '';

  Future<void> open() async {
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final file = File('${dir.path}/${AppLog.logFileName}');
    _current = file;
    if (file.existsSync()) _size = file.lengthSync();
    _sink = file.openWrite(mode: FileMode.append);
  }

  Future<void> append(String line) async {
    if (_sink == null) return;
    final bytes = line.length + 1;
    if (_size + bytes > maxBytes) {
      await rotate();
    }
    // rotate() 会替换 sink，必须重新取；用进入时捕获的旧 sink 会写到已关闭的流。
    final sink = _sink;
    if (sink == null) return;
    sink.write(line);
    sink.write('\n');
    _size += bytes;
  }

  /// 把缓冲真正写到磁盘（IOSink 会缓冲，不 flush 时文件里可能还没有内容）。
  Future<void> flush() => _sink?.flush() ?? Future<void>.value();

  Future<void> rotate() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    final files = <File>[
      File('${dir.path}/${AppLog.logFileName}'),
      for (var i = 1; i <= maxBackups; i++)
        File('${dir.path}/${AppLog.logFileName}.$i'),
    ];
    // 最旧备份先删。
    final oldest = files[files.length - 1];
    if (oldest.existsSync()) oldest.deleteSync();
    // 备份依次后移。
    for (var i = maxBackups; i >= 1; i--) {
      final from = File(
        '${dir.path}/${AppLog.logFileName}${i == 1 ? '' : '.$i'}',
      );
      final to = File('${dir.path}/${AppLog.logFileName}.$i');
      if (from.existsSync()) from.renameSync(to.path);
    }
    _size = 0;
    final fresh = File('${dir.path}/${AppLog.logFileName}');
    _current = fresh;
    _sink = fresh.openWrite(mode: FileMode.write);
  }

  Future<void> close() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }
}

/// Rust 核心日志（`core_log` 落盘副本）的读取入口。
///
/// Rust 侧只把日志写进 `runtime_dir/rust.log` —— Android 应用读不到自己的 logcat，
/// 这是真机上唯一的观测面。读取实现由宿主注入（`main()` 接
/// `BackendService.rustLogFile`），日志页的「Rust」视图据此展示；未注入时视为
/// 不可用，页面给空态而不是报错。
class RustLogSource {
  const RustLogSource._();

  /// 返回文件全文；文件不存在返回 null。
  static Future<String?> Function()? reader;

  static Future<String?> read() async {
    final read = reader;
    if (read == null) return null;
    try {
      return await read();
    } catch (_) {
      return null;
    }
  }
}

/// 把日志条目渲染成可复制/分享的纯文本。
///
/// `maxLines` 只保留最后若干条并标注省略数；日志页对「应用」与「Rust」两个来源
/// 共用这一个渲染器，避免两处各写一遍截断规则。
String formatLogLines(List<LogEntry> entries, {int? maxLines}) {
  final lines = entries.map((e) => e.format()).toList();
  if (maxLines != null && lines.length > maxLines) {
    final kept = lines.sublist(lines.length - maxLines);
    return '... 省略 ${lines.length - maxLines} 条 ...\n${kept.join('\n')}';
  }
  return lines.join('\n');
}