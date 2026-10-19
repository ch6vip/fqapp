import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import 'home_design.dart';

/// Filter and sort model for the home recommendation feed.
@immutable
class HomeFeedFilter {
  final double minScore;
  final String status; // 'all' | 'finished' | 'serial'
  final String sort; // 'default' | 'score'

  const HomeFeedFilter({
    this.minScore = 0.0,
    this.status = 'all',
    this.sort = 'default',
  });

  bool get isActive => minScore > 0 || status != 'all' || sort != 'default';

  HomeFeedFilter copyWith({double? minScore, String? status, String? sort}) {
    return HomeFeedFilter(
      minScore: minScore ?? this.minScore,
      status: status ?? this.status,
      sort: sort ?? this.sort,
    );
  }

  List<MediaItem> apply(List<MediaItem> items) {
    if (!isActive) return items;
    var list = items;
    if (minScore > 0) {
      list = list.where((item) => (item.score ?? 0.0) >= minScore).toList();
    }
    if (status == 'finished' || status == 'serial') {
      final wanted = status == 'finished'
          ? _HomeFeedStatus.finished
          : _HomeFeedStatus.serial;
      list = list.where((item) => _statusOf(item) == wanted).toList();
    }
    if (sort == 'score') {
      list = [...list]
        ..sort((a, b) => (b.score ?? 0.0).compareTo(a.score ?? 0.0));
    }
    return list;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HomeFeedFilter &&
          runtimeType == other.runtimeType &&
          minScore == other.minScore &&
          status == other.status &&
          sort == other.sort;

  @override
  int get hashCode => Object.hash(minScore, status, sort);
}

enum _HomeFeedStatus { finished, serial, unknown }

final _serialStatusPattern = RegExp(
  r'未完结|连载中?|更新中|更新至|更新到|连载',
  caseSensitive: false,
);
final _finishedStatusPattern = RegExp(
  r'已完结|完结|完本|全本|全集|全\d+集',
  caseSensitive: false,
);

/// Reads only explicit status evidence from the episode/tag copy.
///
/// A bare chapter or episode count says nothing about whether a work is still
/// being serialized, so it stays [unknown] instead of being guessed as
/// "连载中". The serial pattern runs first because "未完结" contains "完".
_HomeFeedStatus _statusOf(MediaItem item) {
  final evidence = '${item.ep} ${item.tag?.text ?? ''}'.trim();
  if (evidence.isEmpty) return _HomeFeedStatus.unknown;
  if (_serialStatusPattern.hasMatch(evidence)) return _HomeFeedStatus.serial;
  if (_finishedStatusPattern.hasMatch(evidence)) {
    return _HomeFeedStatus.finished;
  }
  return _HomeFeedStatus.unknown;
}

/// Quiet text action shown at the end of the recommendation heading.
class HomeFilterButton extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;

  const HomeFilterButton({
    super.key,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final accent = palette.eink ? Colors.black : HomePalette.accent;

    return Semantics(
      button: true,
      label: active ? '筛选，已启用' : '筛选',
      child: InkWell(
        key: const Key('home_section_filter_button'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        splashColor: accent.withValues(alpha: 0.07),
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.sliders_horizontal,
                size: 15,
                color: active ? accent : palette.muted,
              ),
              const SizedBox(width: 5),
              Text(
                '筛选',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? accent : palette.muted,
                ),
              ),
              if (active) ...[
                const SizedBox(width: 4),
                Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Only rendered while a filter is active, so the default feed stays quiet.
class HomeFilterSummary extends StatelessWidget {
  final HomeFeedFilter filter;
  final VoidCallback onClear;
  final String scopeLabel;

  const HomeFilterSummary({
    super.key,
    required this.filter,
    required this.onClear,
    this.scopeLabel = '为你推荐',
  });

  @override
  Widget build(BuildContext context) {
    if (!filter.isActive) return const SizedBox.shrink();
    final palette = HomePalette.of(context);
    final labels = <String>[
      if (filter.minScore > 0) '${filter.minScore.toStringAsFixed(1)} 分以上',
      if (filter.status == 'finished') '已完结',
      if (filter.status == 'serial') '连载中',
      if (filter.sort == 'score') '评分优先',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HomeSpace.gutter,
        0,
        HomeSpace.gutter,
        12,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
        decoration: BoxDecoration(
          color: palette.soft,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              LucideIcons.sliders_horizontal,
              size: 14,
              color: palette.accentText,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$scopeLabel · ${labels.join(' · ')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HomeType.meta.copyWith(
                  fontSize: 11.5,
                  color: palette.secondary,
                ),
              ),
            ),
            InkWell(
              onTap: onClear,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(
                  '清除',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: palette.accentText,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet for score, status and sort choices.
Future<void> showHomeFilterSheet(
  BuildContext context, {
  required HomeFeedFilter current,
  required ValueChanged<HomeFeedFilter> onApply,
  String scopeLabel = '为你推荐',
}) async {
  final palette = HomePalette.of(context);

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: palette.surface,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _FilterSheetContent(
      initialFilter: current,
      palette: palette,
      onApply: onApply,
      scopeLabel: scopeLabel,
    ),
  );
}

class _FilterSheetContent extends StatefulWidget {
  final HomeFeedFilter initialFilter;
  final HomePalette palette;
  final ValueChanged<HomeFeedFilter> onApply;
  final String scopeLabel;

  const _FilterSheetContent({
    required this.initialFilter,
    required this.palette,
    required this.onApply,
    required this.scopeLabel,
  });

  @override
  State<_FilterSheetContent> createState() => _FilterSheetContentState();
}

class _FilterSheetContentState extends State<_FilterSheetContent> {
  late HomeFeedFilter _filter = widget.initialFilter;

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final accent = palette.eink ? Colors.black : HomePalette.accent;

    Widget sectionTitle(String title) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 10),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: palette.secondary,
        ),
      ),
    );

    Widget choice({
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? accent : palette.soft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? Colors.white : palette.ink,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '筛选推荐',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: palette.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '只筛选「${widget.scopeLabel}」列表；上方焦点区保持编辑精选。',
              style: TextStyle(fontSize: 12.5, color: palette.muted),
            ),
            sectionTitle('评分'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                choice(
                  label: '不限',
                  selected: _filter.minScore == 0.0,
                  onTap: () =>
                      setState(() => _filter = _filter.copyWith(minScore: 0.0)),
                ),
                choice(
                  label: '8.0 分及以上',
                  selected: _filter.minScore == 8.0,
                  onTap: () =>
                      setState(() => _filter = _filter.copyWith(minScore: 8.0)),
                ),
                choice(
                  label: '8.5 分及以上',
                  selected: _filter.minScore == 8.5,
                  onTap: () =>
                      setState(() => _filter = _filter.copyWith(minScore: 8.5)),
                ),
                choice(
                  label: '9.0 分及以上',
                  selected: _filter.minScore == 9.0,
                  onTap: () =>
                      setState(() => _filter = _filter.copyWith(minScore: 9.0)),
                ),
              ],
            ),
            sectionTitle('状态'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                choice(
                  label: '全部',
                  selected: _filter.status == 'all',
                  onTap: () =>
                      setState(() => _filter = _filter.copyWith(status: 'all')),
                ),
                choice(
                  label: '已完结',
                  selected: _filter.status == 'finished',
                  onTap: () => setState(
                    () => _filter = _filter.copyWith(status: 'finished'),
                  ),
                ),
                choice(
                  label: '连载中',
                  selected: _filter.status == 'serial',
                  onTap: () => setState(
                    () => _filter = _filter.copyWith(status: 'serial'),
                  ),
                ),
              ],
            ),
            sectionTitle('排序'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                choice(
                  label: '默认推荐',
                  selected: _filter.sort == 'default',
                  onTap: () => setState(
                    () => _filter = _filter.copyWith(sort: 'default'),
                  ),
                ),
                choice(
                  label: '评分从高到低',
                  selected: _filter.sort == 'score',
                  onTap: () =>
                      setState(() => _filter = _filter.copyWith(sort: 'score')),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() => _filter = const HomeFeedFilter());
                    },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      side: BorderSide(color: palette.line, width: 0.8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      '重置',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: () {
                      widget.onApply(_filter);
                      Navigator.pop(context);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      '确定',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
