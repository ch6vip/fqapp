import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';

/// 底部弹层的统一基座：拖拽柄 + 标题 + Lucide 关闭 + 可滚动内容。
///
/// 几何取阅读设置面板 [ReaderSettingsSheetFrame] 的一套并固定下来：
/// 顶部圆角 22、标题 19sp w600、关闭图标 Lucide x 20、拖拽柄 36×4。
/// 历史上弹层圆角有 12/16/20/22/24 五套、标题字号五套、关闭图标四种，
/// 新增弹层一律走这里；`homeSheetShape` 的默认 24 保留给已上线的旧调用方。
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

  /// 统一的弹层顶部圆角（与阅读设置面板一致）。
  static const double radius = 22;

  /// 统一的弹层标题字号。
  static const double titleFontSize = 19;

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
    // 键盘 + 手势条：内容不压在输入法或系统导航条下面。
    final bottomInset =
        MediaQuery.viewInsetsOf(context).bottom +
        MediaQuery.paddingOf(context).bottom;
    return AnimatedContainer(
      // 墨水屏：插值动画会留残影，面板直接跳变。
      duration: palette.eink
          ? Duration.zero
          : const Duration(milliseconds: 160),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * maxHeightFactor,
      ),
      decoration: BoxDecoration(
        color: homeSheetColor(palette),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(radius)),
        // 只描上缘：弹层底边贴着屏幕，画一圈会在手势条上方多一条线。
        border: Border(top: homeSheetShape(palette, top: radius).side),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showHandle) _handle(palette),
              _header(context, palette),
              Flexible(
                child: SingleChildScrollView(
                  key: scrollKey,
                  padding: contentPadding,
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
    );
  }

  Widget _handle(HomePalette palette) => Container(
    margin: const EdgeInsets.only(top: 10, bottom: 4),
    width: 36,
    height: 4,
    decoration: BoxDecoration(
      color: palette.muted.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(2),
    ),
  );

  Widget _header(BuildContext context, HomePalette palette) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 8, 2),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.ink,
              fontSize: titleFontSize,
              fontWeight: FontWeight.w600,
            ),
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
  );
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
