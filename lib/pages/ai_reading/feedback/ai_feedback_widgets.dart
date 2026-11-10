import 'package:flutter/material.dart';

import '../../../services/ai_reading/ai_models.dart';
import '../../../widgets/ai_reading/ai_ui.dart';
import '../../../widgets/home/home_design.dart';

/// 反馈类型对应的状态色。墨水屏下 `AiStatusPill` 与这里都会退化成黑白，
/// 类型的区分仍然靠文字标签，不依赖颜色。
AiStatusTone aiFeedbackKindTone(AiFeedbackKind kind) => switch (kind) {
  AiFeedbackKind.good => AiStatusTone.ok,
  AiFeedbackKind.shouldNotChange => AiStatusTone.neutral,
  AiFeedbackKind.wrongChange => AiStatusTone.error,
  AiFeedbackKind.missedChange => AiStatusTone.warn,
};

/// 与 [AiStatusPill] 内部同一套色值，供 badge / 文字复用。
Color aiFeedbackToneColor(
  HomePalette palette,
  AiStatusTone tone,
) => switch (tone) {
  AiStatusTone.ok => palette.eink ? Colors.black : const Color(0xFF557A46),
  AiStatusTone.warn => palette.eink ? Colors.black : const Color(0xFF9A6A24),
  AiStatusTone.error => palette.eink ? Colors.black : const Color(0xFF9C3D33),
  AiStatusTone.neutral => palette.muted,
};

String aiFeedbackStatusText(AiFeedbackStatus status) => switch (status) {
  AiFeedbackStatus.active => '生效中',
  AiFeedbackStatus.archived => '已归档',
  AiFeedbackStatus.superseded => '已被替代',
  AiFeedbackStatus.deleted => '已删除',
};

/// 状态文案。生效中的反馈如果绑定的正文版本已经不是当前版本，显示为
/// 「待重新定位」，不把它伪装成仍然生效。
String aiFeedbackStatusLabel(
  AiFeedbackCase feedback, {
  bool relocated = false,
}) {
  if (feedback.status == AiFeedbackStatus.active && relocated) {
    return '待重新定位';
  }
  return aiFeedbackStatusText(feedback.status);
}

AiStatusTone aiFeedbackStatusTone(
  AiFeedbackCase feedback, {
  bool relocated = false,
}) {
  if (feedback.status == AiFeedbackStatus.active && relocated) {
    return AiStatusTone.warn;
  }
  return feedback.status == AiFeedbackStatus.active
      ? AiStatusTone.ok
      : AiStatusTone.neutral;
}

/// 两类持久保护的固定文案，和阅读器里的提示保持一致。
String aiFeedbackPolicyLabel(AiProtectionPolicy policy) =>
    policy == AiProtectionPolicy.keepApprovedEdit ? '已锁定认可改法' : '已锁定原文';

String aiFeedbackPolicyEffect(AiProtectionPolicy policy) =>
    policy == AiProtectionPolicy.keepApprovedEdit
    ? '此处已锁定认可改法，与它重叠的新修改会整条跳过'
    : '此处已锁定原文，与它重叠的新修改会整条跳过';

/// 一条反馈是否会产生显示保护。
bool aiFeedbackProtects(AiFeedbackCase feedback) =>
    feedback.kind == AiFeedbackKind.good ||
    feedback.kind == AiFeedbackKind.shouldNotChange;

/// 卡片上的一句话保护说明。
String aiFeedbackProtectionSummary(AiFeedbackCase feedback) {
  if (feedback.kind == AiFeedbackKind.good) {
    return feedback.protectionEnabled ? '已锁定认可改法' : '保护已停用';
  }
  if (feedback.kind == AiFeedbackKind.shouldNotChange) {
    return feedback.protectionEnabled ? '已锁定原文' : '保护已停用';
  }
  if (feedback.kind == AiFeedbackKind.wrongChange) {
    return '不产生显示保护，保留为错误改法反例';
  }
  return '不产生显示保护，等待人工确认';
}

String aiFeedbackKindDescription(AiFeedbackKind kind) => switch (kind) {
  AiFeedbackKind.good => '锁定这次认可的改法',
  AiFeedbackKind.shouldNotChange => '锁定这段原文，不允许 AI 再改',
  AiFeedbackKind.wrongChange => '记录这次改错的地方，不锁定显示',
  AiFeedbackKind.missedChange => '记录 AI 漏掉的问题，不锁定显示',
};

/// 反馈时间：同年只显示月日，跨年补年份。
String aiFeedbackTimeLabel(DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  final monthDay = '${two(local.month)}-${two(local.day)}';
  final clock = '${two(local.hour)}:${two(local.minute)}';
  return local.year == now.year
      ? '$monthDay $clock'
      : '${local.year}-$monthDay $clock';
}

/// 反馈类型的方角标签。状态仍走 [AiFeedbackStatusPill]，两者形状不同，
/// 不额外叠加色条或描边竖线。
class AiFeedbackKindBadge extends StatelessWidget {
  const AiFeedbackKindBadge({super.key, required this.kind});

  final AiFeedbackKind kind;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final color = aiFeedbackToneColor(palette, aiFeedbackKindTone(kind));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: palette.eink ? 0 : 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: palette.eink ? Colors.black : color.withValues(alpha: 0.22),
          width: 0.6,
        ),
      ),
      child: Text(
        kind.label,
        style: TextStyle(
          fontSize: 12,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: palette.eink ? Colors.black : color,
        ),
      ),
    );
  }
}

class AiFeedbackStatusPill extends StatelessWidget {
  const AiFeedbackStatusPill({
    super.key,
    required this.feedback,
    this.relocated = false,
  });

  final AiFeedbackCase feedback;

  /// 当前正文版本与反馈绑定的版本不一致。
  final bool relocated;

  @override
  Widget build(BuildContext context) => AiStatusPill(
    label: aiFeedbackStatusLabel(feedback, relocated: relocated),
    tone: aiFeedbackStatusTone(feedback, relocated: relocated),
  );
}

/// 原文 / 改法片段：soft 底，标签在上，正文允许多行。
class AiQuoteBlock extends StatelessWidget {
  const AiQuoteBlock({
    super.key,
    required this.label,
    required this.text,
    this.maxLines,
  });

  final String label;
  final String text;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, height: 1.3, color: palette.muted),
          ),
          const SizedBox(height: 4),
          Text(
            text,
            maxLines: maxLines,
            overflow: maxLines == null ? null : TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, height: 1.55, color: palette.ink),
          ),
        ],
      ),
    );
  }
}
