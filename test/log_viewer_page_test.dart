import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/log_viewer_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/app_log.dart';

/// 日志页用例：条目渲染、级别筛选、清空确认，以及设置页入口可达。
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

    await tester.tap(find.widgetWithText(FilterChip, '错误'));
    await tester.pump();

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

    await tester.tap(find.byTooltip('清空'));
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

    expect(find.text('日志'), findsOneWidget);

    await tester.tap(find.text('日志'));
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

    await tester.tap(find.text('Rust'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('核心已启动', findRichText: true), findsOneWidget);
    expect(find.textContaining('上游超时', findRichText: true), findsOneWidget);

    // Rust 日志由核心追加写入，应用内不提供清空。
    final clearButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.delete_outline),
    );
    expect(clearButton.onPressed, isNull);

    // 卸载页面以取消轮询定时器（否则测试结束会报 pending timer）。
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Rust 文件不存在时给 Rust 空态而不是报错', (tester) async {
    RustLogSource.reader = () async => null;
    addTearDown(() => RustLogSource.reader = null);

    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.pump();
    await tester.tap(find.text('Rust'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('暂无 Rust 日志'), findsOneWidget);
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
    await tester.tap(find.text('Rust'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('很久以前', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('时间范围：不限'));
    await tester.pump();
    // 用显式时长推进弹层动画：Rust 来源开着 2s 轮询，pumpAndSettle 会一直不收敛。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('最近 5 分钟'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('很久以前', findRichText: true), findsNothing);
    expect(find.textContaining('刚刚', findRichText: true), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}