import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../services/reader_preferences.dart';
import '../reader_theme.dart';

/// 阅读设置面板里的取色来源：面板本身、点击区域编辑器等子界面共用当前
/// 阅读预设，避免在浅色面板上残留写死的白色 / 黑色。
class ReaderSettingsTheme extends InheritedWidget {
  const ReaderSettingsTheme({
    super.key,
    required this.preset,
    required super.child,
  });

  final ReaderThemePreset preset;

  static ReaderThemePreset of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ReaderSettingsTheme>()
          ?.preset ??
      ReaderThemePreset.light;

  @override
  bool updateShouldNotify(ReaderSettingsTheme oldWidget) =>
      oldWidget.preset != preset;
}

/// 面板骨架：拖动条 + 标题 + 关闭按钮 + 可滚动内容。
///
/// 内容默认按一屏排布；小屏 / 大字号下退化为滚动，绝不裁切。
/// [maxHeightFactor] 是面板最多占屏高的比例。
class ReaderSettingsSheetFrame extends StatelessWidget {
  const ReaderSettingsSheetFrame({
    super.key,
    required this.preset,
    required this.title,
    required this.closeTooltip,
    required this.scrollKey,
    required this.children,
    this.maxHeightFactor = 0.82,
  });

  final ReaderThemePreset preset;
  final String title;
  final String closeTooltip;
  final Key scrollKey;
  final double maxHeightFactor;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ReaderSettingsTheme(
      preset: preset,
      child: Theme(
        data: preset.theme(Theme.of(context)),
        child: AnimatedContainer(
          // 墨水屏：任何插值动画都会留残影，面板直接跳变。
          duration: preset.isEink
              ? Duration.zero
              : const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: preset.sheetColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            border: Border(
              top: BorderSide(
                color: preset.isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
                width: 0.8,
              ),
            ),
          ),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * maxHeightFactor,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: EdgeInsets.only(
                bottom:
                    MediaQuery.viewInsetsOf(context).bottom +
                    MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _header(context, preset),
                  Flexible(
                    child: SingleChildScrollView(
                      key: scrollKey,
                      padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: children,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, ReaderThemePreset preset) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        margin: const EdgeInsets.only(top: 10, bottom: 4),
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: preset.mutedTextColor.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 8, 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: preset.textColor,
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: closeTooltip,
              onPressed: () => Navigator.pop(context),
              icon: const Icon(LucideIcons.x, size: 20),
            ),
          ],
        ),
      ),
    ],
  );
}

/// 一行设置：短标签 + 控件。标签允许换行，不截断。
class ReaderSettingsRow extends StatelessWidget {
  const ReaderSettingsRow({
    super.key,
    required this.label,
    required this.child,
  });

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final preset = ReaderSettingsTheme.of(context);
    // 标签列统一按四个字宽（「左右边距」）留位，各行控件起点对齐；
    // 大字号时最多占行宽 35%，超出部分换行而不是挤压控件。
    final labelWidth = MediaQuery.textScalerOf(context).scale(13) * 4 + 4;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: labelWidth.clamp(0.0, constraints.maxWidth * 0.35),
              child: Text(
                label,
                style: TextStyle(color: preset.textColor, fontSize: 13),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

/// 选项 chip：内容自适应宽度，不固定高度，放大字号时靠换行而不是裁切。
class ReaderSettingsChip extends StatelessWidget {
  const ReaderSettingsChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final preset = ReaderSettingsTheme.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected
            ? preset.accentColor.withValues(alpha: 0.14)
            : preset.fieldColor,
        borderRadius: BorderRadius.circular(90),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          // 不用 Container.alignment：带 alignment 的 Container 会撑满可用宽度，
          // 在 Wrap 里每个 chip 都会独占一行。
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 34),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected
                        ? preset.accentColor
                        : preset.mutedTextColor,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// chip 组：放得下时一行等分，放不下（窄屏、大字号）才换行。
class ReaderSettingsChipRow extends StatelessWidget {
  const ReaderSettingsChipRow({super.key, required this.children});

  final List<Widget> children;

  static const _gap = 6.0;

  /// 一个 chip 不被截断所需的最小宽度：最长标签按当前字号估算 + 左右内边距。
  double _minChipWidth(BuildContext context) {
    var longest = 2;
    for (final child in children) {
      if (child is ReaderSettingsChip && child.label.length > longest) {
        longest = child.label.length;
      }
    }
    return MediaQuery.textScalerOf(context).scale(12) * longest + 24;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final needed =
          _minChipWidth(context) * children.length +
          _gap * (children.length - 1);
      if (needed <= constraints.maxWidth) {
        return Row(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              Expanded(child: children[i]),
            ],
          ],
        );
      }
      return Wrap(
        spacing: _gap,
        runSpacing: _gap,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      );
    },
  );
}

/// 开关行：标签左、开关右。
class ReaderSettingsSwitchRow extends StatelessWidget {
  const ReaderSettingsSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final preset = ReaderSettingsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                label,
                style: TextStyle(color: preset.textColor, fontSize: 13),
              ),
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// − / 值 / + 步进器。加减按钮不做固定尺寸，随字号撑开。
class ReaderSettingsStepper extends StatelessWidget {
  const ReaderSettingsStepper({
    super.key,
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
    required this.decreaseTooltip,
    required this.increaseTooltip,
  });

  final String value;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;
  final String decreaseTooltip;
  final String increaseTooltip;

  @override
  Widget build(BuildContext context) {
    final preset = ReaderSettingsTheme.of(context);
    // 紧凑的胶囊步进器靠右放：− 值 + 挨在一起，不再横跨整行留大片空白。
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 168),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: preset.fieldColor,
            borderRadius: BorderRadius.circular(90),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: decreaseTooltip,
                visualDensity: VisualDensity.compact,
                onPressed: onDecrease,
                icon: const Icon(LucideIcons.minus, size: 16),
              ),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 44),
                  child: Text(
                    value,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: preset.accentColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: increaseTooltip,
                visualDensity: VisualDensity.compact,
                onPressed: onIncrease,
                icon: const Icon(LucideIcons.plus, size: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 跳转子页 / 开启编辑器的行：标题 + 右箭头，无副标题。
class ReaderSettingsNavRow extends StatelessWidget {
  const ReaderSettingsNavRow({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final preset = ReaderSettingsTheme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: preset.mutedTextColor),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: preset.textColor, fontSize: 13),
              ),
            ),
            Icon(
              LucideIcons.chevron_right,
              size: 18,
              color: preset.mutedTextColor,
            ),
          ],
        ),
      ),
    );
  }
}

/// 分组小标题。
class ReaderSettingsSectionHeader extends StatelessWidget {
  const ReaderSettingsSectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final preset = ReaderSettingsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        title,
        style: TextStyle(
          color: preset.mutedTextColor,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 分隔线。
class ReaderSettingsDivider extends StatelessWidget {
  const ReaderSettingsDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Divider(
      height: 1,
      color: ReaderSettingsTheme.of(context).borderColor,
    ),
  );
}
