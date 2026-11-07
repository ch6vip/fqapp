import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../services/ai_reading/ai_feedback.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/settings/settings_widgets.dart';

/// AI 修改详情里的一排反馈动作：改得好、不该改、改错了。
///
/// 只负责动作，不展示大段说明。正向反馈会建立持久显示保护：
/// * 「改得好」默认锁定这次改法；与旧认可改法重叠时要求确认后替代，
///   与「不该改」的原文锁定重叠时直接拒绝，绝不静默覆盖负保护。
/// * 「不该改」只要与任何生效保护相交就提示冲突。
class AiEditFeedbackActions extends StatelessWidget {
  const AiEditFeedbackActions({
    super.key,
    required this.bookId,
    required this.chapterId,
    required this.snapshot,
    required this.span,
    this.onChanged,
  });

  final String bookId;
  final String chapterId;
  final AiChapterSnapshot snapshot;
  final AiEditSpan span;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) => _AiEditFeedbackActionsBody(
    bookId: bookId,
    chapterId: chapterId,
    snapshot: snapshot,
    span: span,
    onChanged: onChanged,
  );
}

class _AiEditFeedbackActionsBody extends StatefulWidget {
  const _AiEditFeedbackActionsBody({
    required this.bookId,
    required this.chapterId,
    required this.snapshot,
    required this.span,
    this.onChanged,
  });

  final String bookId;
  final String chapterId;
  final AiChapterSnapshot snapshot;
  final AiEditSpan span;
  final VoidCallback? onChanged;

  @override
  State<_AiEditFeedbackActionsBody> createState() =>
      _AiEditFeedbackActionsBodyState();
}

class _AiEditFeedbackActionsBodyState
    extends State<_AiEditFeedbackActionsBody> {
  bool _busy = false;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<List<AiFeedbackProtection>> _overlapping() async {
    final protections = await AiFeedbackService.instance.activeProtections(
      bookId: widget.bookId,
      chapterId: widget.chapterId,
      canonicalVersion: widget.snapshot.canonicalVersion,
      canonicalHash: widget.snapshot.canonicalHash,
    );
    return [
      for (final protection in protections)
        if (protection.intersects(
          widget.span.sourceStart,
          widget.span.sourceEnd,
        ))
          protection,
    ];
  }

  Future<void> _run(
    Future<void> Function() action, {
    required String success,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      widget.onChanged?.call();
      _snack(success);
    } on AiFeedbackConflict catch (error) {
      _snack(error.message);
    } catch (error) {
      _snack('保存反馈失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _good() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final overlaps = await _overlapping();
      if (!mounted) return;
      if (overlaps.any((p) => p.isKeepOriginal)) {
        _snack('此处已锁定原文，不能改成认可改法');
        return;
      }
      var supersede = false;
      if (overlaps.isNotEmpty) {
        final confirmed = await showSettingsConfirmDialog(
          context: context,
          title: '用这次改法替代旧认可改法？',
          message:
              '这段原文已经有 ${overlaps.length} 条认可改法保护。'
              '确认后旧记录会被标为「已被替代」，显示锁定为这次的改法。',
          confirmLabel: '替代',
        );
        if (!confirmed || !mounted) return;
        supersede = true;
      }
      await AiFeedbackService.instance.addFromEdit(
        bookId: widget.bookId,
        chapterId: widget.chapterId,
        snapshot: widget.snapshot,
        span: widget.span,
        kind: AiFeedbackKind.good,
        supersedeOverlappingGood: supersede,
      );
      widget.onChanged?.call();
      _snack('已保存反馈：改得好，此处已锁定认可改法');
    } on AiFeedbackConflict catch (error) {
      _snack(error.message);
    } catch (error) {
      _snack('保存反馈失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shouldNotChange() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final overlaps = await _overlapping();
      if (!mounted) return;
      if (overlaps.isNotEmpty) {
        _snack('此处已有生效保护，请先处理冲突');
        return;
      }
      await AiFeedbackService.instance.addFromEdit(
        bookId: widget.bookId,
        chapterId: widget.chapterId,
        snapshot: widget.snapshot,
        span: widget.span,
        kind: AiFeedbackKind.shouldNotChange,
      );
      widget.onChanged?.call();
      _snack('已保存反馈：不该改，此处已锁定原文');
    } on AiFeedbackConflict catch (error) {
      _snack(error.message);
    } catch (error) {
      _snack('保存反馈失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _wrongChange() => _run(
    () => AiFeedbackService.instance.addFromEdit(
      bookId: widget.bookId,
      chapterId: widget.chapterId,
      snapshot: widget.snapshot,
      span: widget.span,
      kind: AiFeedbackKind.wrongChange,
    ),
    success: '已保存反馈：改错了',
  );

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final style = OutlinedButton.styleFrom(
      foregroundColor: palette.ink,
      side: BorderSide(color: palette.line, width: 0.8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      minimumSize: const Size(0, 40),
      visualDensity: VisualDensity.compact,
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LinearProgressIndicator(
              minHeight: 2,
              color: palette.accentText,
              backgroundColor: palette.line,
            ),
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('ai_feedback_should_not_change'),
                onPressed: _busy ? null : _shouldNotChange,
                style: style,
                icon: const Icon(LucideIcons.ban, size: 16),
                label: const Text('不该改'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('ai_feedback_wrong_change'),
                onPressed: _busy ? null : _wrongChange,
                style: style,
                icon: const Icon(LucideIcons.pencil, size: 16),
                label: const Text('改错了'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('ai_feedback_good'),
                onPressed: _busy ? null : _good,
                style: style,
                icon: const Icon(LucideIcons.thumbs_up, size: 16),
                label: const Text('改得好'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
