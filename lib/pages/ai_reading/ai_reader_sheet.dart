import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/text_replacement_rule.dart';
import '../../services/ai_reading/ai_controller.dart';
import '../../services/ai_reading/ai_coordinator.dart';
import '../../services/ai_reading/ai_display_composition.dart';
import '../../services/ai_reading/ai_models.dart';
import '../../services/reader_preferences.dart';
import '../../widgets/ai_reading/ai_ui.dart';
import '../../widgets/reader/reader_theme.dart';
import 'settings/ai_book_settings_page.dart';

Future<void> showAiReaderSheet(
  BuildContext context, {
  required AiReadingController controller,
  required AiChapterView view,
  required ReaderThemePreset preset,
  required String bookId,
  required String bookTitle,
  required String chapterId,
  required String chapterTitle,
  required bool temporaryOriginal,
  required Future<AiTaskResult?> Function(bool forceRefresh) onRefresh,
  required Future<void> Function(AiDisplayMode mode) onModeChanged,
  required Future<void> Function(bool value) onTemporaryOriginalChanged,
  required void Function(AiEditSpan span) onOpenEdit,
  required void Function(AiBlockedEdit blocked) onPreviewBlocked,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _AiReaderSheet(
      controller: controller,
      view: view,
      preset: preset,
      bookId: bookId,
      bookTitle: bookTitle,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      temporaryOriginal: temporaryOriginal,
      onRefresh: onRefresh,
      onModeChanged: onModeChanged,
      onTemporaryOriginalChanged: onTemporaryOriginalChanged,
      onOpenEdit: onOpenEdit,
      onPreviewBlocked: onPreviewBlocked,
    ),
  );
}

class _AiReaderSheet extends StatefulWidget {
  const _AiReaderSheet({
    required this.controller,
    required this.view,
    required this.preset,
    required this.bookId,
    required this.bookTitle,
    required this.chapterId,
    required this.chapterTitle,
    required this.temporaryOriginal,
    required this.onRefresh,
    required this.onModeChanged,
    required this.onTemporaryOriginalChanged,
    required this.onOpenEdit,
    required this.onPreviewBlocked,
  });

  final AiReadingController controller;
  final AiChapterView view;
  final ReaderThemePreset preset;
  final String bookId;
  final String bookTitle;
  final String chapterId;
  final String chapterTitle;
  final bool temporaryOriginal;
  final Future<AiTaskResult?> Function(bool forceRefresh) onRefresh;
  final Future<void> Function(AiDisplayMode mode) onModeChanged;
  final Future<void> Function(bool value) onTemporaryOriginalChanged;
  final void Function(AiEditSpan span) onOpenEdit;
  final void Function(AiBlockedEdit blocked) onPreviewBlocked;

  @override
  State<_AiReaderSheet> createState() => _AiReaderSheetState();
}

class _AiReaderSheetState extends State<_AiReaderSheet> {
  late AiChapterView _view = widget.view;
  late bool _temporaryOriginal = widget.temporaryOriginal;
  late final ValueNotifier<AiStreamProgress?> _progressNotifier;
  AiStreamProgress? _progress;
  String? _lastNotice;
  bool _busy = false;
  bool _stopping = false;
  bool _showEdits = false;

  @override
  void initState() {
    super.initState();
    _progressNotifier = widget.controller.progressFor(
      widget.bookId,
      widget.chapterId,
    );
    _progress = _progressNotifier.value;
    widget.controller.addListener(_onChanged);
    _progressNotifier.addListener(_onProgress);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _progressNotifier.removeListener(_onProgress);
    super.dispose();
  }

  void _onProgress() {
    if (!mounted) return;
    final progress = _progressNotifier.value;
    setState(() => _progress = progress);
    final notice = progress?.notice;
    if (notice == null) {
      _lastNotice = null;
      return;
    }
    if (notice == _lastNotice) return;
    _lastNotice = notice;
    showAiTopToast(context, notice);
  }

  Future<void> _onChanged() async {
    if (!mounted) return;
    if (widget.controller.statusFor(widget.bookId, widget.chapterId).running) {
      setState(() {});
      return;
    }
    if (_stopping) _stopping = false;
    final view = await widget.controller.viewFor(
      bookId: widget.bookId,
      chapterId: widget.chapterId,
      chapterTitle: widget.chapterTitle,
      content: _view.composition.replacement.source,
      customSnapshot: _view.composition.replacement.snapshotRevision == 0
          ? TextReplacementSnapshot()
          : _customSnapshot(),
      temporaryOriginal: _temporaryOriginal,
    );
    if (!mounted) return;
    setState(() => _view = view);
  }

  TextReplacementSnapshot _customSnapshot() {
    // The sheet only needs a revision for display; the reader owns the real
    // custom rules and recomposes after any feedback action.
    return TextReplacementSnapshot();
  }

  Future<void> _refresh({bool force = false}) async {
    if (_busy ||
        widget.controller.statusFor(widget.bookId, widget.chapterId).running) {
      return;
    }
    setState(() => _busy = true);
    AiTaskResult? result;
    try {
      result = await widget.onRefresh(force);
    } catch (error) {
      if (mounted) showAiTopToast(context, '校对失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stopping = false;
        });
      }
    }
    if (!mounted || result == null) return;
    if (!result.ok) {
      if (result.errorCodes.contains('REQUEST_ABORTED')) {
        showAiTopToast(context, '已停止本次校对');
        return;
      }
      showAiTopToast(context, '校对失败：${result.error ?? '未知错误'}');
      return;
    }
    final edits = result.formal?.edits.length ?? 0;
    showAiTopToast(context, edits == 0 ? '校对完成，本章无需修改' : '校对完成，已保存 $edits 处修改');
  }

  bool get _running =>
      widget.controller.statusFor(widget.bookId, widget.chapterId).running;

  void _stop() {
    if (!_running || _stopping) return;
    setState(() => _stopping = true);
    widget.controller.cancelChapterRequest(widget.bookId, widget.chapterId);
  }

  String _buttonLabel(bool hasFormal) {
    if (_running) {
      if (_stopping) return '正在停止…';
      final progress = _progress;
      if (progress == null) return '准备中…';
      final attempt = progress.attempt > 1 ? '第 ${progress.attempt} 次 · ' : '';
      final prefix = progress.exact ? '' : '~';
      return '$attempt$prefix${_formatTokens(progress.estimatedTokens)} tokens';
    }
    return hasFormal ? '重新校对' : '立即校对';
  }

  String _statusText() {
    if (_stopping) return '正在停止…';
    if (_running) {
      final progress = _progress;
      if (progress == null) return '正在连接…';
      if (progress.notice != null) return progress.notice!;
      if (progress.contentChars == 0 && progress.reasoningChars > 0) {
        return '正在思考…';
      }
      return '正在生成修改…';
    }
    final progress = _progress;
    if (progress != null && progress.estimatedTokens > 0) {
      final prefix = progress.exact ? '' : '~';
      return '${_view.status} · $prefix${_formatTokens(progress.estimatedTokens)} tokens';
    }
    return _view.status;
  }

  static String _formatTokens(int value) {
    final text = value.toString();
    final out = StringBuffer();
    for (var index = 0; index < text.length; index++) {
      if (index > 0 && (text.length - index) % 3 == 0) out.write(',');
      out.write(text[index]);
    }
    return out.toString();
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final formal = _view.composition.formal;
    final spans = _view.composition.applied?.spans ?? const <AiEditSpan>[];
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.82,
      ),
      child: Material(
        color: preset.panelColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        child: SafeArea(
          top: false,
          minimum: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottom),
          child: ListView(
            shrinkWrap: true,
            children: [
              Row(
                children: [
                  Icon(
                    LucideIcons.sparkles,
                    size: 18,
                    color: preset.accentColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'AI 校对',
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
              Text(
                _temporaryOriginal ? '显示原文，AI 修改已临时隐藏' : _statusText(),
                style: TextStyle(color: preset.mutedTextColor, fontSize: 12.5),
              ),
              if (formal != null && formal.edits.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '${_view.composition.skippedByProtection} 处锁定'
                  '${_view.composition.approvedCount > 0 ? '，回放 ${_view.composition.approvedCount} 处' : ''}',
                  style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
                ),
              ],
              const SizedBox(height: 14),
              _ModeRow(
                mode: _temporaryOriginal ? AiDisplayMode.original : _view.mode,
                preset: preset,
                enabled: !_busy,
                onChanged: (mode) async {
                  setState(() => _busy = true);
                  try {
                    await widget.onModeChanged(mode);
                    if (mounted) setState(() => _temporaryOriginal = false);
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '本次看原文',
                  style: TextStyle(color: preset.textColor, fontSize: 13),
                ),
                value: _temporaryOriginal,
                onChanged: _busy
                    ? null
                    : (value) async {
                        setState(() {
                          _temporaryOriginal = value;
                          _busy = true;
                        });
                        try {
                          await widget.onTemporaryOriginalChanged(value);
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy || _running
                          ? null
                          : () => _refresh(force: formal != null),
                      icon: _busy || _running
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(LucideIcons.refresh_cw, size: 16),
                      label: Text(_buttonLabel(formal != null)),
                    ),
                  ),
                ],
              ),
              if (_running) ...[
                const SizedBox(height: 2),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _stopping ? null : _stop,
                    style: TextButton.styleFrom(
                      foregroundColor: preset.mutedTextColor,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                    icon: const Icon(LucideIcons.circle_stop, size: 15),
                    label: Text(_stopping ? '正在停止…' : '停止校对'),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => AiBookSettingsPage(
                          bookId: widget.bookId,
                          title: widget.bookTitle,
                        ),
                      ),
                    );
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: preset.accentColor,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  icon: const Icon(LucideIcons.settings_2, size: 15),
                  label: const Text('本书 AI 设置'),
                ),
              ),
              if (spans.isNotEmpty) ...[
                const SizedBox(height: 12),
                InkWell(
                  onTap: () => setState(() => _showEdits = !_showEdits),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '查看修改（${spans.length}）',
                            style: TextStyle(
                              color: preset.textColor,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Icon(
                          _showEdits
                              ? LucideIcons.chevron_up
                              : LucideIcons.chevron_down,
                          size: 17,
                          color: preset.mutedTextColor,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_showEdits)
                  for (final span in spans)
                    _EditTile(
                      span: span,
                      preset: preset,
                      onTap: () {
                        Navigator.pop(context);
                        widget.onOpenEdit(span);
                      },
                    ),
              ],
              if (_view.composition.blockedEdits.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '被保护拦截（${_view.composition.blockedEdits.length}）',
                  style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
                ),
                for (final blocked in _view.composition.blockedEdits)
                  _BlockedTile(
                    blocked: blocked,
                    preset: preset,
                    onPreview: () {
                      Navigator.pop(context);
                      widget.onPreviewBlocked(blocked);
                    },
                  ),
              ],
              if (formal != null && formal.edits.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    '本章没有需要修改的地方。',
                    style: TextStyle(
                      color: preset.mutedTextColor,
                      fontSize: 12.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.mode,
    required this.preset,
    required this.enabled,
    required this.onChanged,
  });

  final AiDisplayMode mode;
  final ReaderThemePreset preset;
  final bool enabled;
  final ValueChanged<AiDisplayMode> onChanged;

  @override
  Widget build(BuildContext context) {
    const labels = {
      AiDisplayMode.original: '原文',
      AiDisplayMode.customOnly: '仅自定义',
      AiDisplayMode.aiOptimized: 'AI 优化',
    };
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: preset.isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (final item in AiDisplayMode.values)
            Expanded(
              child: GestureDetector(
                onTap: enabled ? () => onChanged(item) : null,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: mode == item
                        ? preset.panelColor
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: mode == item
                          ? preset.mutedTextColor.withValues(alpha: 0.25)
                          : Colors.transparent,
                      width: 0.6,
                    ),
                  ),
                  child: Text(
                    labels[item]!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: mode == item
                          ? preset.textColor
                          : preset.mutedTextColor,
                      fontSize: 12.5,
                      fontWeight: mode == item
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EditTile extends StatelessWidget {
  const _EditTile({
    required this.span,
    required this.preset,
    required this.onTap,
  });
  final AiEditSpan span;
  final ReaderThemePreset preset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: preset.panelColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: preset.isDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.black.withValues(alpha: 0.08),
            width: 0.6,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    span.category,
                    style: TextStyle(
                      color: preset.accentColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (span.approved)
                  Text(
                    '认可改法',
                    style: TextStyle(
                      color: preset.mutedTextColor,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${span.original} → ${span.replacement.isEmpty ? '（删除）' : span.replacement}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: preset.textColor,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlockedTile extends StatelessWidget {
  const _BlockedTile({
    required this.blocked,
    required this.preset,
    required this.onPreview,
  });

  final AiBlockedEdit blocked;
  final ReaderThemePreset preset;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final span = blocked.span;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: preset.panelColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: preset.isDark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.black.withValues(alpha: 0.08),
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  blocked.keepOriginal ? '已锁定原文' : '已锁定认可改法',
                  style: TextStyle(
                    color: preset.mutedTextColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: onPreview,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('临时预览'),
              ),
            ],
          ),
          Text(
            '原文：${span.original}',
            style: TextStyle(
              color: preset.textColor,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          Text(
            'AI 改为：${span.replacement.isEmpty ? '（删除）' : span.replacement}',
            style: TextStyle(
              color: preset.textColor,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          if (span.reason.isNotEmpty)
            Text(
              span.reason,
              style: TextStyle(
                color: preset.mutedTextColor,
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
        ],
      ),
    );
  }
}
