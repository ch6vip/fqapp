import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/widgets/player/playlet_option_sheet.dart';

/// 底栏「倍速」「清晰度」直连的档位弹层。
///
/// 官方依据：档位表含 2x/3x、无 1.75x（用户设备实测，
/// `PlayerPreferences.playbackRates`）；选中档高亮 + 对勾、选中即收起
/// （与横屏右侧档位面板 `PlayerSidePanelOptionList` 同语义）。
void main() {
  Future<void> mount(
    WidgetTester tester,
    Future<Object?> Function(BuildContext) open,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async => open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the rate sheet lists the official playrates', (tester) async {
    await mount(tester, (context) => showPlayletRateSheet(context, rate: 1));
    expect(find.byKey(const ValueKey('player-rate-sheet')), findsOneWidget);
    for (final label in ['0.75x', '1x', '1.25x', '1.5x', '2x', '3x']) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-rate-sheet')),
          matching: find.text(label),
        ),
        findsOneWidget,
        reason: '缺少档位 $label',
      );
    }
    expect(find.text('1.75x'), findsNothing, reason: '官方档位表里没有 1.75x');
    expect(find.text('1x（默认）'), findsNothing, reason: '档位不带（默认）后缀');
    expect(tester.takeException(), isNull);
  });

  testWidgets('picking a rate returns it and closes the sheet', (tester) async {
    Object? picked;
    await mount(tester, (context) async {
      picked = await showPlayletRateSheet(context, rate: 1);
      return picked;
    });
    await tester.tap(find.byKey(const ValueKey('player-rate-sheet-3')));
    await tester.pumpAndSettle();
    expect(picked, 1.5);
    expect(find.byKey(const ValueKey('player-rate-sheet')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the quality sheet marks the current rendition', (tester) async {
    const variants = [
      EpisodeVariant(name: '1080P', url: 'u1080', keyHex: 'k', height: 1080),
      EpisodeVariant(name: '720P', url: 'u720', keyHex: 'k', height: 720),
    ];
    await mount(
      tester,
      (context) => showPlayletQualitySheet(
        context,
        variants: variants,
        currentUrl: 'u720',
      ),
    );
    final current = find.byKey(const ValueKey('player-quality-sheet-1'));
    expect(current, findsOneWidget);
    expect(
      find.descendant(of: current, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    // 非当前档不画对勾，两档都点得到。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('player-quality-sheet-0')),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('player-quality-sheet-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-quality-sheet')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short window keeps every option reachable', (tester) async {
    // 矮窗口 + 大字号：弹层高度受限，档位靠滚动都能点到。
    tester.view.physicalSize = const Size(360, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await mount(
      tester,
      (context) => showPlayletRateSheet(context, rate: 1, dark: false),
    );
    final last = find.byKey(const ValueKey('player-rate-sheet-5'));
    await tester.scrollUntilVisible(
      last,
      48,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('player-rate-sheet')),
        matching: find.byType(Scrollable),
      ),
    );
    // 最后一档滚得到（ListView 是懒建的，滚不到就找不到）。
    expect(last, findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-rate-sheet')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
