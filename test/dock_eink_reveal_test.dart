// RootShell 集成守卫：_onEinkModeChanged 必须同时做 reveal 和 setState。
// 少了 setState，RootShell 不会重建 DockAutoHideSlide，reduceMotion 沿用旧
// widget 的 false；reveal 过渡会跑 500ms 平移而非零帧落位，墨水屏下能看到
// 残影。这条契约靠 widget 层的 'e-ink reveal transition uses zero duration'
// 钉不住（那里 reduceMotion 从挂载起就为 true），必须在壳层里真的翻动
// einkModeNotifier 才能覆盖到。单独放一个文件避免与 drama_page_test 的
// 生命周期状态互相污染。
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/drama_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/dock_auto_hide.dart';
import 'package:fqapp/widgets/shell_dock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MediaItem book(String id) => MediaItem(
    id: id,
    title: '$id 作品',
    cover: '',
    author: '作者',
    badge: '',
    ep: '',
    kind: 'book',
  );

  // 空 items 会让首页停在加载态（无限动画），pumpAndSettle 永远等不到静帧；
  // 每条 feed 给几张卡片，既让壳层进入稳态也保证首页可滚动。
  HomeNotifier notifier({int initialTabIndex = 0}) => HomeNotifier(
    initialTabIndex: initialTabIndex,
    homepageLoader:
        ({int tabType = 2, int offset = 0, String? sessionId}) async {
          return HomepagePage(
            items: [for (var i = 0; i < 6; i++) book('$tabType-$i')],
            nextOffset: null,
            sessionId: null,
          );
        },
    searchLoader: (query, {int page = 1}) async => const [],
  );

  testWidgets(
    'entering eink while dock hidden reveals without slide animation',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => einkModeNotifier.value = false);
      addTearDown(() => dramaLightPageNotifier.value = false);
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            homeProvider.overrideWith(() => notifier()),
            dramaProvider.overrideWith(
              () => notifier(initialTabIndex: dramaTabIndex),
            ),
          ],
          child: MaterialApp(home: RootShell(backendStarter: () async {})),
        ),
      );
      await tester.pumpAndSettle();

      final shellSlide = find.ancestor(
        of: find.byType(ShellDock),
        matching: find.byType(DockAutoHideSlide),
      );
      AnimatedSlide slideWidget() => tester.widget<AnimatedSlide>(
        find.descendant(of: shellSlide, matching: find.byType(AnimatedSlide)),
      );

      // 默认路径：dock 会随拖动滑出，动画 500ms。
      expect(slideWidget().duration, const Duration(milliseconds: 500));
      await tester.dragFrom(const Offset(200, 300), const Offset(0, -200));
      await tester.pump();
      expect(slideWidget().offset, const Offset(0, 1));

      // 打开墨水屏：_onEinkModeChanged 应 reveal + setState。
      einkModeNotifier.value = true;
      // 只推进一帧：setState 到位时 reduceMotion=true → Duration.zero，
      // offset 立刻从 (0,1) 回到 (0,0)；setState 缺失时仍在 500ms 平移途中。
      await tester.pump();
      expect(
        slideWidget().duration,
        Duration.zero,
        reason: 'RootShell 需 setState 将新 reduceMotion 刷到 DockAutoHideSlide',
      );
      expect(
        slideWidget().offset,
        Offset.zero,
        reason: 'eink 下 reveal 必须零帧落位，不能跑 500ms 平移',
      );

      // 对称契约：setState 必须无条件执行。若被收进 `if (eink)` 分支，
      // 退出墨水屏后 reduceMotion 永远停在 true，dock 动画就永久失效了。
      einkModeNotifier.value = false;
      await tester.pump();
      expect(
        slideWidget().duration,
        const Duration(milliseconds: 500),
        reason: '退出 eink 后动画时长必须恢复',
      );

      // 壳层接线：disabledProbe 闭包必须在滚动发生时读 notifier，而不是
      // 构造时快照。若快照化，eink 下拖动会让 dock 收起；widget 层测试
      // （直接翻 disabledProbe）测不到这条接线。
      einkModeNotifier.value = true;
      await tester.pump();
      await tester.dragFrom(const Offset(200, 300), const Offset(0, -200));
      await tester.pump();
      expect(slideWidget().offset, Offset.zero, reason: 'eink 下滚动不许收起 dock');
      expect(tester.takeException(), isNull);
      // _verifyInvariants 先于 tearDown 检查 debug 变量，必须在这里复位。
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
