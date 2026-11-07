import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/ai_reading/ai_feedback.dart';
import '../../services/ai_reading/ai_models.dart';
import '../../widgets/ai_reading/ai_ui.dart';
import '../../services/reader_preferences.dart';
import '../../widgets/reader/reader_theme.dart';

Future<void> showAiEditDetailSheet(
  BuildContext context, {
  required String bookId,
  required String chapterId,
  required AiChapterSnapshot snapshot,
  required AiEditSpan span,
  required ReaderThemePreset preset,
  VoidCallback? onChanged,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _AiEditDetailSheet(
      bookId: bookId,
      chapterId: chapterId,
      snapshot: snapshot,
      span: span,
      preset: preset,
      onChanged: onChanged,
    ),
  );
}

class _AiEditDetailSheet extends StatefulWidget {
  const _AiEditDetailSheet({
    required this.bookId,
    required this.chapterId,
    required this.snapshot,
    required this.span,
    required this.preset,
    this.onChanged,
  });

  final String bookId;
  final String chapterId;
  final AiChapterSnapshot snapshot;
  final AiEditSpan span;
  final ReaderThemePreset preset;
  final VoidCallback? onChanged;

  @override
  State<_AiEditDetailSheet> createState() => _AiEditDetailSheetState();
}

class _AiEditDetailSheetState extends State<_AiEditDetailSheet> {
  bool _busy = false;
  String? _message;

  Future<void> _feedback(AiFeedbackKind kind, {bool supersede = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await AiFeedbackService.instance.addFromEdit(
        bookId: widget.bookId,
        chapterId: widget.chapterId,
        snapshot: widget.snapshot,
        span: widget.span,
        kind: kind,
        supersedeOverlappingGood: supersede,
      );
      widget.onChanged?.call();
      if (!mounted) return;
      Navigator.pop(context);
    } on AiFeedbackConflict catch (error) {
      if (!mounted) return;
      if (kind == AiFeedbackKind.good && !supersede) {
        final replace = await _confirmReplace();
        if (replace && mounted) {
          setState(() => _busy = false);
          await _feedback(kind, supersede: true);
        }
      } else {
        setState(() => _message = error.message);
      }
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmReplace() async {
    final preset = widget.preset;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: preset.panelColor,
        title: Text('替代旧认可改法？', style: TextStyle(color: preset.textColor)),
        content: Text(
          '这里已有一条「改得好」锁定。继续会把旧改法标为历史，改用当前这条。',
          style: TextStyle(color: preset.mutedTextColor, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('替代'),
          ),
        ],
      ),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final span = widget.span;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.78,
      ),
      decoration: BoxDecoration(
        color: preset.panelColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: ListView(
          shrinkWrap: true,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'AI 修改详情',
                    style: TextStyle(
                      color: preset.textColor,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(LucideIcons.x, color: preset.mutedTextColor),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                AiStatusPill(label: span.category),
                if (span.approved && span.category != '认可改法') ...[
                  const SizedBox(width: 8),
                  const AiStatusPill(label: '认可改法', tone: AiStatusTone.ok),
                ],
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '原文',
              style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
            ),
            const SizedBox(height: 4),
            SelectableText(
              span.original,
              style: TextStyle(
                color: preset.textColor,
                fontSize: 15,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'AI 改为',
              style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
            ),
            const SizedBox(height: 4),
            SelectableText(
              span.replacement.isEmpty ? '（删除）' : span.replacement,
              style: TextStyle(
                color: preset.accentColor,
                fontSize: 15,
                height: 1.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '当前显示',
              style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
            ),
            const SizedBox(height: 4),
            SelectableText(
              span.replacement.isEmpty ? '（删除）' : span.replacement,
              style: TextStyle(
                color: preset.textColor,
                fontSize: 15,
                height: 1.5,
              ),
            ),
            if (span.reason.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '理由',
                style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                span.reason,
                style: TextStyle(
                  color: preset.textColor,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(
                _message!,
                style: TextStyle(color: preset.accentColor, fontSize: 12.5),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _feedback(AiFeedbackKind.shouldNotChange),
                    child: const Text('不该改'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _feedback(AiFeedbackKind.wrongChange),
                    child: const Text('改错了'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _feedback(AiFeedbackKind.good),
                    child: const Text('改得好'),
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
