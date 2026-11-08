import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../services/ai_reading/ai_feedback.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../widgets/ai_reading/ai_ui.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/home/home_sheet.dart';
import 'ai_feedback_widgets.dart';

/// 长按选中正文后的「漏改了」面板。提交成功返回 true。
///
/// 选区必须是本章正文里的一个非空、单段落区间；跨段或为空时直接禁用提交，
/// 不把无效锚点交给服务层。
Future<bool> showAiMissedSheet(
  BuildContext context, {
  required String bookId,
  required String chapterId,
  required AiChapterSnapshot snapshot,
  required int sourceStart,
  required int sourceEnd,
  VoidCallback? onChanged,
}) async {
  final palette = HomePalette.of(context);
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: homeSheetColor(palette),
    clipBehavior: Clip.antiAlias,
    shape: homeSheetShape(palette, top: HomeSheetFrame.radius),
    builder: (_) => AiMissedSheet(
      bookId: bookId,
      chapterId: chapterId,
      snapshot: snapshot,
      sourceStart: sourceStart,
      sourceEnd: sourceEnd,
      onChanged: onChanged,
    ),
  );
  return result ?? false;
}

class AiMissedSheet extends StatefulWidget {
  const AiMissedSheet({
    super.key,
    required this.bookId,
    required this.chapterId,
    required this.snapshot,
    required this.sourceStart,
    required this.sourceEnd,
    this.onChanged,
  });

  final String bookId;
  final String chapterId;
  final AiChapterSnapshot snapshot;
  final int sourceStart;
  final int sourceEnd;
  final VoidCallback? onChanged;

  @override
  State<AiMissedSheet> createState() => _AiMissedSheetState();
}

class _AiMissedSheetState extends State<AiMissedSheet> {
  final _expected = TextEditingController();
  final _comment = TextEditingController();
  bool _busy = false;
  String? _submitError;
  late final String? _selectionError;
  late final String _snippet;

  @override
  void initState() {
    super.initState();
    _selectionError = _validateSelection();
    _snippet = _readSnippet();
  }

  @override
  void dispose() {
    _expected.dispose();
    _comment.dispose();
    super.dispose();
  }

  String? _validateSelection() {
    final snapshot = widget.snapshot;
    if (widget.sourceEnd <= widget.sourceStart) return '还没有选中文字';
    if (widget.sourceStart < 0 ||
        widget.sourceEnd > snapshot.requestText.length) {
      return '选区超出本章正文';
    }
    final paragraph = snapshot.paragraphIndexAt(widget.sourceStart);
    if (paragraph == null) return '选区不在正文段落里';
    if (widget.sourceEnd > snapshot.paragraphEnd(paragraph)) {
      return '漏改了只能标在同一个段落内';
    }
    final endParagraph = snapshot.paragraphIndexAt(
      widget.sourceEnd,
      endBias: true,
    );
    if (endParagraph != paragraph) return '选区跨了两个段落';
    return null;
  }

  String _readSnippet() {
    final snapshot = widget.snapshot;
    final length = snapshot.requestText.length;
    final start = widget.sourceStart.clamp(0, length);
    final end = widget.sourceEnd.clamp(start, length);
    if (end <= start) return '';
    return snapshot.requestText.substring(start, end);
  }

  Future<void> _submit() async {
    if (_busy || _selectionError != null) return;
    setState(() {
      _busy = true;
      _submitError = null;
    });
    try {
      final expected = _expected.text.trim();
      await AiFeedbackService.instance.addMissedSelection(
        bookId: widget.bookId,
        chapterId: widget.chapterId,
        snapshot: widget.snapshot,
        sourceStart: widget.sourceStart,
        sourceEnd: widget.sourceEnd,
        comment: _comment.text.trim(),
        expectedText: expected.isEmpty ? null : expected,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已保存「漏改了」反馈')));
      widget.onChanged?.call();
      Navigator.of(context).pop(true);
    } on AiFeedbackConflict catch (error) {
      if (mounted) setState(() => _submitError = error.message);
    } catch (error) {
      if (mounted) setState(() => _submitError = '提交失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final canSubmit = _selectionError == null && !_busy;
    return HomeSheetFrame(
      title: '漏改了',
      maxHeightFactor: 0.9,
      children: [
        Text(
          _selectionError ?? '已选中 ${_snippet.characters.length} 个字',
          style: TextStyle(fontSize: 12.5, height: 1.4, color: palette.muted),
        ),
        if (_snippet.isNotEmpty) ...[
          const SizedBox(height: 8),
          AiQuoteBlock(label: '选中的原文', text: _snippet, maxLines: 5),
        ],
        if (_selectionError != null) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                LucideIcons.circle_alert,
                size: 16,
                color: aiFeedbackToneColor(palette, AiStatusTone.error),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '请重新选择同一段落里的连续文字。',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: aiFeedbackToneColor(palette, AiStatusTone.error),
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        _label(palette, '你期望改成（可选）'),
        const SizedBox(height: 6),
        _field(palette, controller: _expected, hint: '例如：撑不住', enabled: !_busy),
        const SizedBox(height: 12),
        _label(palette, '补充说明（可选）'),
        const SizedBox(height: 6),
        _field(
          palette,
          controller: _comment,
          hint: '这里想表达坚持不住，不是够不到',
          maxLines: 3,
          enabled: !_busy,
        ),
        if (_submitError != null) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                LucideIcons.circle_alert,
                size: 16,
                color: aiFeedbackToneColor(palette, AiStatusTone.error),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _submitError!,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: aiFeedbackToneColor(palette, AiStatusTone.error),
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: LinearProgressIndicator(
              minHeight: 2,
              color: palette.accentText,
              backgroundColor: palette.line,
            ),
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: canSubmit ? _submit : null,
                child: const Text('提交反馈'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _label(HomePalette palette, String text) => Text(
    text,
    style: TextStyle(
      fontSize: 13,
      height: 1.3,
      fontWeight: FontWeight.w600,
      color: palette.ink,
    ),
  );

  Widget _field(
    HomePalette palette, {
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
    bool enabled = true,
  }) {
    final radius = BorderRadius.circular(12);
    return TextField(
      controller: controller,
      enabled: enabled,
      maxLines: maxLines,
      minLines: 1,
      style: TextStyle(fontSize: 14, height: 1.5, color: palette.ink),
      textInputAction: maxLines > 1
          ? TextInputAction.newline
          : TextInputAction.done,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontSize: 13, color: palette.muted),
        isDense: true,
        filled: true,
        fillColor: palette.soft,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: palette.line, width: 0.6),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: palette.line, width: 0.6),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: palette.accentText, width: 0.9),
        ),
      ),
    );
  }
}
