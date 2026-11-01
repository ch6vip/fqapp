import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart' show AudioPlaybackScope;
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/fakes.dart';

/// 双击跳读的**接线**：三层定位只要被播放器接受，就必须当场点亮目标句。
///
/// 这里不测「该选哪一句」（那是 cue_index_test 的事），只测「跳过去之后屏幕
/// 上到底亮没亮」。tick 最长 1s，若等下一拍才亮，等待期间屏幕还停在上一句，
/// 用户看到的就是「点了这句、亮的是上一句」——这正是要钉死的回归。
///
/// 第 3 层（`/timepoints` 段落锚）依赖服务端时间点与段号，测试环境构造不出
/// 匹配条件，这一层留待真机验证；它和其余两层共用同一个 `_confirmTappedSeek`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ListeningSession.instance.clear();
  });

  tearDown(() {
    AudioPlaybackScope.jumpToChapterOverride = null;
    AudioPlaybackScope.jumpToParagraphOverride = null;
    ListeningSession.instance.clear();
  });

  testWidgets('有字幕时双击立即点亮目标句，不等下一拍', (tester) async {
    await _mount(tester);
    final block = _pager(tester).layout.blocks[1];
    _seed(track: _track(), cue: _body.substring(0, 20));
    await tester.pump();

    var jumped = false;
    AudioPlaybackScope.jumpToChapterOverride = (chapterId, position) {
      jumped = true;
      return true;
    };

    await _doubleTap(tester);

    expect(jumped, isTrue, reason: '双击应触发句级跳转');
    final range = _pager(tester).narrationRange;
    expect(range, isNotNull, reason: '跳转成功后必须立刻有高亮，不能等 tick');
    expect(
      range!.$1 >= block.start && range.$2 <= block.end,
      isTrue,
      reason: '亮起的区间必须落在点中的这一段里，而不是上一段',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('三层都失败时不把上一段的高亮留成目标', (tester) async {
    await _mount(tester);
    _seed(track: SubtitleTrack.empty, cue: null);
    await tester.pump();

    AudioPlaybackScope.jumpToChapterOverride = (chapterId, position) => false;
    AudioPlaybackScope.jumpToParagraphOverride =
        (chapterId, {required paraIndex, required ordinal}) => false;

    await _doubleTap(tester);

    expect(
      _pager(tester).narrationRange,
      isNull,
      reason: '没跳成就不该凭空亮一段（更不该亮上一句）',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final _surface = find.byKey(const ValueKey('reader-page-surface'));

ReaderPagedView _pager(WidgetTester tester) =>
    tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));

/// 一段占满整页的正文：双击页面中心必然落在这段里，不用算分页坐标。
const _body =
    '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗，看见远处的云正慢慢越过山脊。'
    '他想起许多年前也是这样的天气，父亲背着猎枪出门，回来时带着一身露水。'
    '那时候他还不懂什么叫告别，只觉得山里的春天太长，长到可以浪费。';

final _chapters = [Chapter(itemId: 'c1', title: '第一章 山间来信', volumeName: '正文')];

String _text() =>
    '<header><div class="tt-title">第一章 山间来信</div></header><article>'
    '<p idx="0">$_body</p>'
    '</article>';

SubtitleTrack _track() =>
    SubtitleTrack([SubtitleCue(startMs: 0, text: _body), SubtitleCue(startMs: 30000, text: '下一句。')]);

Widget _app() => MaterialApp(
  home: ReaderPage(
    bookId: 'b1',
    title: '山川来信',
    chapters: _chapters,
    startIndex: 0,
    localOnly: true,
    readerStore: MemoryReaderStore(),
    chapterCache: MemoryChapterCache(),
    chapterLoader: (chapter) async => _text(),
    readerDevice: _NullDevice(),
  ),
);

Future<void> _mount(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(320, 480));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

/// 把会话摆成「正在听这本书」，双击才有得跳。
void _seed({required SubtitleTrack track, required String? cue}) {
  ListeningSession.instance.update(
    bookId: 'b1',
    chapterId: 'c1',
    chapterTitle: '第一章 山间来信',
    position: Duration.zero,
    duration: const Duration(seconds: 60),
    playing: true,
    subtitles: track,
    cue: cue,
  );
}

/// 双击正文中心。第一次 tap 的单击回调会被双击识别器推迟，正好用来区分。
Future<void> _doubleTap(WidgetTester tester) async {
  final pos = tester.getRect(_surface).center;
  await tester.tapAt(pos);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tapAt(pos);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
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
