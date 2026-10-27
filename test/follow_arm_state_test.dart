import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/listening_session.dart';

/// 跟随开关现在要靠通知驱动迷你栏图标（实心 + 主色 / 空心）。
///
/// 阅读页手动翻页会主动退出跟随，所以「退出」也必须走同一条通知，否则按钮
/// 会一直显示「跟随中」—— 用户看到的就是「点了没反应」。
void main() {
  test('跟随开关变化会广播，重复设同值不重复通知', () {
    final session = ListeningSession.instance;
    session.setFollowArmed(false);
    var hits = 0;
    void listener() => hits++;
    session.addListener(listener);
    addTearDown(() {
      session.removeListener(listener);
      session.setFollowArmed(false);
    });

    session.setFollowArmed(true);
    expect(session.followArmed, isTrue);
    expect(hits, 1, reason: '开跟随要通知一次，图标才会变色');

    session.setFollowArmed(true);
    expect(hits, 1, reason: '同值不重复通知');

    session.setFollowArmed(false);
    expect(session.followArmed, isFalse);
    expect(hits, 2, reason: '退出跟随（例如手动翻页）也要通知');
  });
}
