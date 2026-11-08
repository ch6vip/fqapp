import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/player/playlet_quick_catalog_sheet.dart';
import 'package:fqapp/widgets/series_detail/series_detail_common.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

/// Classic/archive presentation for the two shared media surfaces in this
/// slice: the short-drama section header and the feed quick catalogue.
///
/// The quick catalogue keeps the fqapp offline identity fix (the single-video
/// fallback is never presented as episode 1) in both styles.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('区块头：经典 15sp 文本头与档案编号头随主题切换', (tester) async {
    final store = AppThemeStyleStore()..value = AppThemeStyle.classic;
    addTearDown(store.dispose);
    await tester.pumpWidget(
      AppUiHost(
        store: store,
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: SeriesSectionHeader(title: '选集'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ArchiveSection), findsNothing);
    final classicTitle = tester.widget<Text>(find.text('选集'));
    expect(classicTitle.style?.fontSize, 15);
    expect(classicTitle.style?.height, 1.6);
    expect(classicTitle.style?.fontWeight, FontWeight.w700);
    expect(
      classicTitle.style?.color,
      HomePalette.of(tester.element(find.text('选集'))).ink,
    );

    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();

    expect(find.byType(ArchiveSection), findsOneWidget);
    final archiveTitle = tester.widget<Text>(find.text('选集'));
    expect(archiveTitle.style?.fontSize, 18);
  });

  testWidgets('快速选集：完整目录显示集号并可选择', (tester) async {
    final selected = <int>[];
    await _pumpQuickCatalogue(
      tester,
      item: _seriesItem(),
      loader: (_, _) async => [
        [
          Chapter(itemId: 'ep0', title: '第一集', volumeName: '剧集'),
          Chapter(itemId: 'ep1', title: '第二集', volumeName: '剧集'),
        ],
      ],
      onEpisodeSelected: (index, _) => selected.add(index),
    );

    expect(find.text('共2集'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.text('2'));
    await tester.pumpAndSettle();

    expect(selected, [1]);
    expect(find.byType(PlayletQuickCatalogSheet), findsNothing);
  });

  testWidgets('快速选集：目录为空时退回当前视频，不冒充第 1 集', (tester) async {
    final selected = <int>[];
    await _pumpQuickCatalogue(
      tester,
      item: _seriesItem(episodeId: 'only'),
      history: MemoryReaderStore(
        entry: {
          'id': 'series',
          'episodeId': 'only',
          'episode': 0,
          'position': 30.0,
        },
      ),
      loader: (_, _) async => const [],
      onEpisodeSelected: (index, _) => selected.add(index),
    );

    expect(find.text('完整目录暂不可用'), findsOneWidget);
    expect(find.text('上次看到：当前视频'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    expect(find.text('共1集'), findsNothing);
    expect(find.text('第1集'), findsNothing);
    expect(find.text('上次看到：第1集'), findsNothing);

    await tester.tap(find.text('当前'));
    await tester.pumpAndSettle();
    expect(selected, [0]);
  });

  testWidgets('快速选集：取目录失败但单集仍可播，集号未知', (tester) async {
    await _pumpQuickCatalogue(
      tester,
      item: _seriesItem(episodeId: 'only'),
      loader: (_, _) async => throw const ApiException('剧集列表暂时无法加载'),
      onEpisodeSelected: (_, _) {},
    );

    expect(find.text('完整目录暂不可用'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    expect(find.text('共1集'), findsNothing);
  });
}

MediaItem _seriesItem({String? episodeId}) => MediaItem(
  id: episodeId ?? 'series',
  seriesId: 'series',
  episodeId: episodeId,
  title: '搜索到的这一集',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'video',
);

Future<void> _pumpQuickCatalogue(
  WidgetTester tester, {
  required MediaItem item,
  required Future<List<List<Chapter>>> Function(String id, String tab) loader,
  required void Function(int episodeIndex, List<Chapter> allEpisodes)
  onEpisodeSelected,
  MemoryReaderStore? history,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              PlayletQuickCatalogSheet.show(
                context,
                item: item,
                directoryLoader: loader,
                historyStore: history,
                onEpisodeSelected: onEpisodeSelected,
                onFullscreen: () {},
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
