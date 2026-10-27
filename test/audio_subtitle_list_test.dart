import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/widgets/audio/audio_sections.dart';

/// 60 句，每句 2 秒 —— 一屏放不下，才有「要不要跟随」可言。
SubtitleTrack _track([int count = 60]) => SubtitleTrack([
  for (var i = 0; i < count; i++)
    SubtitleCue(startMs: i * 2000, text: '第 $i 句字幕'),
]);

/// 受控宿主：`active` 由外部改，用来模拟「朗读念到下一句」。
class _Host extends StatefulWidget {
  const _Host({
    required this.track,
    required this.initial,
    this.onSeek,
    this.disableAnimations = false,
  });

  final SubtitleTrack track;
  final int initial;
  final ValueChanged<int>? onSeek;
  final bool disableAnimations;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late int _active = widget.initial;

  void jumpTo(int index) => setState(() => _active = index);

  @override
  Widget build(BuildContext context) {
    Widget child = AudioSubtitleList(
      track: widget.track,
      active: _active,
      onSeek: widget.onSeek,
    );
    if (widget.disableAnimations) {
      child = MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child,
      );
    }
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(height: 420, child: child),
      ),
    );
  }
}

_HostState _host(WidgetTester tester) =>
    tester.state<_HostState>(find.byType(_Host));

/// 当前句的字重（w600 = 高亮），取不到时抛错。
FontWeight _weightOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!.fontWeight!;

Finder _row(int index) => find.byKey(ValueKey('audio_subtitle_row_$index'));

double _offset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('audio_subtitle_list')),
        matching: find.byType(Scrollable),
      ),
    )
    .position
    .pixels;

Rect _listRect(WidgetTester tester) =>
    tester.getRect(find.byKey(const Key('audio_subtitle_list')));

/// 某一行（`Ink` 那一层，整行的高度）相对列表视口的位置：0 = 贴着顶，
/// 1 = 贴着底。定位对不对看这个，不看「列表动没动」。
double _rowFraction(WidgetTester tester, int index) {
  final list = _listRect(tester);
  final row = tester.getRect(
    find.ancestor(of: _row(index), matching: find.byType(Ink)).first,
  );
  return (row.top - list.top) / (list.height - row.height);
}

void main() {
  testWidgets('当前句高亮，其余句是普通字重', (tester) async {
    await tester.pumpWidget(_Host(track: _track(), initial: 0));
    await tester.pumpAndSettle();

    expect(_weightOf(tester, '第 0 句字幕'), FontWeight.w600);
    expect(_weightOf(tester, '第 1 句字幕'), FontWeight.w400);

    // 换一句：高亮跟着走，上一句退回普通字重。
    _host(tester).jumpTo(1);
    await tester.pumpAndSettle();
    expect(_weightOf(tester, '第 1 句字幕'), FontWeight.w600);
    expect(_weightOf(tester, '第 0 句字幕'), FontWeight.w400);
  });

  testWidgets('换到远处的一句时列表自动滚过去', (tester) async {
    await tester.pumpWidget(_Host(track: _track(), initial: 0));
    await tester.pumpAndSettle();
    expect(find.text('第 0 句字幕'), findsOneWidget);
    // 目标句一开始连构建都没有（ListView.builder 只建可视区）。
    expect(find.text('第 45 句字幕'), findsNothing);

    _host(tester).jumpTo(45);
    await tester.pumpAndSettle();

    // 跟上来了：目标句在树上，开头那句已经被回收。
    expect(find.text('第 45 句字幕'), findsOneWidget);
    expect(find.text('第 0 句字幕'), findsNothing);
  });

  testWidgets('当前句停在视口约三分之一处', (tester) async {
    await tester.pumpWidget(_Host(track: _track(), initial: 0));
    await tester.pumpAndSettle();
    expect(_offset(tester), 0);

    _host(tester).jumpTo(30);
    await tester.pumpAndSettle();

    // 不是「滚了一下」：行顶落在 (视口 - 行高) 的 32%，下一句都还看得见。
    expect(_rowFraction(tester, 30), closeTo(0.32, 0.02));
    // 落点是精确对位算出来的，不是比例落点留下的近似值。
    final list = _listRect(tester);
    final row = tester.getRect(
      find.ancestor(of: _row(30), matching: find.byType(Ink)).first,
    );
    expect(
      _offset(tester),
      closeTo(30 * row.height - 0.32 * (list.height - row.height), 1),
    );
  });

  testWidgets('打开时已经念到中段，先落位而不是停在开头', (tester) async {
    await tester.pumpWidget(_Host(track: _track(), initial: 40));
    await tester.pumpAndSettle();

    expect(find.text('第 40 句字幕'), findsOneWidget);
    expect(find.text('第 0 句字幕'), findsNothing);
  });

  testWidgets('点某一句把它的起始毫秒交出去', (tester) async {
    final seeks = <int>[];
    await tester.pumpWidget(
      _Host(track: _track(), initial: 0, onSeek: seeks.add),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('第 2 句字幕'));
    await tester.pumpAndSettle();
    expect(seeks, [4000]);
  });

  testWidgets('没有进度时不响应点击', (tester) async {
    await tester.pumpWidget(
      _Host(track: _track(), initial: 0, onSeek: null),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('第 2 句字幕'));
    await tester.pumpAndSettle();
    // 只是确认点下去不抛异常；onSeek 为 null 时 ListTile 的 onTap 也是 null。
    expect(find.text('第 2 句字幕'), findsOneWidget);
  });

  testWidgets('高亮画在列表自己的 Material 里', (tester) async {
    await tester.pumpWidget(_Host(track: _track(), initial: 2));
    await tester.pumpAndSettle();

    // `Ink` 往最近的 Material 登记图案，而 Material 只按自己的尺寸裁：贴着
    // 页面那层 Material（整页大）时，半滚出视口的那一行会画到 TabBar 上去。
    final material = tester.widget<Material>(
      find.ancestor(of: _row(2), matching: find.byType(Material)).first,
    );
    expect(material.type, MaterialType.transparency);
  });

  testWidgets('鼠标滚轮滚过之后 4 秒内不抢方向盘，暂停结束补跳一次', (tester) async {
    await tester.pumpWidget(_Host(track: _track(), initial: 10));
    await tester.pumpAndSettle();
    final settled = _offset(tester);

    // 滚轮/触控板走 `pointerScroll`：它有 `UserScrollNotification`，但
    // `ScrollStartNotification` 里没有 `dragDetails`。
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byKey(const Key('audio_subtitle_list'))),
        scrollDelta: const Offset(0, -120),
      ),
    );
    await tester.pump();
    final userScrolled = _offset(tester);
    expect(userScrolled, lessThan(settled - 100));

    // 暂停窗口内换句：不许把用户拽回去，但这一句不能丢。
    _host(tester).jumpTo(40);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_offset(tester), closeTo(userScrolled, 0.5));
    expect(_row(40), findsNothing);

    // 4 秒过去：暂停失效，被推迟的那一句补上。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(_row(40), findsOneWidget);
    expect(_offset(tester), greaterThan(userScrolled + 100));
    expect(_rowFraction(tester, 40), closeTo(0.32, 0.05));
  });

  testWidgets('跳得很远、行高又不齐时也会落到目标句上', (tester) async {
    // 窄屏让后面的句子折行，行高 48↔72 不等：`maxScrollExtent` 是按已构建
    // 行外推的，比例落点会差出好几屏，一次纠正够不着。
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final track = SubtitleTrack([
      for (var i = 0; i < 60; i++)
        SubtitleCue(
          startMs: i * 2000,
          text: i < 10
              ? '第 $i 句'
              : '第 $i 句：这一句长一些，窄屏上要折行，行高不再是 48 像素，再补一点让它更长一些',
        ),
    ]);
    await tester.pumpWidget(_Host(track: track, initial: 0));
    await tester.pumpAndSettle();

    _host(tester).jumpTo(55);
    await tester.pumpAndSettle();

    expect(_row(55), findsOneWidget);
    final list = _listRect(tester);
    final row = tester.getRect(
      find.ancestor(of: _row(55), matching: find.byType(Ink)).first,
    );
    expect(row.top, greaterThanOrEqualTo(list.top));
    expect(row.bottom, lessThanOrEqualTo(list.bottom));
  });

  testWidgets('关掉动画时一步到位', (tester) async {
    await tester.pumpWidget(
      _Host(track: _track(), initial: 0, disableAnimations: true),
    );
    await tester.pumpAndSettle();

    _host(tester).jumpTo(3);
    await tester.pump(); // 帧后回调在这里跑
    await tester.pump(); // 新偏移量布局
    final landed = _offset(tester);
    expect(landed, greaterThan(0));

    // 有动画时这一刻大约走了 100/220，还得再跑几帧；关掉动画已经到终点。
    await tester.pump(const Duration(milliseconds: 100));
    expect(_offset(tester), landed);
    expect(_rowFraction(tester, 3), closeTo(0.32, 0.02));
  });
}
