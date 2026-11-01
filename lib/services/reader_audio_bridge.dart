part of '../pages/audio_page.dart';

/// 音色面板的结局，调用方据此决定是否要提示用户。
enum VoicePickerOutcome { changed, dismissed, unavailable, failed }

/// 阅读页听书胶囊 ⇄ 全局听书会话之间的薄桥。
///
/// 只做三件事：复用会话打开听书页、停止播放、原地弹出音色面板。跟随/高亮
/// 仍由阅读页自己的官方路径驱动，这里不碰。
abstract final class ReaderAudioBridge {
  static bool toggle(BuildContext context, String bookId) =>
      AudioPlaybackScope.togglePlayback(context, bookId);

  static bool openPage(BuildContext context, String bookId) =>
      AudioPlaybackScope.openAudioPage(context, bookId);

  static Future<bool> stop(BuildContext context, String bookId) =>
      AudioPlaybackScope.stopPlayback(context, bookId);

  /// 原地弹出音色面板，不离开阅读页。
  ///
  /// 面板顶部带一行提示，切真人讲书还多一道二次确认 —— 那会换掉 `bookId`，
  /// 阅读页的跟随与句高亮会立刻中断，值得挡一下。听书页那条路径
  /// （`_AudioPageState._showVoices`）不传提示、也不走确认，行为保持原样。
  static Future<VoicePickerOutcome> openVoiceSettings(
    BuildContext context,
    String bookId,
  ) async {
    final owner = context.findAncestorStateOfType<_AudioPlaybackScopeState>();
    if (owner == null || !owner.sessionBookMatches(bookId)) {
      return VoicePickerOutcome.unavailable;
    }
    final session = owner._session;
    if (session == null || session._closed || session._switchingVersion) {
      return VoicePickerOutcome.unavailable;
    }

    var tones = session._extras.tones;
    if (tones.ttsTones.isEmpty && tones.narratorTones.isEmpty) {
      // 会话还没取过音色：现拉一次并回填，面板关掉后听书页也不用再拉。
      try {
        await session._publishExtras(session._loadExtrasSafely());
      } catch (_) {
        return VoicePickerOutcome.unavailable;
      }
      tones = session._extras.tones;
      if (session._closed || !context.mounted) {
        return VoicePickerOutcome.dismissed;
      }
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
            // 先等切换完成再关面板：先 pop 会让 showModalBottomSheet 的
            // future 提前返回 changed，_select 的失败就再也传不出去。
            final same = narrator
                ? option.id == session._bookId
                : option.id == session._toneId;
            outcome = same
                ? VoicePickerOutcome.dismissed
                : VoicePickerOutcome.changed;
            if (session._switchingVersion) {
              outcome = VoicePickerOutcome.unavailable;
            } else if (!same) {
              try {
                await _select(session, option, narrator: narrator);
              } catch (_) {
                outcome = VoicePickerOutcome.failed;
              }
            }
            if (sheetContext.mounted) Navigator.maybePop(sheetContext);
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
      if (option.id == session._bookId) return;
      await session._switchBookVersion(
        option.id,
        title: option.title,
        cover: session._cover,
        toneId: '0',
      );
      return;
    }
    if (!session._selectableTone(option.id)) return;
    // 真人讲书的会话按音频书章节记账，智能朗读必须先在原著章节上播；
    // 直接把 TTS 音色发给音频章节会被上游 NO_THIS_TONE 打回并中断播放。
    final novel = session._extras.tones.relatedNovel;
    if (session._ttsBookId != session._bookId && novel != null) {
      await session._switchBookVersion(
        novel.id,
        title: novel.title.isEmpty ? session._title : novel.title,
        cover: novel.cover.isEmpty ? session._cover : novel.cover,
        toneId: option.id,
      );
      return;
    }
    if (option.id == session._toneId) return;
    await session._openChapter(
      session._index,
      position: session._player?.position ?? session._position.value,
      toneId: option.id,
      autoplay: session._wantPlay,
      completed: session._completed,
    );
  }
}
