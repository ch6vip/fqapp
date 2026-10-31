import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/audio_time_track.dart';
import 'package:fqapp/models/book_detail.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/audio_page_theme.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/widgets/audio/audio_control_rows.dart';
import 'package:fqapp/widgets/audio/audio_real_expanded.dart';
import 'package:fqapp/widgets/audio/audio_real_sections.dart';
import 'package:fqapp/widgets/audio/audio_sections.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'support/controlled_player.dart';

/// 展开态全文（规格 S6）：
///
///  * 「展开」进入页内全文，不是弹层；
///  * 书籍行保留、⇋ 隐藏，字幕区/操作行/换版本行收起；
///  * 进度行与控制行保留，控制行只留图标（bare）；
///  * 当前词用 accent 10% 底色高亮，偏移来自 S5 的段落时间点；
///  * 字号、行距跟随阅读器排版设置，取不到时 20sp / 2.1。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
  });

  testWidgets('展开进入页内全文，并收起字幕、操作行与换版本行', (tester) async {
    final session = _ExpandedSession();
    await _mount(tester, session);

    // 默认态：字幕、操作行、⇋、换版本行都在。
    expect(find.byKey(const Key('audio_real_subtitle')), findsOneWidget);
    expect(find.byType(AudioIconRow), findsOneWidget);
    expect(find.byKey(const Key('audio_real_swap')), findsOneWidget);
    expect(find.text('换版本'), findsOneWidget);

    await tester.tap(find.byKey(const Key('audio_real_subtitle_expand')));
    await tester.pumpAndSettle();

    // 书籍行保留，⇋ 隐藏。
    expect(find.byType(AudioRealBookRow), findsOneWidget);
    expect(find.byKey(const Key('audio_real_swap')), findsNothing);
    // 字幕、操作行、换版本行收起。
    expect(find.byKey(const Key('audio_real_subtitle')), findsNothing);
    expect(find.byType(AudioIconRow), findsNothing);
    expect(find.text('换版本'), findsNothing);
    expect(find.byType(AudioRealVersionRow), findsNothing);
    // 进度行与控制行保留，控制行只留图标。
    expect(find.byType(AudioTimeSeekRow), findsOneWidget);
    final transport = tester.widget<AudioTransportRow>(
      find.byType(AudioTransportRow),
    );
    expect(transport.bare, isTrue);
    expect(find.text('目录'), findsNothing);
    expect(find.text('定时'), findsNothing);
    expect(find.byTooltip('目录'), findsOneWidget);
    expect(find.byTooltip('定时'), findsOneWidget);
    // 页内全文出现，且是页内而不是弹层。
    expect(find.byKey(const Key('audio_real_expanded')), findsOneWidget);
    expect(
      find.byKey(const Key('audio_real_expanded_paragraph_1')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('audio_real_fold')), findsOneWidget);

    // 「收起」回到默认态。
    await tester.tap(find.byKey(const Key('audio_real_fold')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio_real_expanded')), findsNothing);
    expect(find.byKey(const Key('audio_real_subtitle')), findsOneWidget);
    expect(find.byType(AudioIconRow), findsOneWidget);
    expect(find.byKey(const Key('audio_real_swap')), findsOneWidget);
    expect(find.text('换版本'), findsOneWidget);
  });

  testWidgets('当前词按时间点高亮，并随播放移动到下一段', (tester) async {
    final session = _ExpandedSession();
    await _mount(tester, session);
    await tester.tap(find.byKey(const Key('audio_real_subtitle_expand')));
    await tester.pumpAndSettle();

    final theme = AudioPageThemeScope.of(
      tester.element(find.byKey(const Key('audio_real_expanded'))),
    );
    final highlightColor = theme.accent.withValues(
      alpha: AudioRealExpandedTranscript.lightHighlightAlpha,
    );

    // 第一个时间点：第 1 段前 4 个字。
    expect(_highlightedText(tester, 'audio_real_expanded_paragraph_1'), '山门外的');
    expect(
      _highlightSpan(
        tester,
        'audio_real_expanded_paragraph_1',
      )?.style?.backgroundColor,
      highlightColor,
    );

    // 播放到第二个时间点：高亮移到第 2 段。
    session.players.single.emitPosition(const Duration(seconds: 6));
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(_highlightedText(tester, 'audio_real_expanded_paragraph_1'), isNull);
    expect(_highlightedText(tester, 'audio_real_expanded_paragraph_2'), '我愣在');
    expect(
      _highlightSpan(
        tester,
        'audio_real_expanded_paragraph_2',
      )?.style?.backgroundColor,
      highlightColor,
    );
  });

  testWidgets('没有时间点时字幕照常显示，但没有「展开」入口', (tester) async {
    final session = _ExpandedSession(timePoints: _noTimePoints);
    await _mount(tester, session);
    expect(find.text('第一句同步字幕'), findsOneWidget);
    expect(find.byKey(const Key('audio_real_subtitle_expand')), findsNothing);
  });

  testWidgets('正文拉取失败时显示状态，仍能收起', (tester) async {
    final session = _ExpandedSession(failContent: true);
    await _mount(tester, session);
    await tester.tap(find.byKey(const Key('audio_real_subtitle_expand')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio_real_expanded_error')), findsOneWidget);
    expect(find.byKey(const Key('audio_real_fold')), findsOneWidget);

    await tester.tap(find.byKey(const Key('audio_real_fold')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio_real_subtitle')), findsOneWidget);
  });

  testWidgets('正文字号、行距与段首缩进跟随阅读器排版设置', (tester) async {
    SharedPreferences.setMockInitialValues({
      'reader_font_size': 22.0,
      'reader_line_height': 2.0,
    });
    final session = _ExpandedSession();
    await _mount(tester, session);
    await tester.tap(find.byKey(const Key('audio_real_subtitle_expand')));
    await tester.pumpAndSettle();

    final paragraph = tester.widget<Text>(
      find.byKey(const Key('audio_real_expanded_paragraph_1')),
    );
    final style = paragraph.textSpan!.style!;
    expect(style.fontSize, 22);
    expect(style.height, 2.0);
    // 段首缩进 2 字：首个子项是零高占位。
    final span = paragraph.textSpan! as TextSpan;
    final indent = span.children!.first as WidgetSpan;
    expect((indent.child as SizedBox).width, 44);
  });

  testWidgets('展开过渡 300ms，进度与控制行在切换中不移动', (tester) async {
    final session = _ExpandedSession();
    await _mount(tester, session);

    final switcher = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher).first,
    );
    expect(switcher.duration, AudioRealExpandedTranscript.transitionDuration);
    expect(switcher.switchInCurve, AudioRealExpandedTranscript.transitionCurve);
    expect(
      switcher.switchOutCurve,
      AudioRealExpandedTranscript.transitionCurve,
    );

    await tester.tap(find.byKey(const Key('audio_real_subtitle_expand')));
    await tester.pump(const Duration(milliseconds: 100));

    final expandedBody = find.byKey(const Key('audio_real_expanded_body'));
    expect(expandedBody, findsOneWidget);
    Rect rowIn(Key key) => tester.getRect(
      find.descendant(of: expandedBody, matching: find.byKey(key)),
    );
    final midSeek = tester.getRect(
      find.descendant(
        of: expandedBody,
        matching: find.byType(AudioTimeSeekRow),
      ),
    );
    final midTransport = tester.getRect(
      find.descendant(
        of: expandedBody,
        matching: find.byType(AudioTransportRow),
      ),
    );

    await tester.pumpAndSettle();
    expect(
      tester.getRect(
        find.descendant(
          of: expandedBody,
          matching: find.byType(AudioTimeSeekRow),
        ),
      ),
      midSeek,
    );
    expect(
      tester.getRect(
        find.descendant(
          of: expandedBody,
          matching: find.byType(AudioTransportRow),
        ),
      ),
      midTransport,
    );
    // 目录/定时只是文字收起，图标仍在原位。
    expect(
      tester
          .getRect(
            find.descendant(of: expandedBody, matching: find.byTooltip('目录')),
          )
          .height,
      closeTo(
        tester
            .getRect(
              find.descendant(
                of: expandedBody,
                matching: find.byIcon(LucideIcons.list),
              ),
            )
            .height,
        0.1,
      ),
    );
    expect(rowIn(const Key('audio_real_fold')).height, 36);
  });
}

/// 当前段里被 accent 底色覆盖的文字；没有高亮时返回 null。
String? _highlightedText(WidgetTester tester, String paragraphKey) {
  final span = _highlightSpan(tester, paragraphKey);
  return span?.text;
}

TextSpan? _highlightSpan(WidgetTester tester, String paragraphKey) {
  final paragraph = tester.widget<Text>(find.byKey(Key(paragraphKey)));
  final root = paragraph.textSpan! as TextSpan;
  for (final span in root.children ?? const <InlineSpan>[]) {
    if (span is TextSpan && span.style?.backgroundColor != null) return span;
  }
  return null;
}

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
  _ExpandedSession session, {
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
  // 时间点/字幕是异步到达的，再推一拍确保快照带上章节映射。
  session.players.single.emitPosition(const Duration(seconds: 1));
  await _flush(tester);
}

Future<AudioTimeTrack> _noTimePoints(String _, String _) async =>
    AudioTimeTrack.empty;

AudioSource _source(String id, String? toneId) => AudioSource(
  itemId: id,
  url: 'https://example.invalid/$id-${toneId ?? '0'}.mp3',
  toneId: toneId ?? '0',
);

const _subtitleTrack = SubtitleTrack([
  SubtitleCue(startMs: 0, text: '第一句同步字幕'),
  SubtitleCue(startMs: 4000, text: '第二句同步字幕'),
]);

/// 两个时间点分别指向正文第 1、2 段；正文开头的章名段会被剥掉。
const _timeTrack = AudioTimeTrack(
  [
    AudioSyncPoint(
      startTime: 0,
      startPara: 1,
      startParaOff: 0,
      endPara: 1,
      endParaOff: 3,
    ),
    AudioSyncPoint(
      startTime: 5000,
      startPara: 2,
      startParaOff: 0,
      endPara: 2,
      endParaOff: 2,
    ),
  ],
  textItemId: 'novel-1',
  novelItemId: 'novel-1',
  novelChapterTitle: '第一章 测试',
);

ChapterContent _chapterContent() => ChapterContent(
  blocks: const [
    ChapterParagraph('第一章 测试', paraIndex: 0),
    ChapterParagraph('山门外的雾还没散，师姐打了个哈欠。', paraIndex: 1),
    ChapterParagraph('我愣在原地，手里的木剑差点掉下去。', paraIndex: 2),
  ],
);

class _ExpandedSession {
  final Future<AudioTimeTrack> Function(String itemId, String toneId)
  timePoints;
  final bool failContent;
  final List<_AudioPlayer> players = [];

  _ExpandedSession({
    this.timePoints = _defaultTimePoints,
    this.failContent = false,
  });

  static Future<AudioTimeTrack> _defaultTimePoints(String _, String _) async =>
      _timeTrack;

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
      subtitleLoader: (_, _) async => _subtitleTrack,
      timePointLoader: (itemId, toneId) => timePoints(itemId, toneId),
      contentLoader: (_) async {
        if (failContent) throw StateError('content unavailable');
        return _chapterContent();
      },
      excerptLoader: (_) async => null,
      extrasLoader: (_) async => const AudioExtras(
        tones: AudioToneSet(
          genreType: 1,
          narratorTones: [AudioTone(id: '7239243941252598845', title: '主播：老恒')],
          ttsTones: [AudioTone(id: '96', title: '多角色对话升级版')],
        ),
        detail: BookDetail(
          bookId: 'book',
          title: '测试听书',
          author: BookAuthor(name: '老恒'),
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
