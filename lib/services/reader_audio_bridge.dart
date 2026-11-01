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

/// Result of the reader's in-place voice picker.
enum VoicePickerOutcome { changed, dismissed, unavailable, failed }

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
    try {
      return await owner.acquire(request) != null;
    } catch (_) {
      // A rejected request must use the same boolean contract as a missing scope.
      return false;
    }
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

  /// Opens the voice picker over the reader without leaving the book.
  ///
  /// The reading page follows the audio session, so switching to a narrator
  /// (another book's recording) needs a warning and confirmation. Unlike the
  /// listening page's picker, this panel also states that consequence up front.
  static Future<VoicePickerOutcome> openVoiceSettings(
    BuildContext context,
    String bookId,
  ) async {
    final owner = _owner(context);
    final session = owner?._session;
    if (owner == null ||
        session == null ||
        session._closed ||
        !owner._sessionBookMatches(bookId)) {
      return VoicePickerOutcome.unavailable;
    }
    if (session._switchingVersion) return VoicePickerOutcome.unavailable;
    if (owner._readerVoicePickerOpen) return VoicePickerOutcome.dismissed;

    owner._readerVoicePickerOpen = true;
    owner._changed();
    try {
      final readerRoute = ModalRoute.of(context);
      final sessionBookId = session._bookId;
      final settingsGeneration = session._settingsGeneration;
      var tones = session._extras.tones;
      if (tones.ttsTones.isEmpty && tones.narratorTones.isEmpty) {
        await session._publishExtras(
          session._loadExtrasSafely(),
          settingsGeneration,
        );
        if (!context.mounted ||
            !_readerVoiceSourceCurrent(
              owner,
              session,
              readerRoute: readerRoute,
              bookId: sessionBookId,
              settingsGeneration: settingsGeneration,
            )) {
          return VoicePickerOutcome.dismissed;
        }
        tones = session._extras.tones;
      }

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
          if (!session._selectableTone(voice.id) || !seen.add(voice.id)) {
            continue;
          }
          online.add(VoiceOption(id: voice.id, title: voice.label));
        }
      }
      if (narrators.isEmpty && online.isEmpty) {
        return VoicePickerOutcome.unavailable;
      }
      if (!context.mounted ||
          !_readerVoiceSourceCurrent(
            owner,
            session,
            readerRoute: readerRoute,
            bookId: sessionBookId,
            settingsGeneration: settingsGeneration,
          )) {
        return VoicePickerOutcome.dismissed;
      }

      var outcome = VoicePickerOutcome.dismissed;
      var selecting = false;
      Future<void>? selectionTask;
      final narratorIds = {for (final option in narrators) option.id};
      try {
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (sheetContext) => StatefulBuilder(
            builder: (sheetContext, setSheetState) {
              final sheetRoute = ModalRoute.of(sheetContext);
              final staticLoading =
                  HomePalette.of(sheetContext).eink ||
                  MediaQuery.disableAnimationsOf(sheetContext) ||
                  MediaQuery.accessibleNavigationOf(sheetContext);
              bool sheetIsCurrent() =>
                  sheetContext.mounted &&
                  sheetRoute != null &&
                  sheetRoute.isCurrent;

              void closeSheet() {
                if (!sheetContext.mounted) return;
                final route = ModalRoute.of(sheetContext);
                if (route == null || route.isCurrent) {
                  Navigator.maybePop(sheetContext);
                }
              }

              void setSelecting(bool value) {
                selecting = value;
                if (sheetContext.mounted) {
                  setSheetState(() {});
                }
              }

              return SizedBox(
                height: MediaQuery.sizeOf(sheetContext).height * 0.72,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AbsorbPointer(
                      absorbing: selecting,
                      child: VoiceSettingsSheet(
                        selectedId: tones.hasFixedTone
                            ? session._bookId
                            : session._toneId,
                        narrators: narrators,
                        online: online,
                        notice: narrators.isEmpty && tones.relatedNovel == null
                            ? null
                            : '真人讲书是另一本书的音频，切换后本页会停止跟随；'
                                  '可在设置 → 更多设置 → 听书方式中从本页重新开始。',
                        onSelect: (option) {
                          if (selecting) return;
                          if (!_readerVoiceSessionCurrent(
                            owner,
                            session,
                            bookId: sessionBookId,
                            settingsGeneration: settingsGeneration,
                          )) {
                            outcome = VoicePickerOutcome.unavailable;
                            closeSheet();
                            return;
                          }
                          final narrator = narratorIds.contains(option.id);
                          final same = narrator
                              ? option.id == session._bookId
                              : option.id == session._toneId;
                          if (same) {
                            outcome = VoicePickerOutcome.dismissed;
                            closeSheet();
                            return;
                          }
                          if (session._switchingVersion) {
                            outcome = VoicePickerOutcome.unavailable;
                            closeSheet();
                            return;
                          }

                          setSelecting(true);
                          final task = () async {
                            var closeAfterSelection = false;
                            try {
                              if (!sheetIsCurrent()) {
                                outcome = VoicePickerOutcome.dismissed;
                                return;
                              }
                              if (narrator) {
                                final confirmed = await showDialog<bool>(
                                  context: sheetContext,
                                  builder: (dialogContext) => AlertDialog(
                                    title: const Text('切换真人讲书？'),
                                    content: const Text(
                                      '这是另一本书的音频，切换后本页会停止跟随，'
                                      '可在设置 → 更多设置 → 听书方式中从本页重新开始。',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(dialogContext, false),
                                        child: const Text('取消'),
                                      ),
                                      FilledButton(
                                        key: const Key(
                                          'reader-voice-narrator-confirm',
                                        ),
                                        onPressed: () =>
                                            Navigator.pop(dialogContext, true),
                                        child: const Text('切换'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed != true) return;
                                if (!sheetIsCurrent() ||
                                    !_readerVoiceSessionCurrent(
                                      owner,
                                      session,
                                      bookId: sessionBookId,
                                      settingsGeneration: settingsGeneration,
                                    )) {
                                  outcome = VoicePickerOutcome.unavailable;
                                  closeAfterSelection = true;
                                  return;
                                }
                              }
                              if (!sheetIsCurrent()) {
                                outcome = VoicePickerOutcome.dismissed;
                                return;
                              }
                              if (session._switchingVersion) {
                                outcome = VoicePickerOutcome.unavailable;
                                closeAfterSelection = true;
                                return;
                              }
                              final targetBookId = _voiceTargetBookId(
                                session,
                                option,
                                narrator: narrator,
                              );
                              if (targetBookId == null) {
                                outcome = VoicePickerOutcome.failed;
                                closeAfterSelection = true;
                                return;
                              }
                              closeAfterSelection = true;
                              final requestGeneration = await _selectVoice(
                                session,
                                option,
                                narrator: narrator,
                                targetBookId: targetBookId,
                              );
                              final succeeded = _voiceSelectionSucceeded(
                                owner,
                                session,
                                bookId: targetBookId,
                                toneId: narrator ? null : option.id,
                                requestGeneration: requestGeneration,
                              );
                              outcome = succeeded
                                  ? VoicePickerOutcome.changed
                                  : VoicePickerOutcome.failed;
                              if (succeeded &&
                                  narrator &&
                                  targetBookId != sessionBookId) {
                                ListeningSession.instance.setFollowArmed(false);
                              }
                            } catch (_) {
                              outcome = VoicePickerOutcome.failed;
                              closeAfterSelection = true;
                            } finally {
                              setSelecting(false);
                              if (closeAfterSelection) closeSheet();
                            }
                          }();
                          selectionTask = task;
                          unawaited(task);
                        },
                      ),
                    ),
                    if (selecting)
                      Positioned.fill(
                        child: AbsorbPointer(
                          child: ColoredBox(
                            color: const Color(0x14000000),
                            child: Center(
                              child: SizedBox.square(
                                dimension: 24,
                                child: staticLoading
                                    ? Icon(
                                        Icons.hourglass_empty,
                                        size: 20,
                                        color: HomePalette.of(sheetContext).ink,
                                      )
                                    : const CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        );
        final pendingSelection = selectionTask;
        if (pendingSelection != null) await pendingSelection;
      } catch (_) {
        outcome = VoicePickerOutcome.failed;
      }
      return outcome;
    } finally {
      owner._readerVoicePickerOpen = false;
      owner._changed();
    }
  }

  static bool _readerVoiceSourceCurrent(
    _AudioPlaybackScopeState owner,
    _AudioPlaybackController session, {
    required Route<dynamic>? readerRoute,
    required String bookId,
    required int settingsGeneration,
  }) =>
      (readerRoute == null || readerRoute.isCurrent) &&
      _readerVoiceSessionCurrent(
        owner,
        session,
        bookId: bookId,
        settingsGeneration: settingsGeneration,
      );

  static bool _readerVoiceSessionCurrent(
    _AudioPlaybackScopeState owner,
    _AudioPlaybackController session, {
    required String bookId,
    required int settingsGeneration,
  }) =>
      owner.mounted &&
      identical(owner._session, session) &&
      !session._closed &&
      session._bookId == bookId &&
      session._settingsGeneration == settingsGeneration;

  static String? _voiceTargetBookId(
    _AudioPlaybackController session,
    VoiceOption option, {
    required bool narrator,
  }) {
    if (narrator) return option.id.trim().isEmpty ? null : option.id;
    final novel = session._extras.tones.relatedNovel;
    if (session._ttsBookId != session._bookId && novel != null) {
      return novel.id.trim().isEmpty ? null : novel.id;
    }
    return session._bookId;
  }

  static bool _voiceSelectionSucceeded(
    _AudioPlaybackScopeState owner,
    _AudioPlaybackController session, {
    required String bookId,
    required String? toneId,
    required int? requestGeneration,
  }) =>
      owner.mounted &&
      identical(owner._session, session) &&
      !session._closed &&
      session._ready &&
      session._bookId == bookId &&
      (toneId == null || session._toneId == toneId) &&
      requestGeneration != null &&
      session._generation == requestGeneration;

  static Future<int?> _selectVoice(
    _AudioPlaybackController session,
    VoiceOption option, {
    required bool narrator,
    required String targetBookId,
  }) async {
    if (narrator) {
      final expectedGeneration = session._generation + 2;
      await session._switchBookVersion(
        option.id,
        title: option.title,
        cover: session._cover,
        toneId: '0',
      );
      return expectedGeneration;
    }
    if (!session._selectableTone(option.id)) {
      throw StateError('该音色当前不可用');
    }
    final novel = session._extras.tones.relatedNovel;
    if (targetBookId != session._bookId) {
      if (novel == null || targetBookId != novel.id) {
        throw StateError('该音色对应的原著当前不可用');
      }
      final expectedGeneration = session._generation + 2;
      await session._switchBookVersion(
        targetBookId,
        title: novel.title.isEmpty ? session._title : novel.title,
        cover: novel.cover.isEmpty ? session._cover : novel.cover,
        toneId: option.id,
      );
      return expectedGeneration;
    }
    if (option.id == session._toneId) return null;
    final expectedGeneration = session._generation + 1;
    await session._openChapter(
      session._index,
      position: session._player?.position ?? session._position.value,
      toneId: option.id,
      autoplay: session._wantPlay,
      completed: session._completed,
    );
    return expectedGeneration;
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
