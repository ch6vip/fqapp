part of '../pages/audio_page.dart';

/// 测试缝的函数形状：拦截后台起播。
typedef BackgroundStartHandler =
    Future<bool> Function(BuildContext context, AudioPage request);

/// 测试缝的函数形状：拦截段落锚点跳转。
typedef ParagraphJumpHandler =
    bool Function(
      String chapterId, {
      required int? paraIndex,
      required int ordinal,
    });

/// 测试缝的函数形状：拦截句级/段首毫秒跳转。
typedef ChapterJumpHandler = bool Function(String chapterId, Duration position);

/// Reader playback requests and the menu's borrowed global player.
abstract final class ReaderAudioBridge {
  /// Live sessions include paused/loading playback, but not an idle history card.
  static Widget buildMenuForBook(
    BuildContext context, {
    required String bookId,
    required Widget Function(BuildContext context, bool currentBook) builder,
  }) {
    final owner = _owner(context);
    if (owner == null) return builder(context, false);
    return ListenableBuilder(
      listenable: owner._tick,
      builder: (context, _) {
        final tts = owner._tts;
        final currentBook =
            owner._sessionBookMatches(bookId) ||
            (tts != null && !tts.closed && tts.book.bookId == bookId);
        return builder(context, currentBook);
      },
    );
  }

  static Widget buildMenuPlayer(
    BuildContext context, {
    required bool monochrome,
  }) =>
      _owner(
        context,
      )?._buildCapsule(context, inReaderMenu: true, monochrome: monochrome) ??
      const SizedBox.shrink();

  static _AudioPlaybackScopeState? _owner(BuildContext context) =>
      context.findAncestorStateOfType<_AudioPlaybackScopeState>();

  /// 在后台起播，不打开听书页（阅读页「从本页听」用它）。
  ///
  /// 会话由 scope 持有、页面只是视图，所以不挂载页面也能播；阅读页留在
  /// 原处继续跟随与高亮。返回值只表示是否接收请求；实际加载、播放与错误
  /// 由会话发布，创建控制器不代表已经出声。
  static Future<bool> startListeningInBackground(
    BuildContext context,
    AudioPage request,
  ) async {
    final override = AudioPlaybackScope.startListeningOverride;
    if (override != null) return override(context, request);
    final owner = _owner(context);
    if (owner == null) return false;
    return await owner.acquire(request) != null;
  }

  /// 段落锚点跳转（双击跳读用）：与「从本页播放」同一套寻址。
  static bool jumpToParagraph(
    BuildContext context,
    String chapterId, {
    required int? paraIndex,
    required int ordinal,
  }) {
    final override = AudioPlaybackScope.jumpToParagraphOverride;
    if (override != null) {
      return override(chapterId, paraIndex: paraIndex, ordinal: ordinal);
    }
    final owner = _owner(context);
    if (owner == null) return false;
    return _jumpToParagraphFor(
      owner,
      chapterId,
      paraIndex: paraIndex,
      ordinal: ordinal,
    );
  }

  /// 见 [AudioPlaybackScope.jumpToChapter]。
  static bool jumpToChapter(
    BuildContext context,
    String chapterId,
    Duration position,
  ) {
    final override = AudioPlaybackScope.jumpToChapterOverride;
    if (override != null) return override(chapterId, position);
    final owner = _owner(context);
    return owner?.jumpToChapter(chapterId, position) ?? false;
  }

  /// 段落锚点交给播放器的 `/timepoints` 解析，不依赖字幕轨 —— 跨页/跨章
  /// 时手里的字幕轨对不上本章正文，这条才是可靠的寻址路径。
  static bool _jumpToParagraphFor(
    _AudioPlaybackScopeState owner,
    String chapterId, {
    required int? paraIndex,
    required int ordinal,
  }) {
    final session = owner._session;
    if (session == null || session._closed) return false;
    // 阅读页传的是原著章节 id 时要先映射回音频集；映射不到宁可不跳。
    final audioChapterId = owner._audioChapterIdFor(chapterId);
    if (audioChapterId == null) return false;
    final index = session._chapters.indexWhere(
      (c) => c.itemId == audioChapterId,
    );
    if (index < 0) return false;
    unawaited(
      session._openChapter(
        index,
        paragraph: (paraIndex: paraIndex, ordinal: ordinal),
      ),
    );
    return true;
  }
}
