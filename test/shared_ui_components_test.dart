import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/home/home_back_button.dart';
import 'package:fqapp/widgets/home/home_chip.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_feed_states.dart';
import 'package:fqapp/widgets/home/home_sheet.dart';
import 'package:fqapp/widgets/home/home_stream_footer.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';
import 'package:fqapp/widgets/shelf/shelf_design.dart';

Widget _app(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? AppTheme.createTheme(Brightness.light),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    einkModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
  });

  test('全局画布与 HomePalette.canvas 对齐，AppBar 不再另起一色', () {
    void expectsAligned(ThemeData theme, HomePalette palette) {
      expect(theme.scaffoldBackgroundColor, palette.canvas);
      expect(theme.canvasColor, palette.canvas);
      expect(theme.appBarTheme.backgroundColor, palette.canvas);
      expect(theme.appBarTheme.elevation, 0);
      expect(theme.appBarTheme.scrolledUnderElevation, 0);
      expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
    }

    expectsAligned(
      AppTheme.createTheme(Brightness.light),
      const HomePalette(false),
    );
    expectsAligned(
      AppTheme.createTheme(Brightness.dark),
      const HomePalette(true),
    );
    expectsAligned(
      AppTheme.createTheme(Brightness.dark, oledMode: true),
      const HomePalette(true, oled: true),
    );
    expectsAligned(
      AppTheme.createTheme(Brightness.light, einkMode: true),
      const HomePalette(false, eink: true),
    );
    // 官方书城底色：浅色画布不再用暖纸色 #FCFAF7。
    expect(
      AppTheme.createTheme(Brightness.light).scaffoldBackgroundColor,
      const Color(0xFFF6F6F6),
    );
  });

  testWidgets('浅色 HomeChip 是 soft 底 + ink 实心选中', (tester) async {
    await tester.pumpWidget(
      _app(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HomeChip(
              key: const Key('chip-light-selected'),
              label: '已选',
              selected: true,
              onTap: () {},
            ),
            HomeChip(
              key: const Key('chip-light-plain'),
              label: '未选',
              selected: false,
              onTap: () {},
            ),
          ],
        ),
      ),
    );
    const palette = HomePalette(false);
    ShapeDecoration decoration(String key) =>
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byKey(Key(key)),
                    matching: find.byType(Container),
                  ),
                )
                .decoration
            as ShapeDecoration;
    expect(decoration('chip-light-selected').color, palette.ink);
    expect(decoration('chip-light-plain').color, palette.soft);
    expect(
      (decoration('chip-light-plain').shape as StadiumBorder).side,
      BorderSide.none,
    );
    expect(tester.widget<Text>(find.text('已选')).style!.color, palette.canvas);
  });

  testWidgets('墨水屏下 HomeChip 选中黑底白字、未选中白底黑字并描边', (tester) async {
    einkModeNotifier.value = true;
    final theme = AppTheme.createTheme(Brightness.light, einkMode: true);
    await tester.pumpWidget(
      _app(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HomeChip(
              key: const Key('chip-eink-selected'),
              label: '已选',
              selected: true,
              onTap: () {},
            ),
            HomeChip(
              key: const Key('chip-eink-plain'),
              label: '未选',
              selected: false,
              onTap: () {},
            ),
          ],
        ),
        theme: theme,
      ),
    );

    ShapeDecoration decoration(String key) =>
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byKey(Key(key)),
                    matching: find.byType(Container),
                  ),
                )
                .decoration
            as ShapeDecoration;
    final selected = decoration('chip-eink-selected');
    final plain = decoration('chip-eink-plain');
    expect(selected.color, Colors.black);
    expect((selected.shape as StadiumBorder).side, BorderSide.none);
    expect(plain.color, Colors.white);
    final plainSide = (plain.shape as StadiumBorder).side;
    expect(plainSide.color, Colors.black);
    expect(plainSide.width, 1);
    expect(tester.widget<Text>(find.text('已选')).style!.color, Colors.white);
    expect(tester.widget<Text>(find.text('未选')).style!.color, Colors.black);
    for (final key in ['chip-eink-selected', 'chip-eink-plain']) {
      expect(
        tester.getSize(find.byKey(Key(key))).height,
        greaterThanOrEqualTo(HomeChip.minTapTarget),
      );
    }
  });

  testWidgets('墨水屏下 SettingsSwitch 纯黑白且两种状态可区分', (tester) async {
    einkModeNotifier.value = true;
    final theme = AppTheme.createTheme(Brightness.light, einkMode: true);
    await tester.pumpWidget(
      _app(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SettingsSwitch(
              key: const Key('switch-on'),
              value: true,
              onChanged: (_) {},
            ),
            SettingsSwitch(
              key: const Key('switch-off'),
              value: false,
              onChanged: (_) {},
            ),
          ],
        ),
        theme: theme,
      ),
    );
    Switch switchOf(String key) => tester.widget<Switch>(
      find.descendant(of: find.byKey(Key(key)), matching: find.byType(Switch)),
    );

    final on = switchOf('switch-on');
    expect(on.thumbColor!.resolve({WidgetState.selected}), Colors.white);
    expect(on.trackColor!.resolve({WidgetState.selected}), Colors.black);
    expect(on.trackOutlineColor!.resolve({WidgetState.selected}), Colors.black);

    final off = switchOf('switch-off');
    expect(off.thumbColor!.resolve(const {}), Colors.black);
    expect(off.trackColor!.resolve(const {}), Colors.white);
    expect(off.trackOutlineColor!.resolve(const {}), Colors.black);
  });

  testWidgets('流尾三态用 muted 文字色，重试可点高度不小于 44', (tester) async {
    var retried = 0;
    const palette = HomePalette(false);
    await tester.pumpWidget(
      _app(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const HomeStreamFooter.loading(key: Key('footer-loading')),
            const HomeStreamFooter.done(key: Key('footer-done')),
            HomeStreamFooter.retry(
              key: const Key('footer-retry'),
              onRetry: () => retried++,
            ),
          ],
        ),
      ),
    );
    for (final key in ['footer-loading', 'footer-done']) {
      final text = tester.widget<Text>(
        find
            .descendant(of: find.byKey(Key(key)), matching: find.byType(Text))
            .first,
      );
      expect(text.style!.color, palette.muted);
    }
    expect(
      tester.widget<Text>(find.text('加载失败，点击重试')).style!.color,
      palette.muted,
    );
    final hit = find.descendant(
      of: find.byKey(const Key('footer-retry')),
      matching: find.byType(GestureDetector),
    );
    expect(tester.getSize(hit).height, greaterThanOrEqualTo(44));
    await tester.tap(find.text('加载失败，点击重试'));
    expect(retried, 1);
  });

  testWidgets('showHomeSheet 使用 homeSheetColor 与统一圆角', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showHomeSheet<void>(
                  context: context,
                  title: '选择一项',
                  children: const [Text('内容')],
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.backgroundColor, homeSheetColor(const HomePalette(true)));
    final shape = sheet.shape! as RoundedRectangleBorder;
    expect(
      shape.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(HomeSheetFrame.radius)),
    );
    expect(find.text('选择一项'), findsOneWidget);
    expect(find.text('内容'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('内容'), findsNothing);
  });

  testWidgets('SettingsGroupCard 单一圆角 + surface/line 描边', (tester) async {
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 360,
          child: SettingsGroupCard(
            children: [
              const SettingsRow(title: '第一项'),
              const SettingsRow(title: '第二项'),
            ],
          ),
        ),
      ),
    );
    const palette = HomePalette(false);
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SettingsGroupCard),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, palette.surface);
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.side.color, palette.line);
    expect(shape.side.width, 0.6);
    expect(shape.borderRadius, BorderRadius.circular(SettingsGroupCard.radius));
    final divider = tester.widget<Divider>(find.byType(Divider));
    expect(divider.indent, SettingsGroupCard.dividerIndent);
  });

  testWidgets('深色下设置卡片与行跟随 surface / ink', (tester) async {
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 360,
          child: SettingsGroupCard(children: const [SettingsRow(title: '深色行')]),
        ),
        theme: AppTheme.createTheme(Brightness.dark),
      ),
    );
    const palette = HomePalette(true);
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SettingsGroupCard),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, palette.surface);
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.side.color, palette.line);
    expect(tester.widget<Text>(find.text('深色行')).style!.color, palette.ink);
  });

  testWidgets('SettingsRow 无副标题至少 52、有副标题至少 64', (tester) async {
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 360,
          child: SettingsGroupCard(
            children: [
              const SettingsRow(key: Key('row-plain'), title: '仅标题'),
              const SettingsRow(
                key: Key('row-sub'),
                title: '带副标题',
                subtitle: '说明文字',
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const Key('row-plain'))).height,
      greaterThanOrEqualTo(SettingsRow.minHeight),
    );
    expect(
      tester.getSize(find.byKey(const Key('row-sub'))).height,
      greaterThanOrEqualTo(SettingsRow.minHeightWithSubtitle),
    );
    expect(tester.widget<Text>(find.text('仅标题')).style!.fontSize, 15);
    final subtitle = tester.widget<Text>(find.text('说明文字'));
    expect(subtitle.style!.fontSize, 12.5);
    expect(subtitle.style!.color, const HomePalette(false).muted);
  });

  testWidgets('SettingsScaffold 画布与 AppBar 同色且无 elevation', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SettingsScaffold(title: '设置', body: Text('内容')),
      ),
    );
    const palette = HomePalette(false);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, palette.canvas);
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.backgroundColor, palette.canvas);
    expect(appBar.elevation, 0);
    expect(appBar.scrolledUnderElevation, 0);
    expect(appBar.surfaceTintColor, Colors.transparent);
    expect(find.byTooltip('返回'), findsOneWidget);
  });

  testWidgets('HomeBackButton 使用 Lucide chevron_left 且 tooltip 为返回', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const HomeBackButton()));
    expect(find.byTooltip('返回'), findsOneWidget);
    final icon = tester.widget<Icon>(find.byIcon(LucideIcons.chevron_left));
    expect(icon.size, 20);
    final button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.tooltip, '返回');
  });

  testWidgets('HomeStateView 紧凑态显示图标砖、标题、说明与动作', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      _app(
        HomeStateView(
          icon: LucideIcons.cloud_off,
          title: '没有更多',
          message: '换个分类试试',
          actionLabel: '重试',
          onAction: () => tapped++,
        ),
      ),
    );
    expect(find.byIcon(LucideIcons.cloud_off), findsOneWidget);
    expect(find.text('没有更多'), findsOneWidget);
    expect(find.text('换个分类试试'), findsOneWidget);
    expect(
      tester.getSize(find.widgetWithText(TextButton, '重试')).height,
      greaterThanOrEqualTo(44),
    );
    await tester.tap(find.text('重试'));
    expect(tapped, 1);
  });

  testWidgets('showSettingsConfirmDialog 破坏性确认使用书架删除红', (tester) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  confirmed = await showSettingsConfirmDialog(
                    context: context,
                    title: '删除',
                    message: '无法撤销',
                    confirmLabel: '删除',
                    destructive: true,
                  );
                },
                child: const Text('执行'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('执行'));
    await tester.pumpAndSettle();
    expect(find.text('无法撤销'), findsOneWidget);
    final confirmButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '删除'),
    );
    expect(
      confirmButton.style!.foregroundColor!.resolve(const {}),
      ShelfTokens.deleteRed,
    );
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('墨水屏破坏性确认键为黑字黑描边，与白色对话框可区分', (tester) async {
    einkModeNotifier.value = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light, einkMode: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showSettingsConfirmDialog(
                  context: context,
                  title: '删除',
                  confirmLabel: '删除',
                  destructive: true,
                ),
                child: const Text('执行'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('执行'));
    await tester.pumpAndSettle();

    final confirmButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '删除'),
    );
    final style = confirmButton.style!;
    // 破坏红不进入墨屏主题：前景纯黑。
    expect(style.foregroundColor!.resolve(const {}), Colors.black);
    // secondaryContainer 与对话框底都是白色，靠 1dp 黑描边划出按钮边界。
    final side = style.side!.resolve(const {});
    expect(side?.color, Colors.black);
    expect(side?.width, 1);
    expect(
      Theme.of(tester.element(find.byType(AlertDialog))).colorScheme.surface,
      Colors.white,
    );
  });
}
