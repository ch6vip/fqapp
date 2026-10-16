import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/log_viewer_page.dart';
import 'package:fqapp/pages/service_detail_page.dart';

void main() {
  testWidgets('健康检查通过时显示运行中与服务地址', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ServiceDetailPage(healthCheck: () async => true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本地后端'), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('服务地址'), findsOneWidget);
    expect(find.textContaining('127.0.0.1:28080'), findsOneWidget);
    expect(find.text('日志'), findsOneWidget);
  });

  testWidgets('健康检查失败时显示已停止', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ServiceDetailPage(healthCheck: () async => false),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已停止'), findsOneWidget);
  });

  testWidgets('点刷新会重新执行健康检查', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ServiceDetailPage(
          healthCheck: () async {
            calls++;
            return calls > 1;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已停止'), findsOneWidget);

    await tester.tap(find.byTooltip('重新检查'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('运行中'), findsOneWidget);
  });

  testWidgets('点日志进入日志页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ServiceDetailPage(healthCheck: () async => true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('日志'));
    await tester.pumpAndSettle();
    expect(find.byType(LogViewerPage), findsOneWidget);
  });
}
