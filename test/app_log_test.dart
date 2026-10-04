import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/app_log.dart';

/// 应用内日志核心的服务用例：环形缓冲、级别过滤、三路捕获、落盘轮换与
/// 导出，以及 API 插桩的隐私纪律（只记路由模板，不记 query/参数/主机）。
void main() {
  setUp(() => AppLog.instance.resetForTest());
  tearDown(() => AppLog.instance.resetForTest());

  /// 关掉落盘句柄后再删临时目录，否则 Windows 上文件仍被占用。
  void cleanupDir(Directory dir) {
    addTearDown(() async {
      await AppLog.instance.resetForTest();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
  }

  test('环形缓冲按容量淘汰最旧条目', () {
    AppLog.instance.install(capacity: 3);
    for (var i = 1; i <= 5; i++) {
      AppLog.i('t', 'msg$i');
    }
    expect(AppLog.instance.entries.map((e) => e.message), [
      'msg3',
      'msg4',
      'msg5',
    ]);
  });

  test('minLevel 过滤：低于阈值的级别不入缓冲', () {
    AppLog.instance.install(minLevel: LogLevel.warn);
    AppLog.d('t', 'd');
    AppLog.i('t', 'i');
    AppLog.w('t', 'w');
    AppLog.e('t', 'e');
    expect(AppLog.instance.entries.map((e) => e.level), [
      LogLevel.warn,
      LogLevel.error,
    ]);
  });

  test('revision 在记录与清空时递增，供日志页刷新', () {
    AppLog.instance.install();
    final before = AppLog.instance.revision.value;
    AppLog.i('t', 'x');
    expect(AppLog.instance.revision.value, before + 1);
    AppLog.instance.clear();
    expect(AppLog.instance.revision.value, before + 2);
    expect(AppLog.instance.entries, isEmpty);
  });

  test('debugPrint 被接管，且仍链到旧实现（控制台输出不丢）', () {
    final seen = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => seen.add(message ?? '');
    addTearDown(() => debugPrint = original);

    AppLog.instance.install();
    debugPrint('hello-debug');

    expect(seen, ['hello-debug']);
    expect(AppLog.instance.entries.single.tag, 'flutter');
    expect(AppLog.instance.entries.single.message, 'hello-debug');

    // 卸下后不再进缓冲，但仍走原来的控制台实现。
    AppLog.instance.uninstall();
    final before = AppLog.instance.entries.length;
    debugPrint('after-uninstall');
    expect(seen, ['hello-debug', 'after-uninstall']);
    expect(AppLog.instance.entries, hasLength(before));
  });

  test('FlutterError.onError 被接管，且仍链到旧实现', () {
    final seen = <FlutterErrorDetails>[];
    final original = FlutterError.onError;
    FlutterError.onError = seen.add;
    addTearDown(() => FlutterError.onError = original);

    AppLog.instance.install();
    FlutterError.onError!(FlutterErrorDetails(exception: StateError('boom')));

    expect(seen, hasLength(1));
    final entry = AppLog.instance.entries.single;
    expect(entry.level, LogLevel.error);
    expect(entry.tag, 'framework');
    expect(entry.message, contains('boom'));
  });

  test('exportText 默认导出全部，maxLines 时保留最后若干条并标注省略数', () {
    AppLog.instance.install();
    for (var i = 1; i <= 5; i++) {
      AppLog.i('t', 'm$i');
    }
    expect(AppLog.instance.exportText().split('\n'), hasLength(5));

    final text = AppLog.instance.exportText(maxLines: 2);
    expect(text, contains('省略 3 条'));
    expect(text.split('\n').last, contains('m5'));
  });

  test('startPersistence 落盘：开启前后的条目都能读到', () async {
    final dir = await Directory.systemTemp.createTemp('fqapp-log-');
    cleanupDir(dir);

    AppLog.instance.install();
    AppLog.i('boot', 'before-persistence');
    await AppLog.instance.startPersistence(directory: dir);
    AppLog.i('boot', 'after-persistence');
    await AppLog.instance.flush();

    final content = await File('${dir.path}/app.log').readAsString();
    expect(content, contains('before-persistence'));
    expect(content, contains('after-persistence'));
  });

  test('拿不到私有目录时退化为纯内存模式，不抛异常', () async {
    AppLog.instance.install();
    // 用一个不可创建的子路径模拟失败（该路径已存在一个同名文件）。
    final parent = await Directory.systemTemp.createTemp('fqapp-log-bad-');
    final file = File('${parent.path}/notadir');
    await file.writeAsString('x');
    cleanupDir(parent);

    await AppLog.instance.startPersistence(directory: Directory(file.path));
    AppLog.i('t', 'still-in-memory');
    expect(AppLog.instance.filePath, isNull);
    expect(AppLog.instance.entries, hasLength(1));
  });

  test('FileLogWriter 超过上限时轮换并保留备份', () async {
    final dir = await Directory.systemTemp.createTemp('fqapp-log-rot-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final writer = FileLogWriter(dir, maxBytes: 60, maxBackups: 1);
    await writer.open();
    for (var i = 0; i < 12; i++) {
      await writer.append('line-$i-xxxxxxxxxxxxxxxx');
    }
    await writer.close();

    final current = File('${dir.path}/app.log');
    expect(current.existsSync(), isTrue);
    expect(File('${dir.path}/app.log.1').existsSync(), isTrue);
    expect(await current.readAsString(), isNotEmpty);
    // 轮换后当前文件始终回到上限以内。
    expect(await current.length(), lessThan(60));
  });

  test('api 日志只含路由模板：不含主机、query 与数值 id', () async {
    AppLog.instance.install();
    final client = ApiClient(
      baseUrl: 'http://backend.invalid',
      client: MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(jsonEncode({'code': 0, 'data': <String, Object>{}})),
          200,
        ),
      ),
    );

    await client.homepagePage(tabType: 8, offset: 0);
    // 成功回调挂在 future.then 上，让微任务先跑完再断言。
    await Future<void>.delayed(Duration.zero);

    final lines = AppLog.instance.entries
        .where((e) => e.tag == 'api')
        .map((e) => e.message)
        .toList();
    expect(lines, isNotEmpty);
    final joined = lines.join('\n');
    expect(joined, contains('/api/v1/recommend/homepage'));
    expect(joined, isNot(contains('backend.invalid')));
    expect(joined, isNot(contains('?')));
    expect(joined, isNot(contains('tab_type')));
    expect(joined, isNot(contains('session_id')));
  });

  test('开启落盘后由定时器 flush：不显式调用也能读到', () async {
    final dir = await Directory.systemTemp.createTemp('fqapp-log-timer-');
    cleanupDir(dir);

    AppLog.instance.install();
    await AppLog.instance.startPersistence(
      directory: dir,
      flushInterval: const Duration(milliseconds: 40),
    );
    AppLog.i('timer', 'auto-flushed');

    // 故意不调用 flush()：等定时窗口自行落盘（前台硬崩溃时的保命路径）。
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final content = await File('${dir.path}/app.log').readAsString();
    expect(content, contains('auto-flushed'));
  });

  test('警告/错误立即落盘，不等定时窗口', () async {
    final dir = await Directory.systemTemp.createTemp('fqapp-log-urgent-');
    cleanupDir(dir);

    AppLog.instance.install();
    await AppLog.instance.startPersistence(
      directory: dir,
      // 定时窗口故意拉长：若还靠定时器，本条断言必红。
      flushInterval: const Duration(seconds: 30),
    );
    AppLog.e('boom', 'urgent-error');

    await Future<void>.delayed(const Duration(milliseconds: 50));

    final content = await File('${dir.path}/app.log').readAsString();
    expect(content, contains('urgent-error'));
  });

  test('重启后回读上次会话，且历史不重复落盘', () async {
    final dir = await Directory.systemTemp.createTemp('fqapp-log-history-');
    cleanupDir(dir);
    const window = Duration(seconds: 30); // 不靠定时器，手动 flush

    // 第一次运行：写两条后结束（模拟进程退出/被杀）。
    AppLog.instance.install();
    await AppLog.instance.startPersistence(
      directory: dir,
      flushInterval: window,
    );
    AppLog.i('boot', 'session-one-a');
    AppLog.e('boom', 'session-one-b');
    await AppLog.instance.flush();
    await AppLog.instance.resetForTest();

    // 第二次运行：同一目录，应当回读到上一次会话。
    AppLog.instance.install();
    await AppLog.instance.startPersistence(
      directory: dir,
      flushInterval: window,
    );
    AppLog.i('boot', 'session-two');
    await AppLog.instance.flush();

    final messages = AppLog.instance.entries.map((e) => e.message).toList();
    expect(messages, contains('session-one-a'));
    expect(messages, contains('session-one-b'));
    expect(messages, contains('session-two'));

    // 回读的历史不得再写一遍（否则每次重启文件都会翻倍）。
    final content = await File('${dir.path}/app.log').readAsString();
    expect('session-one-a'.allMatches(content).length, 1);
    expect('session-two'.allMatches(content).length, 1);
  });

  test('多行消息回读后仍是同一条，级别与标签保真', () async {
    final dir = await Directory.systemTemp.createTemp('fqapp-log-multiline-');
    cleanupDir(dir);
    await File('${dir.path}/app.log').writeAsString(
      '[E] 2026-10-02T10:00:00.000 e2e: 第一行\n'
      '  第二行（栈）\n'
      '  第三行\n'
      '[I] 2026-10-02T10:00:01.000 boot: 第二条\n',
    );

    AppLog.instance.install();
    await AppLog.instance.startPersistence(
      directory: dir,
      flushInterval: const Duration(seconds: 30),
    );

    final entries = AppLog.instance.entries;
    expect(entries, hasLength(2));
    expect(entries.first.level, LogLevel.error);
    expect(entries.first.tag, 'e2e');
    expect(entries.first.message, contains('第一行'));
    expect(entries.first.message, contains('第二行（栈）'));
    expect(entries.last.level, LogLevel.info);
    expect(entries.last.message, '第二条');
  });

  test('clear 同时清掉回读历史与本次会话缓冲', () async {
    final dir = await Directory.systemTemp.createTemp('fqapp-log-clear-');
    cleanupDir(dir);
    await File(
      '${dir.path}/app.log',
    ).writeAsString('[I] 2026-10-02T10:00:00.000 boot: 上次会话\n');

    AppLog.instance.install();
    await AppLog.instance.startPersistence(
      directory: dir,
      flushInterval: const Duration(seconds: 30),
    );
    AppLog.i('boot', '本次会话');
    expect(AppLog.instance.entries, hasLength(2));

    AppLog.instance.clear();
    expect(AppLog.instance.entries, isEmpty);
  });
}