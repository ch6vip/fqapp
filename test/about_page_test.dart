import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/about_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';

/// 关于页改版后的结构与交互：全部信息行齐备、版本行点按复制、开源许可
/// 打开框架许可页、微信赞赏打开赞赏码弹窗。
void main() {
  Future<void> pumpAbout(WidgetTester tester) async {
    // 页面内容高于默认 800x600 视口，ListView 外的行不会被构建；
    // 拉高测试视口让整页一次排完，断言才能覆盖每一行。
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 1800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const AboutPage(),
      ),
    );
    await tester.pump();
  }

  testWidgets('关于页渲染出介绍与全部信息行', (tester) async {
    await pumpAbout(tester);

    expect(find.text('什锦铺'), findsOneWidget);
    expect(find.text('小说 / 短剧 / 漫剧 / 漫画 / 听书聚合客户端'), findsOneWidget);
    // 介绍是一段正文，不再是「项目介绍」标题行。
    expect(find.textContaining('所有签名与解密都在你的手机本地完成'), findsOneWidget);
    expect(find.text('项目介绍'), findsNothing);

    expect(find.text('当前版本'), findsOneWidget);
    expect(find.text(AboutPage.versionText), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('前往 GitHub 发布页查看新版本'), findsOneWidget);
    expect(find.text('开源许可'), findsOneWidget);
    expect(find.text('GPL-3.0 与第三方组件许可'), findsOneWidget);
    expect(find.text('Source Code'), findsNothing);
    expect(find.text('源代码'), findsOneWidget);
    expect(find.text('问题反馈'), findsOneWidget);
    // 信息行统一走设置组件，不再使用 Material ListTile。
    expect(find.byType(SettingsRow), findsNWidgets(5));
    expect(find.byType(ListTile), findsNothing);

    expect(find.text('支持作者'), findsOneWidget);
    expect(find.text('前往爱发电'), findsOneWidget);
    expect(find.text('微信赞赏'), findsOneWidget);
    expect(find.textContaining('仅限个人学习研究使用'), findsOneWidget);
  });

  testWidgets('点当前版本行复制版本号并提示', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
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

    await pumpAbout(tester);
    await tester.tap(find.text('当前版本'));
    await tester.pump();

    expect(copied, AboutPage.versionText);
    expect(find.text('已复制版本号'), findsOneWidget);
  });

  testWidgets('点开源许可打开许可页', (tester) async {
    await pumpAbout(tester);
    await tester.tap(find.text('开源许可'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(LicensePage), findsOneWidget);
    // 许可页要等 LicenseRegistry 的真实异步结果，FakeAsync 推不动，
    // 用 runAsync 给它真实时间，页眉的应用名随后出现。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    await tester.pump();
    expect(find.text('什锦铺'), findsWidgets);
  });

  testWidgets('点微信赞赏打开赞赏码弹窗', (tester) async {
    await pumpAbout(tester);
    await tester.tap(find.text('微信赞赏'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('微信扫一扫，赞赏作者'), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image).last);
    expect(
      (image.image as AssetImage).assetName,
      'assets/images/wechat_reward.png',
    );
  });

  testWidgets('墨水屏下 logo 不投彩色阴影，浅色仍保留', (tester) async {
    final original = einkModeNotifier.value;
    addTearDown(() => einkModeNotifier.value = original);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 1800);
    addTearDown(tester.view.reset);

    Future<BoxDecoration> logoDecoration() async {
      final eink = einkModeNotifier.value;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.createTheme(Brightness.light, einkMode: eink),
          // 用 key 强制换一棵新树：同一页面在两种主题间切换时，const 子树
          // 可能复用旧 element，测不到重建后的配色。
          home: AboutPage(key: ValueKey('about-$eink')),
        ),
      );
      await tester.pump();
      final plate = tester.widget<Container>(
        find.byKey(const ValueKey('about-logo-plate')),
      );
      return plate.decoration! as BoxDecoration;
    }

    einkModeNotifier.value = true;
    expect((await logoDecoration()).boxShadow, isNull);

    einkModeNotifier.value = false;
    expect((await logoDecoration()).boxShadow, isNotEmpty);
  });
}
