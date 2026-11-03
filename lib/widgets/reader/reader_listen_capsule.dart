import 'package:flutter/material.dart';

import '../../pages/audio_page.dart' show ReaderAudioBridge;

/// Borrows the global player without binding it to the book being read.
class ReaderListenCapsuleHost extends StatelessWidget {
  const ReaderListenCapsuleHost({
    super.key,
    required this.monochrome,
    this.onOpenBook,
  });

  final bool monochrome;

  /// 点封面「回到书页」：菜单本身就长在书页上，收起菜单即可，不再叠层。
  final VoidCallback? onOpenBook;

  @override
  Widget build(BuildContext context) => ReaderAudioBridge.buildMenuPlayer(
    context,
    monochrome: monochrome,
    onOpenBook: onOpenBook,
  );
}

/// 阅读页向菜单里的胶囊开放「换引擎接续」的通道。
///
/// 胶囊三点选完引擎要立即按新引擎把这本书接上，别让用户关掉再重进。其
/// 中「作品音频 → 系统朗读」需要整本正文来构造 [SystemTtsBook]，只有
/// 阅读页拿得出，所以胶囊在菜单里时由阅读页把这个 Inherited 挂在祖先链
/// 上：胶囊经 [ReaderAudioBridge.resumeWithEngine] 查到它，交给阅读页自
/// 己的起播逻辑。阅读页不在场（听书页、全局胶囊）自然查不到，走降级。
class ReaderEngineSwitch extends InheritedWidget {
  const ReaderEngineSwitch({
    super.key,
    required this.bookId,
    required this.onSwitch,
    required super.child,
  });

  /// 接续只认这本书：胶囊挂着别书会话时不抢。
  final String bookId;

  /// 按新偏好从当前页起播；阅读页传 `_openListening(fromPage: true)`。
  final Future<void> Function() onSwitch;

  static ReaderEngineSwitch? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ReaderEngineSwitch>();

  @override
  bool updateShouldNotify(ReaderEngineSwitch oldWidget) =>
      bookId != oldWidget.bookId;
}
