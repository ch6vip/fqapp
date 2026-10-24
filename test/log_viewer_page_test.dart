import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/api_service_page.dart';
import 'package:fqapp/pages/log_viewer_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/app_log.dart';
import 'package:fqapp/services/book_txt_export.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/logs/log_entry_card.dart';

/// 日志页定向回归：筛选、导出范围、历史跟随和窄屏布局。
///
/// 注意：组件测试里**不能**调 `AppLog.install()`——它会重绑 `debugPrint`，
/// 触发 flutter_test 的 `debugAssertAllFoundationVarsUnset` 不变量断言。
/// 记录日志本身不需要 install（默认级别就是 debug）。
void main() {
  setUp(() => AppLog.instance.resetForTest());
  tearDown(() => AppLog.instance.resetForTest());

  testWidgets('渲染日志条目并按级别筛选', (tester) async {
    AppLog.i('boot', '服务已启动');
    AppLog.w('api', '接口超时');
    AppLog.e('zone', '未捕获异常');

    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.pump();

    // 日志行是 RichText，需要 findRichText 才能命中。
    expect(find.textContaining('服务已启动', findRichText: true), findsOneWidget);
    expect(find.textContaining('接口超时', findRichText: true), findsOneWidget);
    expect(find.textContaining('未捕获异常', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('筛选日志'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '错误'));
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();

    expect(find.textContaining('未捕获异常', findRichText: true), findsOneWidget);
    expect(find.textContaining('服务已启动', findRichText: true), findsNothing);
    expect(find.textContaining('接口超时', findRichText: true), findsNothing);
  });

  testWidgets('无日志时给出空态文案', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.pump();
    expect(find.text('暂无日志'), findsOneWidget);
  });

  testWidgets('清空按钮经确认后清空内存日志', (tester) async {
    AppLog.i('boot', '待清空');

    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.pump();

    await tester.tap(find.byTooltip('日志操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空当前视图'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();

    expect(AppLog.instance.entries, isEmpty);
    expect(find.text('暂无日志'), findsOneWidget);
  });

  testWidgets('设置页「服务」分类下有日志入口，点击进入日志页', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('服务'));
    await tester.pumpAndSettle();

    // The service category opens the local API console; the log entry lives at
    // the bottom of that page, so it has to be scrolled into view first.
    expect(find.byType(ApiServicePage), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('运行日志'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('运行日志'), findsOneWidget);

    await tester.tap(find.text('运行日志'));
    await tester.pumpAndSettle();
    expect(find.byType(LogViewerPage), findsOneWidget);
  });

  testWidgets('切到 Rust 来源时读取核心落盘副本，且清空被禁用', (tester) async {
    RustLogSource.reader = () async =>
        '[I] 2026-10-02T10:00:00 core: fqapi_core::api: 核心已启动\n'
        '[W] 2026-10-02T10:00:01 core: fqapi_core::upstream: 上游超时\n';
    addTearDown(() => RustLogSource.reader = null);

    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.pump();
    // 应用来源为空时先给应用日志的空态。
    expect(find.text('暂无日志'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '核心'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('核心已启动', findRichText: true), findsOneWidget);
    expect(find.textContaining('上游超时', findRichText: true), findsOneWidget);

    // Rust 日志由核心追加写入，应用内不提供清空。
    await tester.tap(find.byTooltip('日志操作'));
    await tester.pumpAndSettle();
    final clearTile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '清空当前视图'),
    );
    expect(clearTile.enabled, isFalse);

    // 卸载页面以取消轮询定时器（否则测试结束会报 pending timer）。
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Rust 文件不存在时给 Rust 空态而不是报错', (tester) async {
    RustLogSource.reader = () async => null;
    addTearDown(() => RustLogSource.reader = null);

    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, '核心'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('暂无核心日志'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('搜索按标签或内容过滤，清除后恢复', (tester) async {
    AppLog.i('boot', '服务已启动');
    AppLog.w('api', '接口超时');

    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '超时');
    await tester.pump();

    expect(find.textContaining('接口超时', findRichText: true), findsOneWidget);
    expect(find.textContaining('服务已启动', findRichText: true), findsNothing);

    // 无匹配时给出带关键词的空态，而不是假装列表为空。
    await tester.enterText(find.byType(TextField), '不存在的关键词');
    await tester.pump();
    expect(find.textContaining('没有匹配', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump();
    expect(find.textContaining('服务已启动', findRichText: true), findsOneWidget);
  });

  testWidgets('时间范围过滤掉过旧的 Rust 日志', (tester) async {
    // 应用日志的时间恒为「现在」，所以时间过滤只能用 Rust 来源注入旧时间戳。
    RustLogSource.reader = () async =>
        '[I] 2020-01-01T00:00:00 core: fqapi_core::api: 很久以前\n'
        '[I] ${DateTime.now().toIso8601String()} core: fqapi_core::api: 刚刚\n';
    addTearDown(() => RustLogSource.reader = null);

    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, '核心'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('很久以前', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('筛选日志'));
    await tester.pump();
    // 用显式时长推进弹层动画：Rust 来源开着 2s 轮询，pumpAndSettle 会一直不收敛。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('最近 5 分钟'));
    await tester.tap(find.text('应用筛选'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('很久以前', findRichText: true), findsNothing);
    expect(find.textContaining('刚刚', findRichText: true), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('复制只包含当前筛选结果，TXT 全部导出不截断为 500 条', (tester) async {
    final sink = _RecordingSink();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    for (var i = 0; i < 600; i++) {
      AppLog.i('network', 'request-$i');
    }
    AppLog.w('player-load', '播放超时');
    await tester.pumpWidget(MaterialApp(home: LogViewerPage(exportSink: sink)));
    await tester.enterText(find.byType(TextField), '播放超时');
    await tester.pump();
    await tester.tap(find.byTooltip('日志操作'));
    await tester.pumpAndSettle();
    expect(find.text('1 条 · 当前查看的结果'), findsOneWidget);
    await tester.tap(find.text('复制筛选结果'));
    await tester.pumpAndSettle();
    expect(copied, contains('播放超时'));
    expect(copied, isNot(contains('request-')));

    await tester.tap(find.byTooltip('日志操作'));
    await tester.pumpAndSettle();
    expect(find.text('601 条 · 当前来源，不受筛选影响'), findsOneWidget);
    await tester.tap(find.text('导出全部'));
    await tester.pumpAndSettle();
    expect(sink.text, contains('共 601 条'));
    expect(sink.text, contains('request-0\n'));
    expect(sink.text, contains('request-599\n'));
    expect(sink.text, contains('播放超时'));
    expect(sink.text, isNot(contains('省略')));
    expect(sink.fileName, endsWith('.txt'));
  });

  testWidgets('日志详情可展开并复制完整堆栈', (tester) async {
    const message = '读取失败\n#0 firstFrame\n#1 secondFrame\n#2 lastFrame';
    AppLog.e('player-load', message);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.byType(LogEntryCard));
    await tester.pump();
    expect(find.widgetWithText(SelectableText, message), findsOneWidget);
    await tester.tap(find.text('复制单条'));
    await tester.pump();
    expect(copied, AppLog.instance.entries.single.format());
  });

  testWidgets('导出应用与核心日志时分别分区并读取最新核心内容', (tester) async {
    final sink = _RecordingSink();
    AppLog.i('app', '应用启动');
    RustLogSource.reader = () async =>
        '[W] 2026-10-12T10:00:00Z core: 核心刚刚写入\n';
    addTearDown(() => RustLogSource.reader = null);
    await tester.pumpWidget(MaterialApp(home: LogViewerPage(exportSink: sink)));

    await tester.enterText(find.byType(TextField), 'no-match');
    await tester.pump();
    await tester.tap(find.byTooltip('日志操作'));
    await tester.pumpAndSettle();
    expect(find.text('导出应用 + 核心'), findsOneWidget);
    expect(find.text('应用 1 条 + 核心日志 · 导出前读取最新内容'), findsOneWidget);
    await tester.tap(find.text('导出应用 + 核心'));
    await tester.pumpAndSettle();

    expect(sink.fileName, startsWith('fqapp-all-logs-'));
    expect(sink.text, contains('应用日志：1 条'));
    expect(sink.text, contains('核心日志：1 条'));
    expect(sink.text, contains('===== 应用日志 ====='));
    expect(sink.text, contains('应用启动'));
    expect(sink.text, contains('===== 核心日志 ====='));
    expect(sink.text, contains('核心刚刚写入'));
  });

  testWidgets('应用为空且未打开核心页时仍可合并导出核心日志', (tester) async {
    final sink = _RecordingSink();
    RustLogSource.reader = () async =>
        '[I] 2026-10-12T10:00:00Z core: core-only\n';
    addTearDown(() => RustLogSource.reader = null);
    await tester.pumpWidget(MaterialApp(home: LogViewerPage(exportSink: sink)));
    await tester.tap(find.byTooltip('日志操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出应用 + 核心'));
    await tester.pumpAndSettle();
    expect(sink.text, contains('应用日志：0 条'));
    expect(sink.text, contains('核心日志：1 条'));
    expect(sink.text, contains('core-only'));
  });

  testWidgets('合并导出无法读取核心时保留应用日志并明确说明缺失', (tester) async {
    final sink = _RecordingSink();
    AppLog.e('app', 'application-error');
    RustLogSource.reader = () async => throw StateError('read failed');
    addTearDown(() => RustLogSource.reader = null);
    await tester.pumpWidget(MaterialApp(home: LogViewerPage(exportSink: sink)));
    await tester.tap(find.byTooltip('日志操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出应用 + 核心'));
    await tester.pumpAndSettle();
    expect(sink.text, contains('application-error'));
    expect(sink.text, contains('核心日志：未获取（文件不存在或读取失败）'));
    expect(sink.text, isNot(contains('核心日志：0 条')));
  });

  testWidgets('上翻冻结阅读位置，满缓冲新增日志仍计数，点击恢复最新', (tester) async {
    for (var i = 0; i < AppLog.defaultCapacity; i++) {
      AppLog.i('network', 'entry-$i');
    }
    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.pump();
    final list = find.byKey(const ValueKey('log-list'));
    await tester.drag(list, const Offset(0, 320));
    await tester.pumpAndSettle();
    final controller = tester.widget<ListView>(list).controller!;
    final oldOffset = controller.offset;
    expect(oldOffset, greaterThan(24));
    expect(find.text('回到最新'), findsOneWidget);
    AppLog.w('network', 'new-while-paused');
    await tester.pump();
    expect(AppLog.instance.entries.length, AppLog.defaultCapacity);
    expect(find.text('新增 1 条'), findsOneWidget);
    expect(controller.offset, oldOffset);
    expect(find.text('new-while-paused'), findsNothing);
    await tester.tap(find.text('新增 1 条'));
    await tester.pumpAndSettle();
    expect(find.text('new-while-paused'), findsOneWidget);
    expect(find.text('实时跟随'), findsOneWidget);
    expect(controller.offset, 0);
  });

  testWidgets('播放诊断切回应用来源且按标签精确匹配', (tester) async {
    AppLog.d('player-load', '播放阶段耗时');
    AppLog.i('network', 'body mentions player-load');
    RustLogSource.reader = () async => null;
    addTearDown(() => RustLogSource.reader = null);
    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.tap(find.widgetWithText(ChoiceChip, '核心'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '播放诊断'));
    await tester.pumpAndSettle();
    expect(find.text('播放阶段耗时'), findsOneWidget);
    expect(find.text('body mentions player-load'), findsNothing);
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '应用')).selected,
      isTrue,
    );
  });

  testWidgets('核心轮询保留展开状态，只计新增日志', (tester) async {
    var text = '[I] 2026-10-12T10:00:00Z core: first\n';
    RustLogSource.reader = () async => text;
    addTearDown(() => RustLogSource.reader = null);
    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.tap(find.widgetWithText(ChoiceChip, '核心'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(LogEntryCard));
    await tester.pump();
    expect(find.widgetWithText(SelectableText, 'first'), findsOneWidget);
    await tester.pump(LogViewerPage.rustRefresh);
    expect(find.widgetWithText(SelectableText, 'first'), findsOneWidget);
    await tester.tap(find.text('实时跟随'));
    await tester.pump();
    text += '[W] 2026-10-12T10:00:01Z core: second\n';
    await tester.pump(LogViewerPage.rustRefresh);
    await tester.pump();
    expect(find.text('新增 1 条'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, 'first'), findsOneWidget);
    await tester.tap(find.text('新增 1 条'));
    await tester.pump();
    expect(find.text('second'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, 'first'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('导出失败给出真实结果，并允许重试', (tester) async {
    final sink = _RecordingSink()..fail = true;
    AppLog.e('api', 'timeout');
    await tester.pumpWidget(MaterialApp(home: LogViewerPage(exportSink: sink)));
    await tester.tap(find.byTooltip('日志操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出筛选结果'));
    await tester.pumpAndSettle();
    expect(find.text('导出失败：磁盘空间不足'), findsOneWidget);
    sink.fail = false;
    await tester.tap(find.byTooltip('日志操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出筛选结果'));
    await tester.pumpAndSettle();
    expect(sink.text, contains('范围：当前筛选结果'));
    expect(find.text('已导出 1 条：Download/test.txt'), findsOneWidget);
  });

  testWidgets('窄屏和大字体下明暗主题的工具栏、详情与筛选无溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AppLog.w('a-very-long-diagnostic-tag', '长日志\n第一行\n第二行');
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.createTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: const LogViewerPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(LogEntryCard));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('筛选日志'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}

class _RecordingSink implements TxtSink {
  String? text;
  String? fileName;
  bool fail = false;

  @override
  Future<ExportTarget> saveText({
    required String fileName,
    required String text,
  }) async {
    if (fail) throw const ExportWriteException('磁盘空间不足');
    this.fileName = fileName;
    this.text = text;
    return const ExportTarget(path: 'Download/test.txt', isPublic: true);
  }
}
