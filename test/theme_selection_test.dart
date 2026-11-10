import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/pages/theme_page.dart';
import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.light;
  });
  tearDown(() {
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
  });

  test('both styles carry tokens through normal, OLED and e-ink themes', () {
    for (final style in AppThemeStyle.values) {
      for (final brightness in Brightness.values) {
        final theme = AppTheme.createTheme(brightness, style: style);
        expect(theme.extension<AppStyleTokens>()?.style, style);
        final ported = WenkuTheme.create(brightness, style: style);
        expect(ported.extension<AppStyleTokens>()?.style, style);
        expect(ported.extension<WenkuAppearance>(), isNotNull);
        expect(ported.extension<WenkuTonalColors>(), isNotNull);
      }
      final oled = WenkuTheme.create(Brightness.dark, oled: true, style: style);
      expect(oled.scaffoldBackgroundColor, Colors.black);
      expect(oled.colorScheme.surface, isNot(Colors.black));
      final eink = WenkuTheme.create(
        Brightness.dark,
        eink: true,
        oled: true,
        style: style,
      );
      expect(eink.brightness, Brightness.light);
      expect(eink.scaffoldBackgroundColor, Colors.white);
      expect(eink.colorScheme.onSurface, Colors.black);
      expect(eink.extension<AppStyleTokens>()?.style, style);
    }
  });

  test('reader paper colours survive app style changes', () {
    for (final preset in ReaderThemePreset.values) {
      final archive = preset.theme(AppTheme.createTheme(Brightness.light));
      final classic = preset.theme(
        AppTheme.createTheme(Brightness.light, style: AppThemeStyle.classic),
      );
      expect(classic.scaffoldBackgroundColor, archive.scaffoldBackgroundColor);
      expect(classic.colorScheme.onSurface, archive.colorScheme.onSurface);
      expect(preset.backgroundColor, classic.scaffoldBackgroundColor);
      expect(classic.extension<AppStyleTokens>()?.style, AppThemeStyle.classic);
    }
  });

  testWidgets(
    'shared headers and panels restyle without replacing child state',
    (tester) async {
      final style = ValueNotifier(AppThemeStyle.archive);
      addTearDown(style.dispose);
      await tester.pumpWidget(
        _app(
          style,
          const WenkuScope(
            entrance: false,
            child: Scaffold(
              body: Column(
                children: [
                  ArchiveMasthead(title: '设置', code: '04 / SYSTEM PROFILE'),
                  ContentPanel(child: _RetainedCounter()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('计数 0'));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(_RetainedCounter));
      expect(find.text('04 / SYSTEM PROFILE'), findsOneWidget);
      RoundedRectangleBorder shape() =>
          tester
                  .widget<Material>(
                    find
                        .descendant(
                          of: find.byType(ContentPanel),
                          matching: find.byType(Material),
                        )
                        .first,
                  )
                  .shape!
              as RoundedRectangleBorder;
      expect(shape().borderRadius, BorderRadius.circular(4));
      style.value = AppThemeStyle.classic;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_RetainedCounter)), same(state));
      expect(find.text('计数 1'), findsOneWidget);
      expect(find.text('04 / SYSTEM PROFILE'), findsNothing);
      expect(shape().borderRadius, BorderRadius.circular(16));
      expect(
        AppStyleTokens.of(tester.element(find.byType(ContentPanel))).style,
        AppThemeStyle.classic,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings exposes a direct theme route', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-entry-主题')));
    await tester.pumpAndSettle();
    expect(find.byType(ThemePage), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-choice-classic')), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-choice-archive')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('both theme cards sit side by side and fit a phone screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: ThemePage(store: store),
      ),
    );
    await tester.pumpAndSettle();
    final classic = tester.getRect(
      find.byKey(const ValueKey('theme-choice-classic')),
    );
    final archive = tester.getRect(
      find.byKey(const ValueKey('theme-choice-archive')),
    );
    // Comparing the two styles must not require scrolling past one of them.
    expect(classic.top, archive.top);
    expect(classic.right, lessThan(archive.left));
    expect(archive.bottom, lessThan(640));
    expect(
      find.byKey(const ValueKey('theme-selected-archive-true')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('theme-selected-classic-false')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('choosing a theme preserves pushed route and saves selection', (
    tester,
  ) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    final navigator = GlobalKey<NavigatorState>();
    final editor = TextEditingController(text: '保留输入');
    addTearDown(editor.dispose);
    var initializations = 0;
    await tester.pumpWidget(
      ValueListenableBuilder<AppThemeStyle>(
        valueListenable: store,
        builder: (context, style, _) => MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.createTheme(Brightness.light, style: style),
          home: _RetainedCounter(onInit: () => initializations++),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: TextField(controller: editor)),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => ThemePage(store: store)),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(ThemePage));
    await tester.tap(find.byKey(const ValueKey('theme-choice-classic')));
    await tester.pumpAndSettle();
    expect(store.value, AppThemeStyle.classic);
    expect(tester.state(find.byType(ThemePage)), same(state));
    expect(
      find.byKey(const ValueKey('theme-selected-classic-true')),
      findsOneWidget,
    );
    expect(
      (await SharedPreferences.getInstance()).getString(
        AppThemeStyleStore.storageKey,
      ),
      'classic',
    );
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('保留输入'), findsOneWidget);
    expect(initializations, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [const Size(320, 560), const Size(800, 360)]) {
    testWidgets('theme previews fit $size with large text', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.createTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: ThemePage(store: store),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('theme-choice-archive')).hitTestable(),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _app(ValueNotifier<AppThemeStyle> style, Widget child) =>
    ValueListenableBuilder<AppThemeStyle>(
      valueListenable: style,
      child: child,
      builder: (context, value, child) => MaterialApp(
        theme: AppTheme.createTheme(Brightness.light, style: value),
        home: child,
      ),
    );

class _RetainedCounter extends StatefulWidget {
  const _RetainedCounter({this.onInit});
  final VoidCallback? onInit;

  @override
  State<_RetainedCounter> createState() => _RetainedCounterState();
}

class _RetainedCounterState extends State<_RetainedCounter> {
  int count = 0;

  @override
  void initState() {
    super.initState();
    widget.onInit?.call();
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => count++),
    child: Text('计数 $count'),
  );
}
