// Ported from Wenku8_Flutter@ebcd7f1, lib/reader_tools.dart
// ReaderChapterProgress(compact: true). fqapp supplies a measured 0..1 chapter
// fraction; this is no longer a chapter-index slider. Engine and persistence
// remain owned by ReaderPage. The source's hint, semantics and drag lifecycle
// are retained through ReaderValueSlider.
import 'package:flutter/cupertino.dart';

import '../../services/reader_preferences.dart';
import '../wenku/wenku_ui.dart';
import 'reader_theme.dart';
import 'reader_value_slider.dart';

class ReaderChapterProgress extends StatefulWidget {
  const ReaderChapterProgress({
    super.key,
    required this.preset,
    required this.fraction,
    required this.chapterLabel,
    required this.onPreview,
    required this.onCommitted,
    required this.onPreviewChanged,
    this.onPrevious,
    this.onNext,
  });

  final ReaderThemePreset preset;
  final double? fraction;
  final String chapterLabel;
  final ValueChanged<double> onPreview;
  final ValueChanged<double> onCommitted;
  final ValueChanged<bool> onPreviewChanged;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  State<ReaderChapterProgress> createState() => _ReaderChapterProgressState();
}

class _ReaderChapterProgressState extends State<ReaderChapterProgress> {
  final _hint = OverlayPortalController();
  final _hintLink = LayerLink();
  late final _preview = ValueNotifier<double>(widget.fraction ?? 0);

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  Widget _progressHint(BuildContext context) => Positioned(
    left: 0,
    top: 0,
    child: CompositedTransformFollower(
      link: _hintLink,
      showWhenUnlinked: false,
      targetAnchor: Alignment.topCenter,
      followerAnchor: Alignment.bottomCenter,
      offset: const Offset(0, -10),
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width - 32,
            ),
            child: ValueListenableBuilder<double>(
              valueListenable: _preview,
              builder: (context, value, _) => LiquidGlass(
                key: const ValueKey('reader-progress-drag-hint'),
                radius: 24,
                tintColor: widget.preset.panelColor,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Text(
                  '${widget.chapterLabel} · ${(value * 100).round()}%',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.preset.textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _hint,
    overlayChildBuilder: _progressHint,
    child: CompositedTransformTarget(
      link: _hintLink,
      child: LiquidGlass(
        key: const ValueKey('reader-progress-capsule'),
        radius: 24,
        tintColor: widget.preset.panelColor,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            GlassIconButton(
              key: const ValueKey('reader-previous-chapter'),
              icon: CupertinoIcons.backward_end,
              label: '上一章',
              liveGlass: false,
              transparent: true,
              haptic: HapticCue.pageTurn,
              onPressed: widget.onPrevious,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: ReaderValueSlider(
                sliderKey: const ValueKey('reader-chrome-progress-slider'),
                label: '本章进度',
                inline: true,
                showLabels: false,
                value: widget.fraction ?? 0,
                reconcileValue: true,
                preset: widget.preset,
                min: 0,
                max: 1,
                divisions: 500,
                hapticSteps: 100,
                format: (value) => '${(value * 100).round()}%',
                onPreview: (value) {
                  if (!mounted) return;
                  _preview.value = value;
                  widget.onPreview(value);
                },
                onCommitted: widget.fraction == null
                    ? null
                    : widget.onCommitted,
                onInteractionChanged: (active) {
                  if (!mounted) return;
                  if (active) {
                    _preview.value = widget.fraction ?? 0;
                    _hint.show();
                  } else {
                    _hint.hide();
                  }
                  widget.onPreviewChanged(active);
                },
              ),
            ),
            const SizedBox(width: 4),
            GlassIconButton(
              key: const ValueKey('reader-next-chapter'),
              icon: CupertinoIcons.forward_end,
              label: '下一章',
              liveGlass: false,
              transparent: true,
              haptic: HapticCue.pageTurn,
              onPressed: widget.onNext,
            ),
          ],
        ),
      ),
    ),
  );
}
