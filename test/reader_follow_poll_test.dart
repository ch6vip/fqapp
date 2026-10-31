import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/reader_follow_poll.dart';

void main() {
  testWidgets('polls only while a session needs it', (tester) async {
    var ticks = 0;
    var needed = false;
    final poll = ReaderFollowPoll(() => ticks++, () => needed);

    poll.sync();
    await tester.pump(const Duration(seconds: 1));
    expect(ticks, 0, reason: '没有听书会话时不该每 100ms 唤醒一次');

    needed = true;
    poll.sync();
    await tester.pump(const Duration(milliseconds: 350));
    expect(ticks, greaterThanOrEqualTo(3));

    needed = false;
    poll.sync();
    final stopped = ticks;
    await tester.pump(const Duration(seconds: 1));
    expect(ticks, stopped, reason: '会话结束或退到后台后应停止计时');
    poll.dispose();
  });

  testWidgets('offers a periodic save every 20 followed ticks', (tester) async {
    final poll = ReaderFollowPoll(() {}, () => true);
    poll.sync();
    var dues = 0;
    for (var i = 0; i < 60; i++) {
      if (poll.saveDue()) dues++;
    }
    expect(dues, 3);
    poll.dispose();
  });
}
