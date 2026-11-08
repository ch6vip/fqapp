import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';

import 'support/app_ui_host.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetAppUiTestDiagnostics();
  });

  testWidgets('root, nested navigator and overlays share one live style', (
    tester,
  ) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    final navigatorKey = GlobalKey<NavigatorState>();
    final nestedKey = GlobalKey<NavigatorState>();
    final initializations = <String, int>{};

    await tester.pumpWidget(
      AppUiHost(
        store: store,
        navigatorKey: navigatorKey,
        home: _RootPage(
          nestedKey: nestedKey,
          initializations: initializations,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppUiScope), findsOneWidget);
    expect(find.text('root:archive:true'), findsOneWidget);
    expect(find.text('nested:archive:true'), findsOneWidget);

    // One overlay owned by the nested Navigator, one owned by the root one.
    await tester.tap(find.byKey(const ValueKey('nested-dialog')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('root-dialog')));
    await tester.pumpAndSettle();
    expect(find.text('nested-overlay:archive:true'), findsOneWidget);
    expect(find.text('root-overlay:archive:true'), findsOneWidget);

    final rootNavigator = navigatorKey.currentState;
    final nestedNavigator = nestedKey.currentState;
    final rootState = tester.state(find.byType(_RootPage));
    final nestedState = tester.state(find.byType(_NestedPage));
    expect(rootNavigator, isNotNull);
    expect(nestedNavigator, isNotNull);
    expect(initializations, {'root': 1, 'nested': 1});

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();

    // Every presentation surface already mounted follows the live style,
    // including both already-open overlays.
    expect(find.text('root:classic:false'), findsOneWidget);
    expect(find.text('nested:classic:false'), findsOneWidget);
    expect(find.text('root-overlay:classic:false'), findsOneWidget);
    expect(find.text('nested-overlay:classic:false'), findsOneWidget);

    // Switching presentation does not replace the owners or the routes.
    expect(navigatorKey.currentState, same(rootNavigator));
    expect(nestedKey.currentState, same(nestedNavigator));
    expect(tester.state(find.byType(_RootPage)), same(rootState));
    expect(tester.state(find.byType(_NestedPage)), same(nestedState));
    expect(initializations, {'root': 1, 'nested': 1});
    expect(find.byType(AppUiScope), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('only display readers rebuild; scope ignores animated tokens', (
    tester,
  ) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    final builds = <String, int>{};

    await tester.pumpWidget(
      AppUiHost(
        store: store,
        // Mirrors a stale captured theme: tokens stay archive even after the
        // live style changes, so the scope (not the theme) must win.
        followTheme: false,
        home: Column(
          children: [
            const _StyleProbe(name: 'live'),
            _BuildCounter(name: 'sibling', builds: builds),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('live:archive:true'), findsOneWidget);
    expect(builds['sibling'], 1);

    final siblingState = tester.state(find.byType(_BuildCounter));
    await store.select(AppThemeStyle.classic);
    await tester.pump();

    expect(find.text('live:classic:false'), findsOneWidget);
    expect(
      AppStyleTokens.of(tester.element(find.text('live:classic:false'))).style,
      AppThemeStyle.archive,
    );
    // A widget that does not read the scope is not rebuilt by the update.
    expect(builds['sibling'], 1);
    expect(tester.state(find.byType(_BuildCounter)), same(siblingState));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('discrete style switches before the theme animation settles', (
    tester,
  ) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      AppUiHost(
        store: store,
        themeAnimationDuration: const Duration(seconds: 1),
        home: const _TokenProbe(),
      ),
    );
    await tester.pump();
    expect(find.text('live:archive token:archive'), findsOneWidget);

    await store.select(AppThemeStyle.classic);
    await tester.pump();
    expect(find.text('live:classic token:archive'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('live:classic token:archive'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('live:classic token:classic'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a missing scope falls back to theme tokens and is measurable', (
    tester,
  ) async {
    for (final style in AppThemeStyle.values) {
      resetAppUiTestDiagnostics();
      AppUiPresentation? presentation;
      var available = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.createTheme(Brightness.light, style: style),
          home: Builder(
            builder: (context) {
              available = AppUiScope.isAvailable(context);
              presentation = AppUiScope.presentationOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(available, isFalse);
      expect(presentation?.style, style);
      expect(
        presentation?.showDecorativeCodes,
        style == AppThemeStyle.archive,
      );
      expect(AppUiScope.debugFallbackReads, greaterThan(0));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('production wiring keeps owners and exposes the scope', (
    tester,
  ) async {
    // Touch the singleton inside the test body on purpose: constructing it in
    // `setUp` creates its write queue in the real zone, and awaiting
    // `select()` from the test's fake-async zone then deadlocks.
    AppThemeStyleStore.instance.value = AppThemeStyle.archive;
    resetAppUiTestDiagnostics();
    await tester.pumpWidget(const ProviderScope(child: FqApp()));
    await tester.pump();

    final appState = tester.state(find.byType(FqApp));
    final rootNavigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    final audioScope = tester.state(find.byType(AudioPlaybackScope));
    expect(find.byType(AppUiScope), findsOneWidget);
    expect(AppUiScope.of(rootNavigator.context), AppThemeStyle.archive);

    await AppThemeStyleStore.instance.select(AppThemeStyle.classic);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.state(find.byType(FqApp)), same(appState));
    expect(
      tester.state<NavigatorState>(find.byType(Navigator).first),
      same(rootNavigator),
    );
    expect(tester.state(find.byType(AudioPlaybackScope)), same(audioScope));
    expect(AppUiScope.of(rootNavigator.context), AppThemeStyle.classic);

    rootNavigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const _StyleProbe(name: 'pushed'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('pushed:classic:false'), findsOneWidget);

    rootNavigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('pushed:classic:false'), findsNothing);
    expect(
      tester.state<NavigatorState>(find.byType(Navigator).first),
      same(rootNavigator),
    );
    // Every live-style read in this scenario went through the production
    // scope; nothing fell back to theme tokens.
    expect(AppUiScope.debugFallbackReads, 0);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    AppThemeStyleStore.instance.value = AppThemeStyle.archive;
  });
}

/// One probe per presentation surface: root route, nested route, root Overlay
/// and nested-Overlay. The trailing flag is the discrete policy value.
class _StyleProbe extends StatelessWidget {
  const _StyleProbe({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final presentation = AppUiScope.presentationOf(context);
    return Text(
      '$name:${presentation.style.name}:${presentation.showDecorativeCodes}',
    );
  }
}

class _TokenProbe extends StatelessWidget {
  const _TokenProbe();

  @override
  Widget build(BuildContext context) => Text(
    'live:${AppUiScope.of(context).name} '
    'token:${AppStyleTokens.of(context).style.name}',
  );
}

class _RootPage extends StatefulWidget {
  const _RootPage({required this.nestedKey, required this.initializations});

  final GlobalKey<NavigatorState> nestedKey;
  final Map<String, int> initializations;

  @override
  State<_RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<_RootPage> {
  @override
  void initState() {
    super.initState();
    _count(widget.initializations, 'root');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const _StyleProbe(name: 'root'),
        TextButton(
          key: const ValueKey('root-dialog'),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(
              content: _StyleProbe(name: 'root-overlay'),
            ),
          ),
          child: const Text('root dialog'),
        ),
        Expanded(
          child: Navigator(
            key: widget.nestedKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) =>
                  _NestedPage(initializations: widget.initializations),
            ),
          ),
        ),
      ],
    ),
  );
}

class _NestedPage extends StatefulWidget {
  const _NestedPage({required this.initializations});

  final Map<String, int> initializations;

  @override
  State<_NestedPage> createState() => _NestedPageState();
}

class _NestedPageState extends State<_NestedPage> {
  @override
  void initState() {
    super.initState();
    _count(widget.initializations, 'nested');
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const _StyleProbe(name: 'nested'),
      TextButton(
        key: const ValueKey('nested-dialog'),
        onPressed: () => showDialog<void>(
          context: context,
          useRootNavigator: false,
          builder: (_) => const AlertDialog(
            content: _StyleProbe(name: 'nested-overlay'),
          ),
        ),
        child: const Text('nested dialog'),
      ),
    ],
  );
}

class _BuildCounter extends StatefulWidget {
  const _BuildCounter({required this.name, required this.builds});

  final String name;
  final Map<String, int> builds;

  @override
  State<_BuildCounter> createState() => _BuildCounterState();
}

class _BuildCounterState extends State<_BuildCounter> {
  @override
  Widget build(BuildContext context) {
    _count(widget.builds, widget.name);
    return Text('sibling:${widget.builds[widget.name]}');
  }
}

void _count(Map<String, int> counts, String name) =>
    counts[name] = (counts[name] ?? 0) + 1;
