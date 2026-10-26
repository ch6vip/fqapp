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
  const _Host({required this.track, required this.initial, this.onSeek});

  final SubtitleTrack track;
  final int initial;
  final ValueChanged<int>? onSeek;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late int _active = widget.initial;

  void jumpTo(int index) => setState(() => _active = index);

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 420,
        child: AudioSubtitleList(
          track: widget.track,
          active: _active,
          onSeek: widget.onSeek,
        ),
      ),
    ),
  );
}

_HostState _host(WidgetTester tester) =>
    tester.state<_HostState>(find.byType(_Host));

/// 当前句的字重（w600 = 高亮），取不到时抛错。
FontWeight _weightOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!.fontWeight!;

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
}
