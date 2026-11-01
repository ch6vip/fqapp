part of '../pages/audio_page.dart';

/// 音色面板的结局，调用方据此决定是否要提示用户。
enum VoicePickerOutcome { changed, dismissed, unavailable, failed }

/// 测试缝的函数形状（单独命名，避免在字段声明处把参数拆成好几行）。
typedef VoiceSettingsHandler =
    Future<VoicePickerOutcome> Function(BuildContext context, String bookId);

/// 测试缝的函数形状：拦截停止播放。
typedef StopPlaybackHandler =
    Future<bool> Function(BuildContext context, String bookId);

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

/// 阅读页听书胶囊 ⇄ 全局听书会话之间的桥。
///
/// 为什么单独一个文件：`audio_playback_controller.dart` 已顶到行数预算上限、
/// `audio_playback_scope.dart` 距 500 行红线只剩几行，两者都动不得。这里作为
/// `audio_page.dart` 的 part，既能碰私有成员，又自成一份行数预算。
///
/// 音色数据与切换动作本来就在控制器上（`_extras.tones` / `_uniqueTones` /
/// `_selectableTone` / `_switchBookVersion` / `_openChapter`），所以这里只复刻
/// 听书页那两个「拼参数 + 关面板」的薄壳，不做下沉。
abstract final class ReaderAudioBridge {
  /// 测试缝：拦截停止播放，避免测试真的挂播放器。
  @visibleForTesting
  static StopPlaybackHandler? stopOverride;

  /// 测试缝：拦截音色面板。
  @visibleForTesting
  static VoiceSettingsHandler? voiceSettingsOverride;

  static _AudioPlaybackScopeState? _owner(BuildContext context) =>
      context.findAncestorStateOfType<_AudioPlaybackScopeState>();

  /// 正在听这本书的音频会话（系统朗读不算）。
  ///
  /// 走 scope 的 [_AudioPlaybackScopeState._sessionBookMatches]：真人讲书的
  /// 「边听边读」打开原著时，阅读页传的是原著 id，会话记的是音频书 id。
  static bool _audioMatches(_AudioPlaybackScopeState owner, String bookId) =>
      owner._sessionBookMatches(bookId);

  static bool _ttsMatches(_AudioPlaybackScopeState owner, String bookId) {
    final tts = owner._tts;
    return tts != null && !tts.closed && tts.book.bookId == bookId;
  }

  /// 在后台起播，不打开听书页（阅读页「从本页听」用它）。
  ///
  /// 会话由 scope 持有、页面只是视图，所以不挂载页面也能播；阅读页留在
  /// 原处继续跟随与高亮。返回 false 表示入口不支持或起播失败。
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

  /// 播放 / 暂停。
  static bool toggle(BuildContext context, String bookId) =>
      AudioPlaybackScope.togglePlayback(context, bookId);

  /// 停止播放：音频会话与系统朗读各走各的关闭路径。
  static Future<bool> stop(BuildContext context, String bookId) async {
    final override = stopOverride;
    if (override != null) return override(context, bookId);
    final owner = _owner(context);
    if (owner == null) return false;
    if (_audioMatches(owner, bookId)) {
      await owner.stop(owner._session!);
      return true;
    }
    if (_ttsMatches(owner, bookId)) {
      await owner.stopTts(owner._tts!);
      return true;
    }
    return false;
  }

  /// 打开听书页（点封面）。
  static void openPage(BuildContext context, String bookId) {
    final owner = _owner(context);
    if (owner == null || !_audioMatches(owner, bookId)) return;
    owner._openAudio(owner._session!);
  }

  /// 原地弹出音色面板。
  ///
  /// 面板顶部带一行提示，切真人讲书还多一道二次确认 —— 那会换掉 `bookId`，
  /// 阅读页的跟随与句高亮会立刻中断，值得挡一下。听书页那条路径
  /// （`_AudioPageState._showVoices`）不传提示、也不走确认，行为保持原样。
  static Future<VoicePickerOutcome> openVoiceSettings(
    BuildContext context,
    String bookId,
  ) async {
    final override = voiceSettingsOverride;
    if (override != null) return override(context, bookId);
    final owner = _owner(context);
    if (owner == null || !_audioMatches(owner, bookId)) {
      return VoicePickerOutcome.unavailable;
    }
    final session = owner._session!;

    var tones = session._extras.tones;
    if (tones.ttsTones.isEmpty && tones.narratorTones.isEmpty) {
      // 会话还没取过音色：现拉一次并回填，面板关掉后听书页也不用再拉。
      await session._publishExtras(session._loadExtras());
      tones = session._extras.tones;
      if (tones.ttsTones.isEmpty && tones.narratorTones.isEmpty) {
        return VoicePickerOutcome.unavailable;
      }
    }
    if (!context.mounted) return VoicePickerOutcome.dismissed;

    final narrators = <VoiceOption>[
      for (final tone in session._uniqueTones(tones.narratorTones))
        VoiceOption(
          id: tone.id,
          title: tone.title,
          description: tone.description,
          badge: tone.badge,
        ),
    ];
    final online = <VoiceOption>[];
    final seen = <String>{};
    for (final tone in session._uniqueTones(session._ttsTones)) {
      if (session._selectableTone(tone.id) && seen.add(tone.id)) {
        online.add(
          VoiceOption(
            id: tone.id,
            title: tone.title,
            description: tone.description,
            badge: tone.badge,
            isMultiTone: tone.isMultiTone,
          ),
        );
      }
    }
    if (online.isEmpty) {
      for (final voice in session._voices) {
        if (!session._selectableTone(voice.id) || !seen.add(voice.id)) continue;
        online.add(VoiceOption(id: voice.id, title: voice.label));
      }
    }

    var outcome = VoicePickerOutcome.dismissed;
    final narratorIds = {for (final option in narrators) option.id};
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.72,
        child: VoiceSettingsSheet(
          selectedId: tones.hasFixedTone ? session._bookId : session._toneId,
          narrators: narrators,
          online: online,
          notice: narrators.isEmpty && tones.relatedNovel == null
              ? null
              : '真人讲书是另一本书的音频，切换后本页会停止跟随；'
                    '可点胶囊「听」从本页重新开始。',
          onSelect: (option) async {
            final narrator = narratorIds.contains(option.id);
            if (narrator) {
              final confirmed = await showDialog<bool>(
                context: sheetContext,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('切换真人讲书？'),
                  content: const Text('这是另一本书的音频，切换后本页会停止跟随，需要重新点「听」才能继续。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      key: const Key('reader-voice-narrator-confirm'),
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('切换'),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
            }
            if (sheetContext.mounted) Navigator.maybePop(sheetContext);
            outcome = VoicePickerOutcome.changed;
            try {
              await _select(session, option, narrator: narrator);
            } catch (_) {
              outcome = VoicePickerOutcome.failed;
            }
          },
        ),
      ),
    );
    return outcome;
  }

  static Future<void> _select(
    _AudioPlaybackController session,
    VoiceOption option, {
    required bool narrator,
  }) async {
    if (narrator) {
      await session._switchBookVersion(
        option.id,
        title: option.title,
        cover: session._cover,
        toneId: '0',
      );
      return;
    }
    await session._openChapter(
      session._index,
      position: session._player?.position ?? session._position.value,
      toneId: option.id,
      autoplay: session._wantPlay,
      completed: session._completed,
    );
  }
}
