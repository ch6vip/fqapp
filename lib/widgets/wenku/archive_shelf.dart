// Ported from Wenku8_Flutter lib/archive_wave.dart (revision ebcd7f1).
//
// Scope: `ArchiveFileCarousel`, `_FlatArchiveCarousel`, `_LazyArchiveCover`,
// `_ArchiveSnapPhysics`, `_WavePose`, `_ShelfRow`, `ArchiveShelfSceneRender`,
// `_BookVolume` and `ArchiveBoxDepthRender`.
//
// Mechanical substitutions:
// - `Novel` + `LibraryState` -> `ArchiveShelfEntry` (fqapp flattens reading
//   state into the row value at `src/archive_shelf_entry.dart`).
// - `NavalMotion`-style `NovelMotion` constants -> `WenkuMotion`
//   (`wenku_theme.dart`).
// - `AppTonalColors` -> `WenkuTonalColors` (`wenku_theme.dart`).
// - `NovelCover`/`LegacyCover`/`LocalBookMedia` -> `ShelfCoverImage`
//   (`widgets/shelf/shelf_cover_image.dart`), backed by the single
//   `PosterCache`.
// - `LibraryReflowPart` wrappers are dropped: fqapp has no reflow scope (same
//   treatment as the already-ported `book_collection_layout.dart`).
// - `PaperCoverOcclusionSource` / `coverOcclusion` are dropped: fqapp has no
//   Hero flight.
// - `ActiveListenableBuilder` over `LibraryState.historyChanges` is dropped;
//   the circular does not own history. `_active` is the only clock.
// - `ReadingEntry` -> the `directReading` bool supplied by the page.
// - `widget.onOpen(book, heroTag)` -> `widget.onOpen(entry)` (frozen design
//   §2.5).
// - `ArchiveDesign.fileCode(int)` -> `ArchiveShelfEntry.fileCode` using the
//   search tiles' FQ-/SQ- convention.
// - The carousel gains `interactive`, `selecting` and `selected`; edit mode
//   freezes dragging and routes taps straight to `onOpen` (fqapp selection
//   semantics, decisions #12).
// - Long-press recognisers live inside the volume: the two `ContentPanel`
//   faces are wrapped in `GestureDetector`, and the projected top cap gets a
//   `LongPressGestureRecognizer` on `ArchiveBoxDepthRender`. Wrapping the
//   whole volume would cut `hitTestChildren` off from the render object.
// - `didUpdateWidget` stores a pending lane jump instead of jumping during
//   build; the jump is clamped against the new extents in a post-frame
//   callback (design C-M3). `_active` stores the raw lane (C-M2).
// - Under `repeatFill`, a count change realigns the lane to the same loop
//   cycle (`_alignedLane`) so `lane % count` still selects the focused book.
// - `_FlatArchiveCarousel` applies the same identity rule: equal-length
//   reorders, count changes and `repeatFill` switches rebuild its
//   `PageController` at the matching page.
// - The narrow caption's second line uses `entry.detailLine`, so reading
//   progress is visible in every mode (design C-M4).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../shelf/shelf_cover_image.dart';
import '../../services/app_style_tokens.dart';
import 'book_source_badge.dart';
import 'src/app_text.dart';
import 'src/archive_icons.dart';
import 'src/archive_shelf_entry.dart';
import 'src/archive_shelf_geometry.dart';
import 'src/archive_shelf_loading.dart';
import 'src/archive_scroll_simulation.dart';
import 'src/archive_spine_title.dart';
import 'src/performance_preferences.dart';
import 'wenku_archive.dart';
import 'wenku_glass.dart';
import 'wenku_loading.dart';
import 'wenku_reveal.dart';
import 'wenku_theme.dart';

/// Scroll position is the single clock for the continuous extraction wave.
class ArchiveFileCarousel extends StatefulWidget {
  const ArchiveFileCarousel({
    super.key,
    required this.entries,
    required this.onOpen,
    required this.directReading,
    this.onLongPress,
    this.reduceMotion = false,
    this.animateEntrance = false,
    this.repeatFill = true,
    this.showChrome = true,
    this.initialIndex = 0,
    this.interactive = true,
    this.selecting = false,
    this.selected = const <String>{},
  });
  final List<ArchiveShelfEntry> entries;
  final ValueChanged<ArchiveShelfEntry> onOpen;
  final ValueChanged<ArchiveShelfEntry>? onLongPress;

  /// The page's actual `BookOpenPreferences` value; only the wide information
  /// pane's action label changes.
  final bool directReading;
  final bool reduceMotion;
  final bool animateEntrance;
  final bool repeatFill;

  /// Keeps the physical bank while omitting its browsing labels and actions.
  final bool showChrome;

  /// Applied only when this carousel is first mounted, within the book range.
  final int initialIndex;

  /// False in edit mode: the bank cannot be dragged and taps route directly to
  /// [onOpen] (the page toggles selection there).
  final bool interactive;
  final bool selecting;

  /// Selected identities (`ArchiveShelfEntry.identity`).
  final Set<String> selected;

  @override
  ArchiveFileCarouselState createState() => ArchiveFileCarouselState();
}

class ArchiveFileCarouselState extends State<ArchiveFileCarousel>
    with SingleTickerProviderStateMixin {
  ScrollController? _scroll;
  late final _WavePose _pose;
  late final ValueNotifier<int> _active;
  int? _targetIndex;

  /// Post-frame lane jump requested by `didUpdateWidget`.
  int? _pendingJumpIndex;
  int _command = 0;
  bool _reduced = false;
  bool _hapticGesture = false;
  int? _lastDetent;
  late final _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
    value: widget.animateEntrance ? 0 : 1,
  );

  @visibleForTesting
  bool get entranceCompleted => _entrance.isCompleted;

  @visibleForTesting
  String? get focusedIdentity => widget.entries.isEmpty
      ? null
      : widget.entries[_pose.bookIndex(_pose.focus.round())].identity;

  @visibleForTesting
  int get debugCentreSlot => _pose.bookIndex(_pose.focus.round());

  @visibleForTesting
  int get debugPoolCount => _pose.poolCount;

  @visibleForTesting
  double get debugFocus => _pose.logicalFocus;

  @visibleForTesting
  AnimationController get debugEntranceClock => _entrance;

  void _finishEntrance() {
    if (!_entrance.isCompleted) _entrance.value = 1;
  }

  @override
  void initState() {
    super.initState();
    final initialIndex = widget.entries.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.entries.length - 1).toInt();
    _pose = _WavePose(
      widget.entries.length,
      initialIndex.toDouble(),
      _entrance,
      fill: widget.repeatFill,
    );
    _entrance.addListener(_pose.inkChanged);
    _active = ValueNotifier(initialIndex);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.reduceMotion ||
        !PerformanceScope.of(context).shelf3d ||
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _finishEntrance();
    } else if (!_entrance.isAnimating && !_entrance.isCompleted) {
      _entrance.forward();
    }
  }

  @override
  void didUpdateWidget(ArchiveFileCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Capture the old lane before the count changes: under `repeatFill` the
    // lane is unbounded, so the focused book is `lane % oldCount`.
    final oldLane = _pose.logicalFocus;
    final oldCount = oldWidget.entries.length;
    final newCount = widget.entries.length;
    final repeatChanged = oldWidget.repeatFill != widget.repeatFill;
    final oldIndex = oldCount == 0 ? 0 : oldLane.round() % oldCount;
    final oldEntry = oldCount == 0 ? null : oldWidget.entries[oldIndex];
    _pose.repeatFill = widget.repeatFill;
    _pose.count = newCount;
    final nextIndex = oldEntry == null
        ? 0
        : widget.entries.indexWhere(
            (entry) => entry.identity == oldEntry.identity,
          );
    final target = nextIndex < 0 ? 0 : nextIndex;
    // A changed count is a move even when the focused book keeps its index:
    // under `repeatFill` the same lane maps to `lane % count`, so 15 % 10 -> 5
    // becomes 15 % 6 -> 3 and silently switches books (design C-M3, decision
    // #9: the shelf follows filtering/sorting).
    final countChanged = oldCount != newCount;
    final indexMoved =
        oldEntry != null && nextIndex >= 0 && nextIndex != oldIndex;
    final moved = repeatChanged || countChanged || indexMoved;
    if (moved) {
      // Keep the same loop cycle under `repeatFill` so the jump lands on the
      // nearest congruent lane instead of the start of the bank.
      final lane = widget.repeatFill && newCount > 1
          ? _alignedLane(target, newCount, oldLane.round())
          : target;
      _pose.move(lane.toDouble());
      _lastDetent = lane;
      _command++;
      _targetIndex = null;
      _hapticGesture = false;
      // The next layout derives a new extent/pool from the scroll pixels. Jump
      // after that frame, clamped against the final extents (design C-M3).
      _pendingJumpIndex = lane;
      _schedulePendingJump();
    } else {
      _pose.move(_pose.logicalFocus);
    }
    _active.value = _pose.logicalFocus.round();
    if (widget.reduceMotion) _finishEntrance();
  }

  /// The lane congruent to [target] modulo [count] that is closest to [lane].
  static int _alignedLane(int target, int count, int lane) {
    final cycles = ((lane - target) / count).round();
    return target + cycles * count;
  }

  void _schedulePendingJump() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final lane = _pendingJumpIndex;
      if (!mounted || lane == null || _scroll?.hasClients != true) return;
      _pendingJumpIndex = null;
      final position = _scroll!.position;
      final target = (lane * _pose.pitch).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((position.pixels - target).abs() > .01) _scroll!.jumpTo(target);
    });
  }

  void _scrolled() {
    if (_scroll?.hasClients != true) return;
    _pose.move(_scroll!.offset / _pose.pitch);
    final lane = _pose.logicalFocus.round();
    if (_active.value != lane) {
      _active.value = lane;
    }
    if (!_hapticGesture || widget.entries.length < 2) return;
    // 0.4.6's click belonged to the approaching book centre, not to the
    // halfway selection boundary. Detect the crossed centre interval too, so
    // a fast frame cannot skip it. The last centre prevents reversal chatter.
    final previous = _lastDetent ?? lane;
    final focus = _pose.logicalFocus;
    final crossed = focus > previous
        ? (focus + .12).floor()
        : focus < previous
        ? (focus - .12).ceil()
        : previous;
    if (crossed == previous) return;
    // Always consume crossings, even when frequency gating drops a fast tick.
    // Never replay skipped books on release, snapping, or a later idle frame.
    _lastDetent = crossed;
    AppHaptics.play(context, HapticCue.shelfStep);
  }

  void _tap(int index) {
    if (!widget.interactive) {
      _open(index);
      return;
    }
    if ((_pose.focus - index).abs() < .03 &&
        _scroll?.position.isScrollingNotifier.value == false) {
      _open(index);
    } else {
      unawaited(_centre(_pose.logicalLane(index)));
    }
  }

  Future<void> _centre(int index) async {
    if (widget.entries.length < 2 || _scroll?.hasClients != true) {
      return;
    }
    if (!widget.repeatFill) index = index.clamp(0, widget.entries.length - 1);
    if ((_scroll!.offset - index * _pose.pitch).abs() < .01) return;
    _finishEntrance();
    final command = ++_command;
    _targetIndex = index;
    if (!_hapticGesture) _lastDetent = _pose.logicalFocus.round();
    _hapticGesture = true;
    final target = index * _pose.pitch;
    if (_reduced) {
      _scroll!.jumpTo(target);
    } else {
      await _scroll!.animateTo(
        target,
        duration: WenkuMotion.enter,
        curve: const Cubic(.2, 1.06, .35, 1),
      );
    }
    if (mounted && command == _command) {
      _targetIndex = null;
      _hapticGesture = false;
    }
  }

  void _step(int delta) =>
      unawaited(_centre((_targetIndex ?? _active.value) + delta));

  void _open(int index) {
    if (widget.entries.isEmpty) return;
    AppHaptics.play(context, HapticCue.action);
    _finishEntrance();
    _command++;
    _targetIndex = null;
    _hapticGesture = false;
    if (_scroll?.hasClients == true) {
      (_scroll!.position as ScrollPositionWithSingleContext).goIdle();
    }
    widget.onOpen(widget.entries[_pose.bookIndex(index)]);
  }

  void _longPress(ArchiveShelfEntry entry) {
    AppHaptics.play(context, HapticCue.longPress);
    widget.onLongPress?.call(entry);
  }

  @override
  void dispose() {
    _scroll?.removeListener(_scrolled);
    _scroll?.dispose();
    _entrance.removeListener(_pose.inkChanged);
    _entrance.dispose();
    _pose.dispose();
    _active.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox.shrink();
    if (!PerformanceScope.of(context).shelf3d) {
      return _FlatArchiveCarousel(
        entries: widget.entries,
        onOpen: widget.onOpen,
        onLongPress: widget.onLongPress,
        repeatFill: widget.repeatFill,
        showChrome: widget.showChrome,
        initialIndex: widget.initialIndex,
        interactive: widget.interactive,
        selecting: widget.selecting,
        selected: widget.selected,
      );
    }
    _reduced = widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Use the browsing pane's actual width, not the device width.
        final wide =
            widget.showChrome &&
            constraints.maxWidth >= 880 &&
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final width = math.min(
          constraints.maxWidth,
          ArchiveShelfGeometry.maxViewportWidth,
        );
        final spine = _WavePose.spineFor(width);
        final pitch = _WavePose.pitchFor(width);
        final cover = _WavePose.coverFor(width);
        final height = ArchiveShelfGeometry.bodyHeight(cover);
        _pose.configure(width, pitch);
        _scroll ??= ScrollController(
          initialScrollOffset: _pose.logicalFocus * pitch,
          // This state owns the unbounded lane. Nested discovery PageStorage
          // must not restore vertical feed pixels into the horizontal bank.
          keepScrollOffset: false,
        )..addListener(_scrolled);
        final rowHeight = ArchiveShelfGeometry.rowHeight(cover, height);
        final dark = Theme.of(context).brightness == Brightness.dark;
        final shelf = SizedBox(
          width: width,
          child: Column(
            key: const ValueKey('archive-shelf-arrival'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: rowHeight,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification is ScrollStartNotification &&
                        notification.dragDetails != null) {
                      _finishEntrance();
                      _targetIndex = null;
                      _command++;
                      _hapticGesture = true;
                      _lastDetent = _pose.logicalFocus.round();
                    } else if (notification is ScrollStartNotification &&
                        _targetIndex != null) {
                      _hapticGesture = true;
                    } else if (notification is ScrollEndNotification) {
                      _hapticGesture = false;
                    }
                    return false;
                  },
                  child: Scrollable(
                    key: const ValueKey('archive-file-carousel'),
                    controller: _scroll,
                    axisDirection: AxisDirection.right,
                    physics: !widget.interactive || widget.entries.length == 1
                        ? const NeverScrollableScrollPhysics()
                        : _ArchiveSnapPhysics(pose: _pose),
                    viewportBuilder: (context, offset) => _ShelfRow(
                      offset: offset,
                      pose: _pose,
                      spine: spine,
                      cover: cover,
                      height: height,
                      dark: dark,
                      children: [
                        for (var i = 0; i < _pose.poolCount; i++)
                          _volume(
                            context,
                            widget.entries[_pose.bookIndex(i)],
                            i,
                            spine,
                            cover,
                            height,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              // Only labels change at index crossings. Never rebuild the bank for
              // each scroll pixel, and never restart a separate extraction timer.
              if (widget.showChrome && !wide)
                ValueListenableBuilder<int>(
                  valueListenable: _active,
                  builder: (context, index, _) {
                    final entry = widget.entries[index % widget.entries.length];
                    final scale =
                        MediaQuery.textScalerOf(context).scale(17) / 17;
                    return SizedBox(
                      height: 16 + 17 * 1.35 * 2 * scale + 12 * 1.4 * scale,
                      child: LoadingHandoff(
                        animation: _entrance,
                        crossfade: true,
                        start: .2,
                        end: .75,
                        placeholder: const LoadingSkeleton(
                          layout: SkeletonLayout.actions,
                        ),
                        child: JellyTapSurface(
                          key: const ValueKey('archive-shelf-open'),
                          // Opening from the cover, caption, or semantics
                          // uses the same committed-action feedback in _open.
                          haptic: null,
                          onTap: _tapActive,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      AppText(
                                        entry.item.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 17,
                                          height: 1.35,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      AppText(
                                        entry.detailLine,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.4,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const ArchiveIcon(
                                  CupertinoIcons.arrow_up_right,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              if (widget.showChrome)
                ValueListenableBuilder<int>(
                  valueListenable: _active,
                  builder: (context, index, _) => Row(
                    children: [
                      const Spacer(),
                      if (widget.entries.length > 1) ...[
                        ArchiveIconButton(
                          tooltip: '上一份档案',
                          haptic: null,
                          onPressed: widget.repeatFill || index > 0
                              ? () => _step(-1)
                              : null,
                          icon: const ArchiveIcon(
                            CupertinoIcons.chevron_left,
                            size: 13,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        Semantics(
                          label:
                              '第 ${index % widget.entries.length + 1} 本，共 ${widget.entries.length} 本${widget.repeatFill ? '，循环浏览' : ''}',
                          child: ArchiveCode(
                            '${(index % widget.entries.length + 1).toString().padLeft(2, '0')} / ${widget.entries.length.toString().padLeft(2, '0')}',
                            decorative: false,
                          ),
                        ),
                        ArchiveIconButton(
                          tooltip: '下一份档案',
                          haptic: null,
                          onPressed:
                              widget.repeatFill ||
                                  index < widget.entries.length - 1
                              ? () => _step(1)
                              : null,
                          icon: const ArchiveIcon(
                            CupertinoIcons.chevron_right,
                            size: 13,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: wide ? 1040 : width),
            child: Row(
              children: [
                shelf,
                if (wide) ...[
                  const SizedBox(width: 48),
                  Expanded(
                    child: KeyedSubtree(
                      key: const ValueKey('archive-shelf-wide'),
                      child: _information(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _tapActive() => _open(_pose.focus.round());

  Widget _information(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: _active,
    builder: (context, index, _) {
      final entry = widget.entries[index % widget.entries.length];
      final item = entry.item;
      final read = entry.read;
      final direct = widget.directReading;
      final progress = entry.fraction?.clamp(0.0, 1.0);
      final colors = Theme.of(context).colorScheme;
      final muted = colors.onSurfaceVariant;
      final summary = item.intro.trim();
      final tags = item.categories.take(3).join(' · ');
      final scaler = MediaQuery.textScalerOf(context);
      return AnimatedSwitcher(
        key: const ValueKey('archive-shelf-information-switch'),
        duration: _reduced ? Duration.zero : WenkuMotion.enter,
        reverseDuration: _reduced ? Duration.zero : WenkuMotion.exit,
        switchInCurve: WenkuMotion.ease,
        switchOutCurve: WenkuMotion.retract,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [
            // Fast swipes can cross many books before a fade completes.
            // Paint only the latest outgoing book, and never let it take taps.
            if (previous.isNotEmpty)
              IgnorePointer(child: ExcludeSemantics(child: previous.last)),
            ?current,
          ],
        ),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: animation.drive(
              Tween(begin: const Offset(0, .04), end: Offset.zero),
            ),
            child: child,
          ),
        ),
        child: Column(
          key: ValueKey(entry.identity),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ArchiveCode(
              '${(index % widget.entries.length + 1).toString().padLeft(2, '0')} / ${widget.entries.length.toString().padLeft(2, '0')}',
              decorative: false,
            ),
            const SizedBox(height: 16),
            SizedBox(
              key: const ValueKey('archive-shelf-title-slot'),
              height: scaler.scale(28) * 1.25 * 2,
              child: AppText(
                item.title,
                key: const ValueKey('archive-shelf-wide-title'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 28,
                  height: 1.25,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: scaler.scale(14) * 1.5,
              child: AppText(
                entry.subtitleLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, height: 1.5, color: muted),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: scaler.scale(12) * 1.5 * 2,
              child: AppText(
                tags,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, height: 1.5, color: muted),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              key: const ValueKey('archive-shelf-summary-slot'),
              height: scaler.scale(14) * 1.7 * 3,
              child: AppText(
                summary,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, height: 1.7, color: muted),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              key: const ValueKey('archive-shelf-progress-slot'),
              height: scaler.scale(13) * 1.5 * 2 + 13,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText(
                    entry.progressText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, height: 1.5, color: muted),
                  ),
                  const Spacer(),
                  if (read && progress != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        color: colors.onSurface.withValues(alpha: .65),
                        backgroundColor: colors.onSurface.withValues(
                          alpha: .08,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: GlassPillButton(
                key: const ValueKey('archive-shelf-wide-open'),
                icon: direct
                    ? CupertinoIcons.play_fill
                    : CupertinoIcons.arrow_up_right,
                label: direct ? (read ? '继续阅读' : '开始阅读') : '查看详情',
                onPressed: () => _open(_pose.focus.round()),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _volume(
    BuildContext context,
    ArchiveShelfEntry entry,
    int index,
    double spine,
    double cover,
    double height,
  ) {
    final item = entry.item;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final number = _pose.bookIndex(index) + 1;
    void tap() => _tap(index);
    Widget ink(Widget child, {bool spine = false}) => ArchiveShelfInk(
      animation: _entrance,
      start: _pose.inkStart(index),
      end: _pose.inkStart(index) + .35,
      base: spine
          ? (dark ? ArchiveDesign.darkRaised : const Color(0xFFF2F0E9))
          : dark
          ? Theme.of(context).extension<WenkuTonalColors>()?.glassSurface ??
                ArchiveDesign.darkSurface
          : Theme.of(context).extension<WenkuTonalColors>()?.milk ??
                ArchiveDesign.milk,
      ink: Theme.of(context).colorScheme.onSurface,
      spine: spine,
      child: child,
    );
    Widget longPress(Widget child) => GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onLongPress: widget.onLongPress == null ? null : () => _longPress(entry),
      child: child,
    );
    return _BookVolume(
      key: ValueKey('archive-slot-$index'),
      pose: _pose,
      index: index,
      spine: spine,
      cover: cover,
      height: height,
      dark: dark,
      label: item.title,
      direction: Directionality.of(context),
      onTap: tap,
      onLongPress: widget.onLongPress == null ? null : () => _longPress(entry),
      children: [
        ExcludeSemantics(
          child: RepaintBoundary(
            child: ink(
              longPress(
                ContentPanel(
                  key: ValueKey('archive-spine-$index'),
                  haptic: null,
                  radius: 0,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 1,
                    vertical: 9,
                  ),
                  // Solid physical faces occlude other files; milk comes from
                  // shading, not alpha that lets readable rear text bleed
                  // through the surface.
                  backgroundColor: dark
                      ? ArchiveDesign.darkRaised
                      : const Color(0xFFF2F0E9),
                  onTap: tap,
                  child: MediaQuery.withNoTextScaling(
                    child: Column(
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: ArchiveCode(number.toString().padLeft(2, '0')),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: Center(child: ArchiveSpineTitle(item.title)),
                        ),
                        const SizedBox(height: 6),
                        ArchiveIcon(
                          CupertinoIcons.circle,
                          size: 6,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              spine: true,
            ),
          ),
        ),
        ExcludeSemantics(
          child: RepaintBoundary(
            child: ink(
              longPress(
                ContentPanel(
                  key: ValueKey('archive-cover-$index'),
                  haptic: null,
                  radius: 0,
                  padding: const EdgeInsets.fromLTRB(10, 9, 10, 8),
                  backgroundColor: dark
                      ? Theme.of(
                              context,
                            ).extension<WenkuTonalColors>()?.glassSurface ??
                            ArchiveDesign.darkSurface
                      : Theme.of(context).extension<WenkuTonalColors>()?.milk ??
                            ArchiveDesign.milk,
                  onTap: tap,
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: ArchiveCode(
                              'NO.${number.toString().padLeft(3, '0')}',
                            ),
                          ),
                          if (entry.sourceLabel case final label?)
                            BookSourceBadge(label),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _LazyArchiveCover(
                              entry: entry,
                              pose: _pose,
                              index: index,
                              width: cover - 20,
                              height: (cover - 20) * 166 / 118,
                              reduced: _reduced,
                            ),
                            if (widget.selecting)
                              _ArchiveSelectionMark(
                                selected: widget.selected.contains(
                                  entry.identity,
                                ),
                              ),
                            if (entry.updated || entry.cached)
                              Positioned(
                                top: 4,
                                right: 4,
                                child: BookSourceBadge(
                                  entry.updated ? '更新' : '缓存',
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (widget.showChrome &&
                          AppStyleTokens.of(context).showDecorativeCodes) ...[
                        const SizedBox(height: 4),
                        ArchiveCode(entry.fileCode),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A selected-state check drawn over the cover. U5 owns the shared tile mark;
/// the carousel keeps its own tiny mark so U4 compiles without U5.
class _ArchiveSelectionMark extends StatelessWidget {
  const _ArchiveSelectionMark({required this.selected});
  final bool selected;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Semantics(
        selected: selected,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.black.withValues(alpha: .18),
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.white.withValues(alpha: .9),
              width: 1.4,
            ),
          ),
          child: selected
              ? Icon(
                  CupertinoIcons.check_mark,
                  size: 13,
                  color: Theme.of(context).colorScheme.surface,
                )
              : null,
        ),
      ),
    ),
  );
}

/// A virtual, lazily built loop with no perspective mesh or extraction layers.
/// It keeps discovery's cover navigation available on the lightweight preset.
class _FlatArchiveCarousel extends StatefulWidget {
  const _FlatArchiveCarousel({
    required this.entries,
    required this.onOpen,
    required this.onLongPress,
    required this.repeatFill,
    required this.showChrome,
    required this.initialIndex,
    required this.interactive,
    required this.selecting,
    required this.selected,
  });
  final List<ArchiveShelfEntry> entries;
  final ValueChanged<ArchiveShelfEntry> onOpen;
  final ValueChanged<ArchiveShelfEntry>? onLongPress;
  final bool repeatFill;
  final bool showChrome;
  final int initialIndex;
  final bool interactive;
  final bool selecting;
  final Set<String> selected;

  @override
  State<_FlatArchiveCarousel> createState() => _FlatArchiveCarouselState();
}

class _FlatArchiveCarouselState extends State<_FlatArchiveCarousel> {
  bool _userPaging = false;
  late var _pages = PageController(
    initialPage:
        (widget.repeatFill ? widget.entries.length * 10000 : 0) +
        (widget.entries.isEmpty
            ? 0
            : widget.initialIndex.clamp(0, widget.entries.length - 1).toInt()),
    viewportFraction: .62,
    keepPage: false,
  );

  @override
  void didUpdateWidget(_FlatArchiveCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldEntries = oldWidget.entries;
    final oldCount = oldEntries.length;
    final newCount = widget.entries.length;
    final page = _pages.hasClients
        ? _pages.page?.round() ?? _pages.initialPage
        : _pages.initialPage;
    final oldIndex = oldCount == 0 ? 0 : page % oldCount;
    final oldId = oldCount == 0 ? null : oldEntries[oldIndex].identity;
    final matching = oldId == null
        ? -1
        : widget.entries.indexWhere((entry) => entry.identity == oldId);
    final next = matching < 0 ? 0 : matching;
    // The filtered/reordered list must move the PageView with it. Comparing the
    // visible identity covers equal-length reorders; count and repeatFill
    // changes cover filtering and the mode switch.
    final moved =
        oldWidget.repeatFill != widget.repeatFill ||
        oldCount != newCount ||
        (matching >= 0 && next != oldIndex);
    if (!moved) return;
    final previous = _pages;
    _pages = PageController(
      initialPage: (widget.repeatFill ? newCount * 10000 : 0) + next,
      viewportFraction: .62,
      // A finite bank must not restore a previously saved unbounded lane.
      keepPage: false,
    );
    _userPaging = false;
    previous.dispose();
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      key: const ValueKey('archive-flat-carousel'),
      height: 300,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification &&
                  notification.dragDetails != null) {
                _userPaging = true;
              } else if (notification is ScrollEndNotification) {
                _userPaging = false;
              }
              return false;
            },
            child: PageView.builder(
              key: ObjectKey(_pages),
              controller: _pages,
              physics: !widget.interactive || widget.entries.length == 1
                  ? const NeverScrollableScrollPhysics()
                  : null,
              itemCount: widget.repeatFill ? null : widget.entries.length,
              onPageChanged: (_) {
                if (_userPaging) {
                  AppHaptics.play(context, HapticCue.shelfStep);
                }
              },
              itemBuilder: (context, index) {
                final entry = widget.entries[index % widget.entries.length];
                final item = entry.item;
                return Semantics(
                  label: '${item.title}，${item.author}',
                  button: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.deferToChild,
                    onLongPress: widget.onLongPress == null
                        ? null
                        : () {
                            AppHaptics.play(context, HapticCue.longPress);
                            widget.onLongPress!(entry);
                          },
                    child: JellyTapSurface(
                      onTap: () {
                        widget.onOpen(entry);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Center(
                                child: FittedBox(
                                  fit: BoxFit.contain,
                                  child: Stack(
                                    children: [
                                      ShelfCoverImage(
                                        item: item,
                                        width: 154,
                                        height: 220,
                                        radius: ArchiveDesign.coverRadius,
                                        decodeWidth: shelfCoverDecodeWidth(
                                          154,
                                          MediaQuery.devicePixelRatioOf(
                                            context,
                                          ),
                                        ),
                                      ),
                                      if (entry.sourceLabel case final label?)
                                        Positioned(
                                          top: 5,
                                          right: 5,
                                          child: BookSourceBadge(label),
                                        ),
                                      if (widget.selecting)
                                        Positioned.fill(
                                          child: _ArchiveSelectionMark(
                                            selected: widget.selected.contains(
                                              entry.identity,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (widget.showChrome) ...[
                              const SizedBox(height: 12),
                              Center(
                                child: SizedBox(
                                  width: 154,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      AppText(
                                        item.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          height: 1.4,
                                        ),
                                      ),
                                      AppText(
                                        entry.detailLine,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Keep only the crest and its two neighbours mounted as actual image widgets.
class _LazyArchiveCover extends StatefulWidget {
  const _LazyArchiveCover({
    required this.entry,
    required this.pose,
    required this.index,
    required this.width,
    required this.height,
    required this.reduced,
  });
  final ArchiveShelfEntry entry;
  final _WavePose pose;
  final int index;
  final double width, height;
  final bool reduced;
  @override
  State<_LazyArchiveCover> createState() => _LazyArchiveCoverState();
}

class _LazyArchiveCoverState extends State<_LazyArchiveCover> {
  bool get _near => (widget.pose.focus.round() - widget.index).abs() <= 1;
  bool get _warm => (widget.pose.focus.round() - widget.index).abs() <= 2;
  late bool _lastNear, _lastWarm;
  Object? _warming;

  @override
  void initState() {
    super.initState();
    _lastNear = _near;
    _lastWarm = _warm;
    widget.pose.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _prewarm();
  }

  void _prewarm() {
    final item = widget.entry.item;
    if (!_warm || item.cover.isEmpty || !TickerMode.valuesOf(context).enabled) {
      return;
    }
    final key = (widget.entry.identity, item.cover, widget.width);
    if (_warming == key) return;
    _warming = key;
    unawaited(() async {
      await precacheShelfCover(context, item.cover, widget.width);
      if (!mounted || !_warm || _warming != key) return;
    }());
  }

  @override
  void didUpdateWidget(_LazyArchiveCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pose != widget.pose) {
      oldWidget.pose.removeListener(_changed);
      widget.pose.addListener(_changed);
    }
    _lastNear = _near;
    _lastWarm = _warm;
    _prewarm();
  }

  void _changed() {
    if (_warm != _lastWarm) {
      _lastWarm = _warm;
      if (_warm) {
        _prewarm();
      } else {
        _warming = null;
      }
    }
    if (_near == _lastNear) return;
    setState(() {
      _lastNear = _near;
    });
  }

  @override
  void dispose() {
    widget.pose.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !_near
      ? const SizedBox.expand()
      : Align(
          alignment: Alignment.topCenter,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations:
                  widget.reduced || MediaQuery.disableAnimationsOf(context),
            ),
            child: TickerMode(
              enabled: _near,
              child: ShelfCoverImage(
                key: ValueKey(
                  'archive-cover-image-${widget.entry.identity}-${widget.index}',
                ),
                item: widget.entry.item,
                width: widget.width,
                height: widget.height,
                radius: ArchiveDesign.coverRadius,
                decodeWidth: shelfCoverDecodeWidth(
                  widget.width,
                  MediaQuery.devicePixelRatioOf(context),
                ),
              ),
            ),
          ),
        );
}

class _ArchiveSnapPhysics extends ScrollPhysics {
  const _ArchiveSnapPhysics({
    required this.pose,
    super.parent = const ClampingScrollPhysics(),
  });
  final _WavePose pose;
  @override
  _ArchiveSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _ArchiveSnapPhysics(pose: pose, parent: buildParent(ancestor));
  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    // Preserve fractional focus during layout instead of jumping a frame later.
    if (!oldPosition.hasViewportDimension ||
        oldPosition.viewportDimension <= 0) {
      return newPosition.pixels.clamp(
        newPosition.minScrollExtent,
        newPosition.maxScrollExtent,
      );
    }
    // Infinite extents keep extentBefore/After unchanged, so the framework's
    // last metrics can hold old pixels. Use live pixels with the old pitch.
    final focus =
        newPosition.pixels / _WavePose.pitchFor(oldPosition.viewportDimension);
    if (!isScrolling &&
        oldPosition.viewportDimension != newPosition.viewportDimension) {
      pose.holdLayoutFocus = true;
    }
    return (focus * _WavePose.pitchFor(newPosition.viewportDimension)).clamp(
      newPosition.minScrollExtent,
      newPosition.maxScrollExtent,
    );
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (pose.holdLayoutFocus && velocity == 0) {
      pose.holdLayoutFocus = false;
      return null;
    }
    pose.holdLayoutFocus = false;
    if (position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    final pitch = _WavePose.pitchFor(position.viewportDimension);
    final simulation = ArchiveScrollSimulation(
      position: position.pixels,
      velocity: velocity,
      pitch: pitch,
      minimumVelocity: minFlingVelocity,
      tolerance: toleranceFor(position),
    );
    if ((simulation.target - position.pixels).abs() < .01 && velocity == 0) {
      return null;
    }
    return simulation;
  }
}

class _WavePose extends ChangeNotifier {
  _WavePose(this._count, this.logicalFocus, this.entrance, {required bool fill})
    : _repeatFill = fill;
  final Animation<double> entrance;
  int _count;
  bool _repeatFill;
  bool get repeatFill => _repeatFill;
  set repeatFill(bool value) {
    if (_repeatFill == value) return;
    _repeatFill = value;
    revision++;
  }

  int revision = 0;
  int get count => _count;
  set count(int value) {
    if (_count == value) return;
    _count = value;
    revision++;
  }

  double logicalFocus;
  double viewport = 340, pitch = pitchFor(340);
  bool _configured = false;
  int edgeSlots = 15;
  bool holdLayoutFocus = false;
  void inkChanged() {
    revision++;
    notifyListeners();
  }

  double inkStart(int index) => ((index - focus + 8) / 24).clamp(0.0, .65);
  double inkProgress(int index) => Interval(
    inkStart(index),
    inkStart(index) + .35,
    curve: Curves.easeOutCubic,
  ).transform(entrance.value.clamp(0.0, 1.0));
  double loadingLift(int index) => entrance.value >= 1
      ? 0
      : archiveLoadingLift(
          index - focus,
          SchedulerBinding.instance.currentSystemFrameTimeStamp,
          1 - inkProgress(index),
        );
  double get focus => count < 2
      ? 0
      : repeatFill
      ? edgeSlots + logicalFocus % count
      : logicalFocus;
  int get poolCount => count < 2 || !repeatFill ? count : count + edgeSlots * 2;
  int bookIndex(int slot) => count < 2
      ? 0
      : repeatFill
      ? (slot - edgeSlots) % count
      : slot.clamp(0, count - 1);
  int logicalLane(int slot) => count < 2
      ? 0
      : repeatFill
      ? (logicalFocus / count).floor() * count + slot - edgeSlots
      : slot.clamp(0, count - 1);
  static const depthX = ArchiveShelfGeometry.depthX;
  static const depthY = ArchiveShelfGeometry.depthY;
  static const radius = 1.48;
  static double spineFor(double width) => ArchiveShelfGeometry.spineFor(width);
  static double pitchFor(double width) => ArchiveShelfGeometry.pitchFor(width);
  static double coverFor(double width) => ArchiveShelfGeometry.coverFor(width);
  static double footprint(double spine, double cover) =>
      ArchiveShelfGeometry.footprint(spine, cover);
  static double pullDistance(double cover) =>
      ArchiveShelfGeometry.pullDistance(cover);
  static double baseY(double cover, double height) =>
      ArchiveShelfGeometry.baseY(cover, height);
  void configure(double width, double nextPitch) {
    if (_configured && viewport == width && pitch == nextPitch) return;
    _configured = true;
    viewport = width;
    pitch = nextPitch;
    final cover = coverFor(width);
    edgeSlots =
        ((width / 2 +
                    footprint(spineFor(width), cover) +
                    pullDistance(cover) * depthX) /
                pitch)
            .ceil() +
        2;
    revision++;
  }

  void move(double next, {bool notify = true}) {
    if (count < 2) next = 0;
    if (!repeatFill && count > 1) next = next.clamp(0, count - 1).toDouble();
    if ((logicalFocus - next).abs() < .000001) return;
    logicalFocus = next;
    revision++;
    if (notify) notifyListeners();
  }

  double railY(int slot) {
    return ArchiveShelfGeometry.railY(slot - focus);
  }

  double weight(int index) {
    final distance = (index - focus).abs();
    if (distance >= radius) return 0;
    final value = math.cos(distance / radius * math.pi / 2);
    // The loading skeleton already shows this crest. Keep its pose throughout
    // the ink handoff instead of dropping the selected book then lifting it.
    return value * value;
  }
}

class _ShelfRow extends MultiChildRenderObjectWidget {
  const _ShelfRow({
    required this.offset,
    required this.pose,
    required this.spine,
    required this.cover,
    required this.height,
    required this.dark,
    required super.children,
  });
  final ViewportOffset offset;
  final _WavePose pose;
  final double spine, cover, height;
  final bool dark;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      ArchiveShelfSceneRender._(offset, pose, spine, cover, height, dark);
  @override
  void updateRenderObject(
    BuildContext context,
    ArchiveShelfSceneRender renderObject,
  ) => renderObject._update(offset, pose, spine, cover, height, dark);
}

class _ShelfParentData extends ContainerBoxParentData<RenderBox> {}

/// Parallel x-separated solids have a fixed occlusion order. Sorting by lift or
/// selected index causes impossible intersections and mid-scroll order pops.
class ArchiveShelfSceneRender extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _ShelfParentData> {
  ArchiveShelfSceneRender._(
    this._scrollOffset,
    this._pose,
    this._spine,
    this._cover,
    this._height,
    this._dark,
  );
  ViewportOffset _scrollOffset;
  _WavePose _pose;
  double _spine, _cover, _height;
  bool _dark;
  final _boxes = <RenderBox>[];
  final _x = <double>[];
  final _clipLayer = LayerHandle<ClipRectLayer>();
  int debugLayoutCount = 0;

  /// Static shadow ink is shared by every translated volume in this scene.
  @visibleForTesting
  int debugFloorShaderBuildCount = 0;
  Path? _floorPath;
  Paint? _floorPaint;

  /// Number of visibility projections, shared by paint and touch.
  @visibleForTesting
  int debugVisibilityCount = 0;
  int _visibleRevision = -1;
  List<int> _visibleSlots = const [];
  double get debugFocus => _pose.logicalFocus;
  int get debugCentreSlot => _pose.focus.round();
  int get debugPoolCount => _pose.poolCount;
  double get debugPitch => _pose.pitch;
  List<int> get debugPaintOrder => _visible;

  Rect get _viewport => Offset.zero & size;
  Offset _offset(int i) =>
      Offset(_x[i] - _pose.focus * _pose.pitch, _pose.railY(i));
  List<int> get _visible {
    if (_visibleRevision == _pose.revision) return _visibleSlots;
    _visibleRevision = _pose.revision;
    debugVisibilityCount++;
    return _visibleSlots = [
      for (var i = 0; i < _boxes.length; i++)
        if (_viewport.overlaps(_boxes[i].paintBounds.shift(_offset(i)))) i,
    ];
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ShelfParentData) {
      child.parentData = _ShelfParentData();
    }
  }

  void _update(
    ViewportOffset offset,
    _WavePose pose,
    double spine,
    double cover,
    double height,
    bool dark,
  ) {
    final geometryChanged =
        _scrollOffset != offset ||
        _pose != pose ||
        _spine != spine ||
        _cover != cover ||
        _height != height;
    final inkChanged = _dark != dark;
    final surfaceChanged = _spine != spine || _cover != cover || inkChanged;
    _scrollOffset = offset;
    if (_pose != pose) {
      if (attached) _pose.removeListener(_changed);
      _pose = pose;
      if (attached) _pose.addListener(_changed);
    }
    _spine = spine;
    _cover = cover;
    _height = height;
    _dark = dark;
    if (surfaceChanged) {
      _floorPath = null;
      _floorPaint = null;
    }
    if (geometryChanged) {
      _visibleRevision = -1;
      markNeedsLayout();
    } else if (inkChanged) {
      markNeedsPaint();
    }
  }

  void _changed() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _pose.addListener(_changed);
  }

  @override
  void detach() {
    _pose.removeListener(_changed);
    super.detach();
  }

  @override
  void performLayout() {
    _visibleRevision = -1;
    size = constraints.biggest;
    _scrollOffset.applyViewportDimension(size.width);
    // A resized viewport may correct its pixels on the first attempt. Accept
    // the new dimensions before deriving the pool's fractional lane.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_scrollOffset.applyContentDimensions(
        _pose.count < 2 || !_pose.repeatFill ? 0 : double.negativeInfinity,
        _pose.count < 2
            ? 0
            : _pose.repeatFill
            ? double.infinity
            : (_pose.count - 1) * _pose.pitch,
      )) {
        break;
      }
    }
    _pose.move(_scrollOffset.pixels / _pose.pitch, notify: false);
    _boxes.clear();
    _x.clear();
    final start =
        _pose.viewport / 2 -
        _WavePose.footprint(_spine, _cover) / 2 +
        _WavePose.pullDistance(_cover) * _WavePose.depthX;
    var child = firstChild;
    while (child != null) {
      child.layout(BoxConstraints.tight(Size(_spine + _cover, size.height)));
      _x.add(start + _boxes.length * _pose.pitch);
      _boxes.add(child);
      child = childAfter(child);
    }
    debugLayoutCount++;
  }

  void _floor(Canvas canvas, Offset offset, List<int> visible) {
    if (_floorPath == null) {
      final depth = Offset(
        _cover * _WavePose.depthX,
        _cover * _WavePose.depthY,
      );
      const tail = Offset(-10, 10);
      final front = Offset(_spine, 1.4);
      _floorPath = Path()
        ..addPolygon([
          Offset.zero,
          front,
          front + depth,
          depth,
          depth + tail,
          tail,
        ], true);
      final ink = _dark ? ArchiveDesign.milk : const Color(0xFF8A806B);
      _floorPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [ink.withValues(alpha: .10), ink.withValues(alpha: 0)],
        ).createShader(_floorPath!.getBounds());
      debugFloorShaderBuildCount++;
    }
    for (final i in visible) {
      final origin =
          offset +
          _offset(i) +
          Offset(0, _WavePose.baseY(_cover, _height) + _height);
      canvas.save();
      canvas.translate(origin.dx, origin.dy);
      canvas.drawPath(_floorPath!, _floorPaint!);
      canvas.restore();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final visible = _visible;
    _clipLayer.layer = context.pushClipRect(
      needsCompositing,
      offset,
      _viewport,
      (context, offset) {
        _floor(context.canvas, offset, visible);
        for (final i in visible) {
          context.paintChild(_boxes[i], offset + _offset(i));
        }
      },
      oldLayer: _clipLayer.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final i in _visible.reversed) {
      if (result.addWithPaintOffset(
        offset: _offset(i),
        position: position,
        hitTest: (result, position) =>
            _boxes[i].hitTest(result, position: position),
      )) {
        return true;
      }
    }
    return false;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = _offset(_boxes.indexOf(child));
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }

  @override
  Rect describeApproximatePaintClip(RenderObject child) => _viewport;

  @override
  void dispose() {
    _clipLayer.layer = null;
    super.dispose();
  }
}

class _BookVolume extends MultiChildRenderObjectWidget {
  const _BookVolume({
    super.key,
    required this.pose,
    required this.index,
    required this.spine,
    required this.cover,
    required this.height,
    required this.dark,
    required this.label,
    required this.direction,
    required this.onTap,
    this.onLongPress,
    required super.children,
  });
  final _WavePose pose;
  final int index;
  final double spine, cover, height;
  final bool dark;
  final String label;
  final TextDirection direction;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      ArchiveBoxDepthRender._(
        pose,
        index,
        spine,
        cover,
        height,
        dark,
        label,
        direction,
        onTap,
        onLongPress,
      );
  @override
  void updateRenderObject(
    BuildContext context,
    ArchiveBoxDepthRender renderObject,
  ) => renderObject._update(
    pose,
    index,
    spine,
    cover,
    height,
    dark,
    label,
    direction,
    onTap,
    onLongPress,
  );
}

class _ArchiveCapHitEntry extends BoxHitTestEntry {
  _ArchiveCapHitEntry(super.target, super.localPosition);
}

/// The top, front and projected side share exactly the same physical vertices.
class ArchiveBoxDepthRender extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _ShelfParentData> {
  ArchiveBoxDepthRender._(
    this._pose,
    this._index,
    this._spine,
    this._cover,
    this._height,
    this._dark,
    this._label,
    this._direction,
    this._onTap,
    this._onLongPress,
  ) {
    _capTap = TapGestureRecognizer(debugOwner: this)
      ..onTap = () {
        _onTap();
      };
    _capLongPress = LongPressGestureRecognizer(debugOwner: this)
      ..onLongPress = () {
        _onLongPress?.call();
      };
  }
  _WavePose _pose;
  int _index;
  double _spine, _cover, _height;
  bool _dark;
  String _label;
  TextDirection _direction;
  VoidCallback _onTap;
  VoidCallback? _onLongPress;
  late final TapGestureRecognizer _capTap;
  late final LongPressGestureRecognizer _capLongPress;
  final _spineLayer = LayerHandle<TransformLayer>();
  final _coverLayer = LayerHandle<TransformLayer>();
  int debugLayoutCount = 0;

  /// Translation does not change a book's cap geometry or gradient.
  @visibleForTesting
  int debugTopShaderBuildCount = 0;
  Path? _capPath;
  Paint? _capFill, _capStroke;

  /// Culling, paint and accessibility reuse one exact pose per wave revision.
  @visibleForTesting
  int debugGeometryCount = 0;
  int _geometryRevision = -1;
  Offset _resolvedOrigin = Offset.zero;
  Matrix4? _resolvedBase, _resolvedCover;
  Path? _resolvedTop;
  double get debugOpenFraction => _pose.weight(_index);
  bool get debugSelected => _pose.focus.round() == _index;
  Matrix4 get debugTransform => _coverTransform.clone();
  Matrix4 get debugSpineTransform => _base.clone();
  double get debugFootprint => _WavePose.footprint(_spine, _cover);

  /// Local-space centre of the projected top cap, used by the hit-test
  /// regression to prove that long-press also starts inside that face.
  @visibleForTesting
  Offset get debugCapCentre => _topPath.getBounds().center;

  Offset get _origin {
    if (_geometryRevision != _pose.revision) {
      _geometryRevision = _pose.revision;
      debugGeometryCount++;
      _resolvedBase = null;
      _resolvedCover = null;
      _resolvedTop = null;
      _resolvedOrigin =
          ArchiveShelfGeometry.origin(_cover, _height, debugOpenFraction) +
          Offset(0, _pose.loadingLift(_index));
    }
    return _resolvedOrigin;
  }

  Matrix4 get _base {
    final origin = _origin;
    return _resolvedBase ??= Matrix4.identity()
      ..setEntry(0, 2, _WavePose.depthX)
      ..setEntry(1, 2, _WavePose.depthY)
      ..setEntry(1, 0, .10)
      ..setEntry(0, 3, origin.dx)
      ..setEntry(1, 3, origin.dy);
  }

  Matrix4 get _coverTransform {
    final origin = _origin;
    return _resolvedCover ??= Matrix4.identity()
      ..setEntry(0, 0, _WavePose.depthX)
      ..setEntry(1, 0, _WavePose.depthY)
      ..setEntry(0, 3, origin.dx + _spine)
      ..setEntry(1, 3, origin.dy + _spine * .10);
  }

  Path get _topPath {
    final origin = _origin;
    final front = Offset(_spine, _spine * .10);
    final depth = Offset(_cover * _WavePose.depthX, _cover * _WavePose.depthY);
    return _resolvedTop ??= Path()
      ..addPolygon([
        origin,
        origin + front,
        origin + front + depth,
        origin + depth,
      ], true);
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ShelfParentData) {
      child.parentData = _ShelfParentData();
    }
  }

  void _update(
    _WavePose pose,
    int index,
    double spine,
    double cover,
    double height,
    bool dark,
    String label,
    TextDirection direction,
    VoidCallback onTap,
    VoidCallback? onLongPress,
  ) {
    _geometryRevision = -1;
    if (_spine != spine || _cover != cover || _dark != dark) {
      _capPath = null;
      _capFill = null;
      _capStroke = null;
    }
    if (_pose != pose) {
      if (attached) _pose.removeListener(_changed);
      _pose = pose;
      if (attached) _pose.addListener(_changed);
    }
    if (_spine != spine || _cover != cover || _height != height) {
      _spine = spine;
      _cover = cover;
      _height = height;
      markNeedsLayout();
    }
    _index = index;
    _dark = dark;
    _label = label;
    _direction = direction;
    _onTap = onTap;
    _onLongPress = onLongPress;
    _changed();
  }

  void _changed() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _pose.addListener(_changed);
  }

  @override
  void detach() {
    _pose.removeListener(_changed);
    _spineLayer.layer = null;
    _coverLayer.layer = null;
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    firstChild!.layout(BoxConstraints.tight(Size(_spine, _height)));
    lastChild!.layout(BoxConstraints.tight(Size(_cover, _height)));
    debugLayoutCount++;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _coverLayer.layer = context.pushTransform(
      needsCompositing,
      offset,
      _coverTransform,
      (context, offset) => context.paintChild(lastChild!, offset),
      oldLayer: _coverLayer.layer,
    );
    if (_capPath == null) {
      final front = Offset(_spine, _spine * .10);
      final depth = Offset(
        _cover * _WavePose.depthX,
        _cover * _WavePose.depthY,
      );
      _capPath = Path()
        ..addPolygon([Offset.zero, front, front + depth, depth], true);
      _capFill = Paint()
        ..shader = LinearGradient(
          colors: _dark
              ? [ArchiveDesign.darkRaisedHigh, ArchiveDesign.darkRaised]
              : [const Color(0xFFE3DFD3), ArchiveDesign.milk],
        ).createShader(_capPath!.getBounds());
      _capStroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .4
        ..color = (_dark ? ArchiveDesign.darkMilk : const Color(0xFF9A927F))
            .withValues(alpha: .24);
      debugTopShaderBuildCount++;
    }
    final canvas = context.canvas;
    final origin = offset + _origin;
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.drawPath(_capPath!, _capFill!);
    canvas.drawPath(_capPath!, _capStroke!);
    canvas.restore();
    _spineLayer.layer = context.pushTransform(
      needsCompositing,
      offset,
      _base,
      (context, offset) => context.paintChild(firstChild!, offset),
      oldLayer: _spineLayer.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintTransform(
        transform: _base,
        position: position,
        hitTest: (result, position) =>
            firstChild!.hitTest(result, position: position),
      ) ||
      result.addWithPaintTransform(
        transform: _coverTransform,
        position: position,
        hitTest: (result, position) =>
            lastChild!.hitTest(result, position: position),
      );

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!paintBounds.contains(position)) return false;
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    if (_topPath.contains(position)) {
      result.add(_ArchiveCapHitEntry(this, position));
      return true;
    }
    return false;
  }

  @override
  void handleEvent(PointerEvent event, covariant BoxHitTestEntry entry) {
    if (entry is _ArchiveCapHitEntry && event is PointerDownEvent) {
      _capTap.addPointer(event);
      if (_onLongPress != null) _capLongPress.addPointer(event);
    }
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(child == firstChild ? _base : _coverTransform);

  @override
  Rect get paintBounds => semanticBounds.inflate(.5);

  @override
  Rect get semanticBounds {
    // Exact projected solid bounds without allocating matrices/paths for every
    // offscreen volume during each culling pass.
    final origin = _origin;
    return Rect.fromLTRB(
      origin.dx,
      origin.dy + _cover * _WavePose.depthY,
      origin.dx + debugFootprint,
      origin.dy + _height + _spine * .10,
    );
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.isSemanticBoundary = true;
    config.isButton = true;
    config.isSelected = debugSelected;
    config.label = _label;
    config.textDirection = _direction;
    config.onTap = _onTap;
    config.hint = debugSelected ? '中心档案，点按打开书籍' : '点按滚动到中心';
  }

  @override
  void dispose() {
    _capTap.dispose();
    _capLongPress.dispose();
    _spineLayer.layer = null;
    _coverLayer.layer = null;
    super.dispose();
  }
}
