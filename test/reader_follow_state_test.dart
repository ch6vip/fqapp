import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/widgets/reader/cue_index.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_controls.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';

/// 听书跟随的状态机：谁负责翻页、拿什么当锚点、什么时候不抢。
///
/// 这几条以前散在两条驱动链上（1Hz 会话通知 + 10Hz 轮询），单看每一段都对，
/// 合起来就出现「每秒回闪一页」「回到开头反而停在章末」。所以用例都按
/// 「同一时刻谁真的改了页面」来断言，而不是断言某个函数的返回值。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    ListeningSession.instance.clear();
    ListeningSession.instance.setFollowArmed(false);
  });

  tearDown(() {
    ListeningSession.instance.clear();
    ListeningSession.instance.setFollowArmed(false);
  });

  testWidgets('会话通知（1Hz）不翻页，页面只跟着 10Hz 轮询走', (tester) async {
    await _mount(tester);
    final layout = _pager(tester).layout;
    ListeningSession.instance.setFollowArmed(true);
    // 位置落在长句的后半段：插值点在后面几页，而句首还在第 0 页。
    _seed(positionMs: 36000, track: _track(), cue: '长句');
    await tester.pump(const Duration(milliseconds: 150));
    final followed = _pager(tester).pageIndex;
    expect(followed, greaterThan(0), reason: '10Hz 跟随应先停在插值点那一页');
    expect(layout.pages.length, greaterThan(followed));

    // 结构性变化 = 一次会话通知（正是每秒来的那一条）。
    _seed(positionMs: 36000, track: _track(), cue: '长句。');
    await tester.pump(const Duration(milliseconds: 20));
    expect(
      _pager(tester).pageIndex,
      followed,
      reason: '1Hz 通知不该把页面拽回句首那一页（那正是每秒回闪的来源）',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('工具条展开时 10Hz 跟随不抢页面', (tester) async {
    await _mount(tester);
    ListeningSession.instance.setFollowArmed(true);
    _seed(positionMs: 0, track: _track(), cue: '长句');
    await tester.pump(const Duration(milliseconds: 150));
    expect(_pager(tester).pageIndex, 0);

    // 点中间展开工具条（单击会被双击识别器推迟到超时之后）。
    await tester.tapAt(tester.getRect(_surface).center);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderControls), findsOneWidget, reason: '工具条应已展开');

    // 播放位置前进到后面几页；工具条还开着，跟随必须让位。
    _seed(positionMs: 36000, track: _track(), cue: '长句');
    await tester.pump(const Duration(milliseconds: 300));
    expect(_pager(tester).pageIndex, 0, reason: '工具条展开时不该翻页（用户正在操作页面）');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('播放位置在首句之前时，不拿残留高亮当导航锚点', (tester) async {
    await _mount(tester);
    final layout = _pager(tester).layout;
    // 真实字幕常常不是从 0 开始（官方 `[3025, 0]`）：位置 0 查不到句。
    final track = _lateStartTrack();
    // 1. 先让页面记下一个「残留高亮」：位置在最后一句，但跟随关着。
    _seed(positionMs: 21000, track: track, cue: '最后一段很短。');
    await tester.pump();
    final held = _pager(tester).narrationRange;
    expect(held, isNotNull, reason: '这一拍应已点亮最后一句');
    final endPage = layout.pageForOffset(held!.$1);
    expect(endPage, greaterThan(0), reason: '末句必须在后面的页，否则验不出回跳');
    expect(_pager(tester).pageIndex, 0);

    // 2. 回到开头：位置 0 归属不到任何一句。
    _seed(positionMs: 0, track: track, cue: '最后一段很短。');
    ListeningSession.instance.setFollowArmed(true);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_pager(tester).pageIndex, 0, reason: '位置在首句之前时不该导航，更不能挪到章末并停在那里');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('官方时间点译不出来时退到字幕兜底', (tester) async {
    await _mount(tester);
    // 多源项章节会重置时间轴：para 号超出本章排版里的段号，译不出区间。
    _seed(
      positionMs: 36000,
      track: _track(),
      cue: '长句',
      audioParaRange: (
        startPara: 9,
        startOff: 0,
        endPara: 9,
        endOff: 5,
        elemIndex: null,
        elemOff: null,
      ),
    );
    await tester.pump();
    final layout = _pager(tester).layout;
    final fallback = CueIndex.build(
      layout: layout,
      track: _track(),
    ).spanAtPositionMs(36000)!;
    expect(_pager(tester).narrationRange, (
      fallback.start,
      fallback.end,
    ), reason: '官方时间点译不出来时应退到字幕兜底，而不是整段没有高亮');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('官方时间点译得出来时仍是唯一来源', (tester) async {
    await _mount(tester);
    final track = _track();
    _seed(
      positionMs: 36000,
      track: track,
      cue: '长句',
      audioParaRange: (
        startPara: 1,
        startOff: 0,
        endPara: 1,
        endOff: 4,
        elemIndex: null,
        elemOff: null,
      ),
    );
    await tester.pump();
    final layout = _pager(tester).layout;
    // 阅读页送给 audioTimePointLayoutRange 的末端是半开区间，所以 +1。
    final official = audioTimePointLayoutRange(layout, 1, 0, 1, 5)!;
    final fallback = CueIndex.build(
      layout: layout,
      track: track,
    ).spanAtPositionMs(36000)!;
    expect(official.start, isNot(fallback.start), reason: '两套来源必须指向不同处');
    expect(_pager(tester).narrationRange, (
      official.start,
      official.end,
    ), reason: '官方区间译得出来时不能被字幕兜底顶掉');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('按「回到朗读处」之后跟随立刻恢复', (tester) async {
    await _mount(tester);
    final layout = _pager(tester).layout;
    _seed(positionMs: 0, track: _track(), cue: '长句');
    // 手动翻一页：闩锁 15 秒 + 退出跟随。
    await _tapSide(tester, 1);
    expect(_pager(tester).pageIndex, 1);

    // 迷你栏的定位键：开跟随 + 跳回朗读处。
    ListeningSession.instance.setFollowArmed(true);
    ListeningSession.instance.jumpToPlaybackHandler!();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_pager(tester).pageIndex, 0, reason: '定位键应把人带回朗读处');

    // 播放位置继续前进，跟随必须马上跟上，而不是等闩锁过期。
    final track = _track();
    _seed(positionMs: 36000, track: track, cue: '长句');
    final span = CueIndex.build(
      layout: layout,
      track: track,
    ).spanAtPositionMs(36000)!;
    final target = layout.pageForOffset(span.spokenOffset(36000));
    expect(target, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_pager(tester).pageIndex, target, reason: '点过定位键就该继续跟随，闩锁不能还挡着');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('被闩锁挡住的跟随换章不再每 100ms 存一次进度', (tester) async {
    final store = ControlledReaderStore();
    await _mount(tester, store: store);
    // 先在第一种里起播，默认跟随把页面带到朗读处。
    _seed(positionMs: 0, track: _track(), cue: '长句');
    await tester.pump(const Duration(milliseconds: 150));
    // 手动翻页制造闩锁（15 秒内不跟随）。
    final rect = tester.getRect(_surface);
    await tester.tapAt(Offset(rect.left + rect.width * .9, rect.center.dy));
    // 挂上双击识别器后，单击要等双击超时才生效，pumpAndSettle 不推进时间。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(_lastBlock(tester), _lastParagraph, reason: '闩锁期间仍留在第 1 章');

    // 播放器已经读完第 1 章进到第 2 章；把跟随开回来（手动翻页后已关掉，
    // 这里不再经过「起播」那条自动路径，闩锁不会因此被清）。
    _seed(positionMs: 5000, chapterId: 'c2', track: _track(), cue: '长句');
    ListeningSession.instance.setFollowArmed(true);
    expect(ListeningSession.instance.followArmed, isTrue);
    await tester.pump(const Duration(milliseconds: 600)); // 等防抖存盘落完
    final before = store.writes.length;

    await tester.pump(const Duration(milliseconds: 1000));
    expect(store.writes.length, before, reason: '闩锁期间的换章请求一次都不该落地，更不该每秒存十次进度');
    expect(
      _lastBlock(tester),
      _lastParagraph,
      reason: '闩锁期间本来就该留在原章（所以每次请求都是纯浪费）',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('「下一章」之后不会再被拽回正在播的那一章', (tester) async {
    await _mount(tester);
    _seed(positionMs: 5000, track: _track(), cue: '长句');
    ListeningSession.instance.setFollowArmed(true);
    await tester.pump(const Duration(milliseconds: 150));

    // 打开工具条 → 展开「设置」里的章节行 → 点「下一章」→ 收起工具条。
    await tester.tapAt(tester.getRect(_surface).center);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一章'));
    await tester.pumpAndSettle();
    expect(_lastBlock(tester), _sentence, reason: '应已切到第二章');
    // 收起工具条：底部面板盖住了半屏，得点上方那块正文才有反应。
    final rect = tester.getRect(_surface);
    await tester.tapAt(Offset(rect.center.dx, rect.top + 150));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      find.byType(ReaderControls),
      findsNothing,
      reason: '工具条还开着的话跟随本来就被挡，验不出「主动换章」这条',
    );

    await tester.pump(const Duration(milliseconds: 300));
    expect(
      _lastBlock(tester),
      _sentence,
      reason: '主动换章要退出跟随，否则轮询 100ms 后又跳回正在播的上一章',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('暂停的会话打开阅读页，双击跳读立刻可用', (tester) async {
    // 开书前就已经暂停：之后不会再有会话通知。
    _seed(positionMs: 0, track: _track(), cue: '长句', playing: false);
    await _mount(tester);
    final surface = tester.widget<GestureDetector>(_surface);
    expect(
      surface.onDoubleTapDown,
      isNotNull,
      reason: '暂停的会话也要先挂上双击跳读，不能等下一次播放事件',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final _surface = find.byKey(const ValueKey('reader-page-surface'));

ReaderPagedView _pager(WidgetTester tester) =>
    tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));

/// 两章的末段文本不同，用来判断现在停在哪一章（`ReaderChapterLayout` 不带
/// 章节标题，只有正文块）。
String _lastBlock(WidgetTester tester) =>
    _pager(tester).layout.blocks.last.text;

/// 一句占满整段的长文：字幕一句跨十几页，句首与「正在读的字」不在同一页。
const _sentence = '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗，看见远处的云正慢慢越过山脊。';

String _longParagraph() => List.generate(40, (_) => _sentence).join();

const _lastParagraph = '最后一段很短。';

SubtitleTrack _track() => SubtitleTrack([
  SubtitleCue(startMs: 0, text: _longParagraph().substring(0, 1200)),
  SubtitleCue(startMs: 40000, text: _lastParagraph),
]);

/// 真机字幕常常不是从 0 开始（官方 `[3025, 0]`）。
SubtitleTrack _lateStartTrack() => SubtitleTrack([
  SubtitleCue(startMs: 3025, text: _longParagraph().substring(0, 1200)),
  SubtitleCue(startMs: 20000, text: _lastParagraph),
]);

final _chapters = [
  Chapter(itemId: 'c1', title: '第一章 山间来信', volumeName: '正文'),
  Chapter(itemId: 'c2', title: '第二章 远山', volumeName: '正文'),
];

/// 走 `toCacheText()`：只有结构化缓存才带 `idx`，官方时间点（按段号寻址）
/// 才有得译；纯文本段落没有段号。
String _text(Chapter chapter) {
  return parseChapterContent(_markup(chapter)).toCacheText();
}

String _markup(Chapter chapter) {
  if (chapter.itemId == 'c2') {
    return '<header><div class="tt-title">${chapter.title}</div></header><article>'
        '${List.generate(6, (i) => '<p idx="$i">$_sentence</p>').join()}'
        '</article>';
  }
  return '<header><div class="tt-title">${chapter.title}</div></header><article>'
      '<p idx="0">${_longParagraph()}</p>'
      '<p idx="1">$_lastParagraph</p>'
      '</article>';
}

Widget _app({ReaderStore? store}) => MaterialApp(
  home: ReaderPage(
    bookId: 'b1',
    title: '山川来信',
    chapters: _chapters,
    startIndex: 0,
    localOnly: true,
    readerStore: store ?? MemoryReaderStore(),
    chapterCache: MemoryChapterCache(),
    chapterLoader: (chapter) async => _text(chapter),
    readerDevice: _NullDevice(),
  ),
);

Future<void> _mount(WidgetTester tester, {ReaderStore? store}) async {
  await tester.binding.setSurfaceSize(const Size(320, 480));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(store: store));
  await tester.pumpAndSettle();
}

Future<void> _tapSide(WidgetTester tester, int direction) async {
  final rect = tester.getRect(_surface);
  await tester.tapAt(
    Offset(rect.left + rect.width * (direction > 0 ? .9 : .1), rect.center.dy),
  );
  await tester.pumpAndSettle();
}

/// 直接把会话摆成某个状态（播放器那边写入的等价物）。
void _seed({
  required int positionMs,
  required SubtitleTrack track,
  required String cue,
  String chapterId = 'c1',
  bool playing = true,
  ({
    int startPara,
    int startOff,
    int endPara,
    int endOff,
    int? elemIndex,
    int? elemOff,
  })?
  audioParaRange,
}) {
  ListeningSession.instance.update(
    bookId: 'b1',
    chapterId: chapterId,
    chapterTitle: '第一章 山间来信',
    position: Duration(milliseconds: positionMs),
    duration: const Duration(seconds: 60),
    playing: playing,
    subtitles: track,
    cue: cue,
    audioParaRange: audioParaRange,
  );
}

class _NullDevice extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(
    time: DateTime(2026, 9, 10, 21, 16),
    battery: 64,
    systemBrightness: .45,
  );
  @override
  Future<void> suspend() async {}
  @override
  Future<void> close() async {}
}
