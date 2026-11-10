import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/ai_reading/ai_models.dart';
import '../home/home_design.dart';
import '../settings/settings_widgets.dart';

OverlayEntry? _aiToastEntry;
Timer? _aiToastTimer;

/// Top-anchored toast used by the reader sheet. A normal bottom SnackBar is
/// hidden behind the modal sheet, so read progress would otherwise be silent.
void showAiTopToast(BuildContext context, String message) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _aiToastTimer?.cancel();
  _aiToastEntry?.remove();
  final top = MediaQuery.paddingOf(context).top + 14;
  final entry = OverlayEntry(
    builder: (context) => Positioned(
      top: top,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: Material(
          color: Colors.transparent,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xE6242424),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  _aiToastEntry = entry;
  overlay.insert(entry);
  _aiToastTimer = Timer(const Duration(milliseconds: 2600), () {
    if (identical(_aiToastEntry, entry)) _aiToastEntry = null;
    try {
      entry.remove();
    } catch (_) {}
  });
}

class AiStatusPill extends StatelessWidget {
  const AiStatusPill({
    super.key,
    required this.label,
    this.tone = AiStatusTone.neutral,
  });

  final String label;
  final AiStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final color = switch (tone) {
      AiStatusTone.ok => palette.eink ? Colors.black : const Color(0xFF557A46),
      AiStatusTone.warn =>
        palette.eink ? Colors.black : const Color(0xFF9A6A24),
      AiStatusTone.error =>
        palette.eink ? Colors.black : const Color(0xFF9C3D33),
      AiStatusTone.neutral => palette.muted,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: palette.eink ? 0 : 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: palette.eink ? Colors.black : color.withValues(alpha: 0.22),
          width: 0.6,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          height: 1.2,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

enum AiStatusTone { neutral, ok, warn, error }

class AiModeSelector extends StatelessWidget {
  const AiModeSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final AiDisplayMode value;
  final ValueChanged<AiDisplayMode>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    const labels = {
      AiDisplayMode.original: '原文',
      AiDisplayMode.customOnly: '仅自定义替换',
      AiDisplayMode.aiOptimized: 'AI 优化',
    };
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      child: Row(
        children: [
          for (final mode in AiDisplayMode.values)
            Expanded(
              child: Semantics(
                selected: value == mode,
                button: true,
                child: GestureDetector(
                  onTap: enabled ? () => onChanged?.call(mode) : null,
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: value == mode
                          ? palette.surface
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: value == mode
                            ? palette.line
                            : Colors.transparent,
                        width: 0.6,
                      ),
                    ),
                    child: Text(
                      labels[mode]!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.2,
                        fontWeight: value == mode
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: enabled
                            ? value == mode
                                  ? palette.ink
                                  : palette.muted
                            : palette.muted,
                      ),
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

Future<bool> showAiConsentDialog(
  BuildContext context, {
  required String host,
  String? model,
}) async {
  final palette = HomePalette.of(context);
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      backgroundColor: palette.surface,
      title: const Text('把章节正文发给第三方？'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '开启后，每次校对会把当前章节的完整正文发送到 $host'
              '${model == null ? '' : '（模型 $model）'}。',
              style: TextStyle(color: palette.ink, height: 1.5),
            ),
            const SizedBox(height: 12),
            Text(
              '服务商可能按 Token 收费；请求一旦发出，即使取消也可能已经计费。'
              'API Key 只保存在系统安全存储，不会进入备份。',
              style: TextStyle(color: palette.muted, height: 1.5),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('暂不开启'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('同意并开启'),
        ),
      ],
    ),
  );
  return result == true;
}

Future<bool> showAiBudgetDialog(BuildContext context, String message) async {
  final palette = HomePalette.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: palette.surface,
      title: const Text('本次请求将超出预算'),
      content: Text(message, style: TextStyle(color: palette.ink, height: 1.5)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('仍然请求'),
        ),
      ],
    ),
  );
  return result == true;
}

/// Keeps dialog-scoped resources (text controllers) alive until the dialog
/// subtree has fully unmounted. `showDialog`'s future completes as soon as the
/// pop starts while the exit animation is still playing, so a controller
/// disposed from the caller side is still held by the mounted TextField, and
/// the unmount pass then trips framework assertions (`_dependents.isEmpty`)
/// on desktop IME paths.
class AiDialogHost extends StatefulWidget {
  const AiDialogHost({
    super.key,
    required this.builder,
    required this.onDispose,
  });

  /// Rebuilt whenever [State.setState] is called, like a [StatefulBuilder];
  /// the second argument is that setState (validation errors and such).
  final Widget Function(BuildContext context, StateSetter setState) builder;

  /// Called from [State.dispose], after every descendant (TextField included)
  /// has unmounted.
  final VoidCallback onDispose;

  @override
  State<AiDialogHost> createState() => _AiDialogHostState();
}

class _AiDialogHostState extends State<AiDialogHost> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, setState);
}

Future<String?> showAiTextInputDialog(
  BuildContext context, {
  required String title,
  String? hint,
  String initial = '',
  int maxLines = 3,
}) async {
  final controller = TextEditingController(text: initial);
  final palette = HomePalette.of(context);
  // showDialog's future resolves the moment the pop starts, while the exit
  // animation is still playing; resolve only after the host unmounts so the
  // caller's follow-up work stays out of the animation frames.
  final removed = Completer<void>();
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AiDialogHost(
      onDispose: () {
        controller.dispose();
        removed.complete();
      },
      builder: (dialogContext, setState) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: maxLines,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  await removed.future;
  return result;
}

/// A compact row used by the AI pages when the existing SettingsRow is too
/// tall or needs a custom trailing widget.
class AiMiniRow extends StatelessWidget {
  const AiMiniRow({
    super.key,
    required this.label,
    required this.value,
    this.onTap,
    this.trailing,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: palette.ink, height: 1.3),
            ),
          ),
          if (trailing != null)
            trailing!
          else
            Text(
              value,
              style: TextStyle(
                fontSize: 12.5,
                color: palette.muted,
                height: 1.3,
              ),
            ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 16, color: palette.muted),
          ],
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(onTap: onTap, child: content);
  }
}

class AiInfoCard extends StatelessWidget {
  const AiInfoCard({
    super.key,
    required this.title,
    required this.body,
    this.icon,
    this.tone = AiStatusTone.neutral,
  });

  final String title;
  final String body;
  final IconData? icon;
  final AiStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final color = switch (tone) {
      AiStatusTone.ok => palette.eink ? Colors.black : const Color(0xFF557A46),
      AiStatusTone.warn =>
        palette.eink ? Colors.black : const Color(0xFF9A6A24),
      AiStatusTone.error =>
        palette.eink ? Colors.black : const Color(0xFF9C3D33),
      AiStatusTone.neutral => palette.muted,
    };
    return SurfacePanel(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: palette.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
