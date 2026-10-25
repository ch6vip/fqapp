import 'package:flutter/material.dart';

/// 播放页右侧浮层的统一形态：贴右缘、全高、左圆角 12、200ms 从右滑入、
/// 0.5 遮罩，宽度约为窗口的三分之一（夹在 240–420dp）。
///
/// 选集抽屉（chrome 内联 `Positioned(right: 0)`）、视频设置、弹幕设置、
/// 同系列都走这一份几何——之前各自算宽度/各自让安全区，横屏带挖孔的设备
/// 上会出现「设置面板比选集抽屉窄一截、还离屏幕边留着一条缝」的错位。
///
/// 安全区的处理方式与选集抽屉一致：**底色铺满到屏幕边**，让开摄像头/
/// 挖孔的是面板内容自己的 `SafeArea`。外圈再包一层 padding 会把整块面板
/// 推离屏幕边线，和抽屉对不齐。
class PlayerSidePanel {
  const PlayerSidePanel._();

  /// 面板宽度：窗口的三分之一，夹在 240–420dp（800 宽 → 266.67）。
  static double widthFor(double windowWidth) =>
      (windowWidth / 3).clamp(240.0, 420.0);

  /// 从右侧滑入一个面板。`builder` 拿到的 context 属于面板自身路由，
  /// 面板内容需要自己让开安全区（`SafeArea`）。
  static Future<T?> show<T>({
    required BuildContext context,
    required Color background,
    required WidgetBuilder builder,
    String barrierLabel = '关闭',
  }) => showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: barrierLabel,
    barrierColor: const Color(0x80000000),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, _, _) => LayoutBuilder(
      // 宽度按路由自己的约束量：`MediaQuery.size` 是整块屏的尺寸，页面被
      // 嵌在别处（桌面窄窗、测试 surface）时两者并不相等。
      builder: (context, constraints) => Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          key: const ValueKey('player-side-panel'),
          width: widthFor(constraints.maxWidth),
          height: double.infinity,
          child: Material(
            color: background,
            clipBehavior: Clip.antiAlias,
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(12),
            ),
            child: builder(context),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

/// 右侧面板的标题行：64dp 高、左侧 ✕、居中标题。
///
/// 与选集抽屉 `StoryEpisodeDrawer` 的头逐像素同款：三个面板的标题和关闭
/// 按钮必须落在同一条线上，否则「选集」有 64dp 标题栏、设置面板的内容
/// 直接从屏幕顶边开始，并排切换时看着就是错位。
class PlayerSidePanelHeader extends StatelessWidget {
  const PlayerSidePanelHeader({
    super.key,
    required this.title,
    this.onClose,
    this.color = Colors.white,
    this.trailing,
  });

  final String title;
  final VoidCallback? onClose;

  /// 标题与 ✕ 的颜色；浅色主题的面板传自己的前景色。
  final Color color;

  /// 右侧位（选集抽屉放「同系列」入口）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 64,
    child: Stack(
      children: [
        if (onClose != null)
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              key: const ValueKey('player-side-panel-close'),
              tooltip: '关闭',
              onPressed: onClose,
              icon: Icon(Icons.close, color: color),
            ),
          ),
        Align(
          alignment: Alignment.center,
          child: Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
        if (trailing != null)
          Align(alignment: Alignment.centerRight, child: trailing!),
      ],
    ),
  );
}

/// 横屏右侧面板之间的跳转出口。
///
/// 面板一律 `Navigator.pop(context, route)` 交回宿主：宿主用一个循环决定
/// 「接下来开哪一块」，所以二级面板关闭时能重新落回视频设置，而不是直接
/// 掉回画面。[more] 是「返回上一层视频设置」，其余值表示打开对应二级面板；
/// `pop(null)` 表示关到底。
enum PlayerSidePanelRoute { more, danmakuSettings, fontScale }

/// 右侧面板里的标准行：48dp 高、图标 + 文案 + 尾注 + 箭头/开关。
///
/// 只承载「进二级面板」和「带开关」两类行：倍速/清晰度的六档选项在
/// 240–420dp 的窄面板里铺不开，横屏改成底条直连的独立档位面板。
class PlayerSidePanelRow extends StatelessWidget {
  const PlayerSidePanelRow({
    super.key,
    required this.rowKey,
    required this.label,
    this.leading,
    this.icon,
    this.value,
    this.onTap,
    this.switchValue,
    this.onToggle,
    this.switchKey,
    this.bright = false,
    this.chevron = true,
  });

  /// 行 key（渲染成 `ValueKey(rowKey)`，测试与既有断言对齐）。
  final String rowKey;
  final String label;

  /// 自定义图标（清晰度用画笔，不传则用 [icon] 的图片资源）。
  final Widget? leading;

  /// `assets/images/drama/more_<icon>.webp` 的资源名。
  final String? icon;

  /// 行尾当前值（倍速「1.0x」、清晰度「1080P」、字号「标准」）。
  final String? value;

  final VoidCallback? onTap;

  /// 非空时行尾画开关而不是箭头。
  final bool? switchValue;
  final VoidCallback? onToggle;

  /// 开关自己的 key（`player-more-danmaku-switch` 之类，测试按它点）。
  final String? switchKey;

  /// 当前档/开启态的强调色（品牌橙）。
  final bool bright;

  /// 行尾是否画箭头：只有点开会进二级面板的行才该有；清屏、听视频、
  /// 离线缓存点了就执行，挂箭头会让人以为还能下一层。
  final bool chevron;

  static const accent = Color(0xFFFA6725);

  @override
  Widget build(BuildContext context) {
    final row = SizedBox(
      height: 48,
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 10),
          ] else if (icon != null) ...[
            Image.asset(
              'assets/images/drama/more_$icon.webp',
              width: 24,
              height: 24,
              color: Colors.white,
              excludeFromSemantics: true,
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, color: Colors.white),
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 96),
              child: Text(
                value!,
                key: ValueKey('$rowKey-value'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 13,
                  color: bright ? accent : const Color(0x99FFFFFF),
                ),
              ),
            ),
          ],
          if (switchValue != null) ...[
            const SizedBox(width: 10),
            _SidePanelSwitch(
              key: switchKey == null ? null : ValueKey(switchKey!),
              value: switchValue!,
            ),
          ] else if (chevron)
            const Icon(Icons.chevron_right, size: 20, color: Color(0x66FFFFFF)),
        ],
      ),
    );
    final tap = switchValue != null ? onToggle : onTap;
    return Semantics(
      key: ValueKey('$rowKey-row'),
      label: label,
      // 开关行是「可切换的开关」，不是按钮：无障碍树里带 isButton 会让
      // 读屏把它念成按钮而不是开关。
      button: switchValue == null ? true : null,
      toggled: switchValue,
      onTap: tap,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey(rowKey),
        onTap: tap,
        excludeFromSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: row,
        ),
      ),
    );
  }
}

/// 右侧面板的 31×18 开关（与更多面板的 `SwitchButtonV2` 同形）。
class _SidePanelSwitch extends StatelessWidget {
  const _SidePanelSwitch({super.key, required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 300),
    width: 31,
    height: 18,
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: value ? PlayerSidePanelRow.accent : const Color(0x33FFFFFF),
      borderRadius: BorderRadius.circular(9),
    ),
    child: AnimatedAlign(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      child: const DecoratedBox(
        decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        child: SizedBox.square(dimension: 14),
      ),
    ),
  );
}

/// 右侧面板里的一块圆角卡片：默认 12dp 圆角、贴着 #141414 面板底的一层
/// 半透明白（官方深色卡片的等价翻色），上下各 4dp 呼吸。
///
/// 面板底色与选集抽屉同为 #141414，行与行之间只靠一条发丝线分隔时整块看着
/// 像一堵墙；卡片把「进二级的行」单独归位，和竖屏白卡的层次一致。
class PlayerSidePanelCard extends StatelessWidget {
  const PlayerSidePanelCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: const Color(0x14FFFFFF),
      borderRadius: BorderRadius.circular(12),
    ),
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(mainAxisSize: MainAxisSize.min, children: children),
  );
}

/// 右侧面板里的方块入口：图标在上、文案在下，开关态用橙色描出来。
///
/// 横屏面板只有 240–420dp 宽、361dp 高，整行长列表放不下九项（弹幕、字号
/// 得靠滚动才能看见）。开关与「点了就执行」的入口压成三列宫格后一屏放得
/// 下；会进二级面板的行仍用 [PlayerSidePanelRow]，行尾带当前值。
class PlayerSidePanelTile extends StatelessWidget {
  const PlayerSidePanelTile({
    super.key,
    required this.tileKey,
    required this.label,
    this.icon,
    this.leading,
    this.active = false,
    this.stateKey,
    this.onTap,
  });

  /// 块 key（渲染成 `ValueKey(tileKey)`，语义节点是 `<tileKey>-row`）。
  final String tileKey;
  final String label;

  /// `assets/images/drama/more_<icon>.webp` 的资源名。
  final String? icon;

  /// 自定义图标（清晰度用画笔，不传则用 [icon] 的图片资源）。
  final Widget? leading;

  /// 开关类入口的开启态：图标与文案转品牌橙、底上加一层橙。
  final bool active;

  /// 开关态节点的 key（测试按它点/读 `toggled`）；非开关入口留空。
  final String? stateKey;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? PlayerSidePanelRow.accent : Colors.white;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null)
          SizedBox(width: 24, height: 24, child: leading)
        else if (icon != null)
          Image.asset(
            'assets/images/drama/more_$icon.webp',
            width: 24,
            height: 24,
            color: color,
            excludeFromSemantics: true,
          ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          // 大字号（系统放大到 2.5 倍）下标签换到第二行、块自己长高，
          // 不再被 68dp 固定高度挤出黄黑条纹；宫格整体在 ListView 里可滚。
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.2, color: color),
          ),
        ),
      ],
    );
    return Semantics(
      key: ValueKey('$tileKey-row'),
      label: label,
      // 开关块在无障碍树里是「可切换」，不是按钮。
      button: stateKey == null ? true : null,
      toggled: stateKey == null ? null : active,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey(tileKey),
        onTap: onTap,
        excludeFromSemantics: true,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          key: stateKey == null ? null : ValueKey(stateKey!),
          duration: const Duration(milliseconds: 200),
          constraints: const BoxConstraints(minHeight: 68),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? const Color(0x24FA6725) : const Color(0x0DFFFFFF),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(child: content),
        ),
      ),
    );
  }
}

/// 二级选项面板的单项。
class PlayerSidePanelOption<T> {
  const PlayerSidePanelOption({required this.label, required this.value});

  final String label;
  final T value;
}

/// 二级选项面板（倍速 / 清晰度）：标题行 + 单选列表，选中档橙色 + 对勾。
///
/// 底部弹层那套药丸行在 240–420dp 的窄面板里只能露出两三档，换成整行
/// 列表后每档都点得到、当前档也不用横向滚出来。
///
/// 选中即 `pop(option.value)`，由宿主接收；✕ 走 [onBack]（**必传**）。
/// 早期还有「嵌在 [PlayletSideSettingsFlow] 里传回调、不 pop」的用法，那套
/// 已由 flow 自己的 `onStep` 换层取代，回调参数随之删除——留着它会让默认
/// 关闭分支的 `pop(PlayerSidePanelRoute.more)` 与 `Route<T>` 的类型对不上。
class PlayerSidePanelOptionList<T> extends StatelessWidget {
  const PlayerSidePanelOptionList({
    super.key,
    required this.title,
    required this.options,
    required this.isSelected,
    required this.onBack,
    this.panelKey = 'player-side-options',
  });

  final String title;
  final List<PlayerSidePanelOption<T>> options;
  final bool Function(T value) isSelected;
  final String panelKey;

  /// ✕ 的行为：收起这一层（回到上一层或直接关掉整条路由）。
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return SafeArea(
      // 面板贴右缘：左边那条安全区属于屏幕另一侧，让开会把整列右推。
      left: false,
      child: Column(
        children: [
          PlayerSidePanelHeader(title: title, onClose: onBack),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.only(bottom: 8 + bottom),
              itemCount: options.length,
              itemBuilder: (context, index) {
                final option = options[index];
                final selected = isSelected(option.value);
                return InkWell(
                  key: ValueKey('$panelKey-$index'),
                  onTap: () => Navigator.pop(context, option.value),
                  child: SizedBox(
                    height: 48,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              option.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                color: selected
                                    ? PlayerSidePanelRow.accent
                                    : Colors.white,
                              ),
                            ),
                          ),
                          if (selected)
                            const Icon(
                              Icons.check,
                              size: 18,
                              color: PlayerSidePanelRow.accent,
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
