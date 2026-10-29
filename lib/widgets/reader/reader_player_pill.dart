import 'dart:async';

import 'package:flutter/material.dart';

import '../../pages/audio_page.dart' show AudioPlaybackScope;
import '../../services/listening_session.dart';
import '../../services/reader_preferences.dart';
import 'reader_player_style.dart';
import 'reader_sync_pill.dart';

/// ReaderPlayerButton (ajo.xml): both indicator and text retain their label.
class ReaderPlayerPill extends StatelessWidget {
  const ReaderPlayerPill({
    super.key,
    required this.playing,
    required this.onTap,
    this.weak = false,
    this.preset = ReaderThemePreset.light,
    this.animate = true,
  });

  final bool playing;
  final VoidCallback onTap;
  final bool weak;
  final ReaderThemePreset preset;
  final bool animate;

  static const double height = 32;

  @override
  Widget build(BuildContext context) {
    final label = playing ? '暂停播放' : '继续播放';
    final foreground = weak ? preset.playerWeakText : preset.playerText;
    final motion =
        animate &&
        preset != ReaderThemePreset.eink &&
        !MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        key: ValueKey(weak ? 'reader-player-text' : 'reader-player-indicator'),
        color: weak ? Colors.transparent : preset.playerBackground,
        borderRadius: BorderRadius.circular(height / 2),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('reader_player_pill'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: height),
            child: Padding(
              padding: const EdgeInsets.only(left: 18, right: 20),
              child: AnimatedSwitcher(
                duration: motion
                    ? const Duration(milliseconds: 200)
                    : Duration.zero,
                child: Row(
                  key: ValueKey(playing),
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      playing ? Icons.pause : Icons.play_arrow,
                      size: MediaQuery.textScalerOf(context).scale(14),
                      color: foreground,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        label,
                        key: const ValueKey('reader_player_pill_label'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: foreground, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Separate floating and page-footer hosts, as in BottomIndicatorContainer
/// and ReaderBottomView.extraLayout. Reserve the footer even without a session
/// so starting, stopping and weakening never repaginate the current text.
class ReaderPlayerPillHost extends StatefulWidget {
  const ReaderPlayerPillHost({
    super.key,
    required this.bookId,
    required this.child,
    required this.highlightOnScreen,
    required this.viewportChanges,
    this.normalPage,
    this.onReturnOriginalProgress,
    this.onListenFromPage,
    this.footerBuilder,
    this.controlsVisible = false,
    this.preset = ReaderThemePreset.light,
    this.animate = true,
  });

  final String bookId;
  final Widget child;
  final bool Function() highlightOnScreen;
  final Listenable viewportChanges;

  /// Official `d.java:305-320` `y(page)`: whether the current page is a normal
  /// text page. The sync pill replaces the play/pause pill when the narration
  /// highlight is off screen and this page is normal.
  final bool Function()? normalPage;

  /// `AudioSyncReaderController.K()`: back to the live position and follow.
  final VoidCallback? onReturnOriginalProgress;

  /// `AudioSyncReaderController.L()`: start listening from this page.
  final VoidCallback? onListenFromPage;

  final Widget? Function(Widget? player)? footerBuilder;
  final bool controlsVisible;
  final ReaderThemePreset preset;
  final bool animate;

  @override
  State<ReaderPlayerPillHost> createState() => _ReaderPlayerPillHostState();
}

class _ReaderPlayerPillHostState extends State<ReaderPlayerPillHost> {
  Timer? _weakening;
  bool _weak = false;
  bool _refreshPending = false;
  (String?, String?, bool, bool, bool)? _snapshot;

  bool get _active {
    final session = ListeningSession.instance;
    // 官方 onPlayCompletion（d.java:92-100）收起播放按钮。
    return session.bookId == widget.bookId && !session.completed;
  }

  bool get _eligible =>
      _active &&
      ListeningSession.instance.playing &&
      widget.highlightOnScreen();

  @override
  void initState() {
    super.initState();
    ListeningSession.instance.addListener(_scheduleRefresh);
    widget.viewportChanges.addListener(_scheduleRefresh);
    _scheduleRefresh();
  }

  @override
  void didUpdateWidget(ReaderPlayerPillHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewportChanges != widget.viewportChanges) {
      oldWidget.viewportChanges.removeListener(_scheduleRefresh);
      widget.viewportChanges.addListener(_scheduleRefresh);
    }
    if (oldWidget.bookId != widget.bookId) {
      _cancelWeakening();
      _weak = false;
      _snapshot = null;
    }
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    if (_refreshPending) return;
    _refreshPending = true;
    // The reader prepares/restores its layout below this host. Sample only
    // after layout, not the previous page's geometry during the parent build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshPending = false;
      if (mounted) _refresh();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _cancelWeakening() {
    _weakening?.cancel();
    _weakening = null;
  }

  void _refresh() {
    final session = ListeningSession.instance;
    final eligible = _eligible;
    final next = (
      session.bookId,
      session.chapterId,
      session.playing,
      eligible,
      session.completed,
    );
    final changedChapter = _snapshot?.$1 != next.$1 || _snapshot?.$2 != next.$2;
    final wasWeak = _weak;
    if (!eligible || changedChapter) {
      _weak = false;
      _cancelWeakening();
    }
    if (widget.controlsVisible) _cancelWeakening();
    if (eligible && !widget.controlsVisible && !_weak && _weakening == null) {
      _weakening = Timer(const Duration(seconds: 5), () {
        _weakening = null;
        if (!mounted || widget.controlsVisible || !_eligible) return;
        final current = ListeningSession.instance;
        if (current.bookId != next.$1 || current.chapterId != next.$2) return;
        setState(() => _weak = true);
      });
    }
    if (_snapshot != next || wasWeak != _weak) {
      setState(() => _snapshot = next);
      _scheduleRefresh();
    }
  }

  void _togglePlayback() {
    if (!AudioPlaybackScope.togglePlayback(context, widget.bookId)) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('当前播放尚未就绪，请稍后重试')));
    }
  }

  @override
  void dispose() {
    _cancelWeakening();
    ListeningSession.instance.removeListener(_scheduleRefresh);
    widget.viewportChanges.removeListener(_scheduleRefresh);
    super.dispose();
  }

  Widget _slot({required bool floating}) {
    final highlightOnScreen = widget.highlightOnScreen();
    // 官方 d.p()（d.java:285-320）：高亮在屏内给播放/暂停胶囊，否则给
    // 「原进度 / 从本页听」同步胶囊。同步胶囊只占浮动位（页面底部），
    // 5 秒弱化只属于播放胶囊。
    final sync =
        _active &&
        !widget.controlsVisible &&
        !highlightOnScreen &&
        (widget.normalPage?.call() ?? true);
    final show =
        !widget.controlsVisible &&
        _active &&
        (sync ? floating : highlightOnScreen && (floating ? !_weak : _weak));
    final motion =
        widget.animate &&
        widget.preset != ReaderThemePreset.eink &&
        !MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      ignoring: !show,
      child: ExcludeSemantics(
        excluding: !show,
        child: AnimatedSwitcher(
          duration: motion ? const Duration(milliseconds: 300) : Duration.zero,
          reverseDuration: motion
              ? const Duration(milliseconds: 200)
              : Duration.zero,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: floating
                ? ScaleTransition(
                    scale: Tween(begin: 0.8, end: 1.0).animate(animation),
                    child: child,
                  )
                : child,
          ),
          child: !show
              ? const SizedBox.shrink()
              : sync
              ? ReaderSyncPill(
                  preset: widget.preset,
                  onReturnOriginalProgress:
                      widget.onReturnOriginalProgress ?? () {},
                  onListenFromPage: widget.onListenFromPage ?? () {},
                )
              : ReaderPlayerPill(
                  playing: ListeningSession.instance.playing,
                  onTap: _togglePlayback,
                  weak: !floating,
                  preset: widget.preset,
                  animate: motion,
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final footerHeight = MediaQuery.textScalerOf(context).scale(20) + 12;
    final footer = widget.footerBuilder?.call(
      _active ? _slot(floating: false) : null,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        Column(
          children: [
            Expanded(child: widget.child),
            if (footer != null)
              footer
            else
              SizedBox(
                key: _active ? const ValueKey('reader-player-footer') : null,
                height: footerHeight < 32 ? 32 : footerHeight,
                child: _active ? Center(child: _slot(floating: false)) : null,
              ),
          ],
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 18,
          child: Center(child: _slot(floating: true)),
        ),
      ],
    );
  }
}
