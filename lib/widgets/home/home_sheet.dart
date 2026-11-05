import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';

/// Shared sheet surface. Long virtualized lists reuse [HomeSheetHeader] without
/// nesting their scroll controller inside this frame.
class HomeSheetFrame extends StatelessWidget {
  const HomeSheetFrame({
    super.key,
    required this.title,
    required this.children,
    this.closeTooltip = '关闭',
    this.closeKey,
    this.onClose,
    this.maxHeightFactor = 0.82,
    this.contentPadding = const EdgeInsets.fromLTRB(20, 4, 20, 16),
    this.showHandle = true,
    this.scrollKey,
  });

  static const double radius = 16;

  /// 统一的弹层标题字号。
  static const double titleFontSize = 20;

  final String title;
  final List<Widget> children;
  final String closeTooltip;

  /// 关闭按钮的 key：面板原有的测试 / 无障碍契约（如
  /// `voice_settings_close`）在换到统一基座后仍可沿用。
  final Key? closeKey;

  /// 关闭动作；缺省返回上一页。需要先落盘再关时由调用方传入。
  final VoidCallback? onClose;

  /// 面板最多占屏高的比例，小屏 / 大字号下内容改为内部滚动。
  final double maxHeightFactor;

  /// 内容内边距。放整宽列表（目录、选集）时可传入更小的水平值。
  final EdgeInsetsGeometry contentPadding;
  final bool showHandle;
  final Key? scrollKey;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final media = MediaQuery.of(context);
    final availableHeight =
        (media.size.height - media.viewInsets.bottom - media.padding.top).clamp(
          0.0,
          media.size.height,
        );
    return AnimatedPadding(
      duration: palette.eink || media.disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 160),
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: availableHeight * maxHeightFactor,
        ),
        decoration: BoxDecoration(
          color: homeSheetColor(palette),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(radius),
          ),
          border: Border(top: homeSheetShape(palette, top: radius).side),
        ),
        child: Material(
          type: MaterialType.transparency,
          // The header also scrolls on short screens with a keyboard open.
          child: SingleChildScrollView(
            key: scrollKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                HomeSheetHeader(
                  title: title,
                  closeTooltip: closeTooltip,
                  closeKey: closeKey,
                  onClose: onClose,
                  showHandle: showHandle,
                ),
                Padding(
                  padding: contentPadding.add(
                    EdgeInsets.only(bottom: media.padding.bottom),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HomeSheetHeader extends StatelessWidget {
  const HomeSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.closeTooltip = '关闭',
    this.closeKey,
    this.onClose,
    this.showHandle = true,
  });

  final String title;
  final String? subtitle;
  final String closeTooltip;
  final Key? closeKey;
  final VoidCallback? onClose;
  final bool showHandle;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showHandle)
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 32,
            height: 3,
            decoration: BoxDecoration(
              color: palette.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: palette.ink,
                        fontSize: HomeSheetFrame.titleFontSize,
                        height: 1.3,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle?.isNotEmpty == true) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: palette.muted, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                key: closeKey,
                tooltip: closeTooltip,
                onPressed: onClose ?? () => Navigator.maybePop(context),
                color: palette.ink,
                icon: const Icon(LucideIcons.x, size: 20),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: palette.line),
      ],
    );
  }
}

/// 以 [HomeSheetFrame] 为基座打开底部弹层。
///
/// 与直接调用 `showModalBottomSheet` 的差别：配色 / 圆角 / 拖拽柄 / 关闭
/// 按钮全部统一，调用方只给标题与内容。[children] 构建的是内容列，等宽
/// 排列；需要局部刷新时在 children 里放 `StatefulBuilder`。
Future<T?> showHomeSheet<T>({
  required BuildContext context,
  required String title,
  required List<Widget> children,
  String? closeTooltip,
  double maxHeightFactor = 0.82,
  EdgeInsetsGeometry contentPadding = const EdgeInsets.fromLTRB(20, 4, 20, 16),
  bool showHandle = true,
  Key? scrollKey,
}) {
  final palette = HomePalette.of(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: homeSheetColor(palette),
    clipBehavior: Clip.antiAlias,
    shape: homeSheetShape(palette, top: HomeSheetFrame.radius),
    sheetAnimationStyle: palette.eink || MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (sheetContext) => HomeSheetFrame(
      title: title,
      closeTooltip: closeTooltip ?? '关闭',
      maxHeightFactor: maxHeightFactor,
      contentPadding: contentPadding,
      showHandle: showHandle,
      scrollKey: scrollKey,
      children: children,
    ),
  );
}
