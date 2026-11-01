import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/audio_time_track.dart';
import 'package:fqapp/models/book_detail.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/audio_page_theme.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/widgets/home/home_sheet.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'support/controlled_player.dart';

/// 听书页的视觉对齐回归：墨水屏纯黑白配色，以及播放速度 / 播放设置 /
/// 定时关闭 / 目录四个弹层共用 HomeSheetFrame 外壳。
///
/// 从 `audio_real_alignment_test.dart` 拆出来，避免两边测试合并后超出
/// `scripts/line_budget.json` 的记录行数。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
  });

  testWidgets('eink renders the listening page in pure black and white', (
    tester,
  ) async {
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = false);
    await _mount(tester, _RealSession());

    final scope = tester.widget<AudioPageThemeScope>(
      find.byType(AudioPageThemeScope),
    );
    expect(scope.theme, AudioPageTheme.eink);
    expect(scope.eink, isTrue);
    expect(scope.oled, isFalse);
    final scaffold = tester.widget<Scaffold>(
      find.byKey(const ValueKey('audio_session_book')),
    );
    expect(scaffold.backgroundColor, Colors.white);
  });

  testWidgets('the playback sheets share the HomeSheetFrame shell', (
    tester,
  ) async {
    await _mount(tester, _RealSession());

    Future<void> openAndCheck(Finder opener, String title) async {
      await tester.ensureVisible(opener);
      await tester.tap(opener);
      await tester.pumpAndSettle();
      expect(find.byType(HomeSheetFrame), findsOneWidget);
      expect(find.text(title), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
    }

    await openAndCheck(find.byKey(const ValueKey('audio-speed')), '播放速度');
    await openAndCheck(find.byKey(const ValueKey('audio_more')), '播放设置');
    await openAndCheck(find.byKey(const ValueKey('audio_sleep')), '定时关闭');

    // #220 之后真人模式的书籍行不再渲染 `audio_book_bar`，目录入口改到
    // 控制行的「目录」；弹层仍然必须是 HomeSheetFrame。
    await tester.ensureVisible(find.text('目录'));
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeSheetFrame), findsOneWidget);
    expect(find.text('目录 · 3 集'), findsOneWidget);
    expect(find.byIcon(LucideIcons.search), findsOneWidget);
  });
}

AudioSource _source(String id, String? toneId) => AudioSource(
  itemId: id,
  url: 'https://example.invalid/$id-${toneId ?? '0'}.mp3',
  toneId: toneId ?? '0',
);

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _flush(tester);
}

Future<void> _mount(
  WidgetTester tester,
  _RealSession session, {
  Size size = const Size(430, 932),
}) async {
  await tester.binding.setSurfaceSize(size);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await _unmount(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(session.app());
  await _flush(tester);
}

/// A 真人讲书 book: `genre_type == 1`, one narrator version, one linked TTS
/// novel, and a populated detail for the intro side.
class _RealSession {
  final List<_AudioPlayer> players = [];

  Widget app() => MaterialApp(
    home: AudioPage(
      bookId: 'book',
      title: '测试听书',
      chapters: [
        for (var index = 1; index <= 3; index++)
          Chapter(itemId: '$index', title: '第$index章', volumeName: '第一卷'),
      ],
      historyStore: ControlledReaderStore(),
      sourceLoader: (id, {toneId}) async => _source(id, toneId),
      voicesLoader: () async => const [],
      subtitleLoader: (_, _) async => SubtitleTrack.empty,
      timePointLoader: (_, _) async => AudioTimeTrack.empty,
      excerptLoader: (_) async => null,
      extrasLoader: (_) async => AudioExtras(
        tones: const AudioToneSet(
          genreType: 1,
          narratorTones: [
            AudioTone(id: '7239243941252598845', title: '主播：老恒'),
          ],
          ttsTones: [AudioTone(id: '96', title: '多角色对话升级版')],
        ),
        related: const [
          RelatedWork(
            kind: 'book',
            id: '7180279419959774247',
            title: '原著小说同名作品',
            label: '原著小说',
          ),
        ],
        detail: const BookDetail(
          bookId: 'book',
          title: '测试听书',
          author: BookAuthor(name: '老恒'),
          abstract:
              '这是一段用于对齐的简介，长度足够触发展开按钮的显示阈值，'
              '因此简介面会渲染「展开」入口而不是空白。',
          category: '都市脑洞',
          creationStatus: 1,
          wordNumber: 1328318,
        ),
      ),
      playerFactory: () {
        final player = _AudioPlayer();
        players.add(player);
        return player;
      },
    ),
  );
}

class _AudioPlayer extends ControlledNativePlayer {
  _AudioPlayer();
}
