import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../pages/audio_page.dart' show ReaderAudioBridge, VoicePickerOutcome;
import '../../services/listening_session.dart';
import '../../services/reader_preferences.dart';
import '../audio/audio_floating_glyphs.dart';
import 'reader_player_style.dart';

/// 阅读页控制条上方的听书胶囊：圆形封面（未听书显示「听」）/ 播放暂停 /
/// 更多（切换音色）/ 关闭。
///
/// 尺寸与全局悬浮胶囊一致（`AudioFloatingPlayer` 162×50、42dp 圆封面），
/// 但**不加**旋转封面与进出场动画：它随菜单一起显隐，自身动画只会和面板
/// 的滑入打架，墨水屏还会留残影。
class ReaderListenCapsule extends StatelessWidget {
  const ReaderListenCapsule({
    super.key,
    required this.listening,
    required this.playing,
    required this.preset,
    required this.onCover,
    required this.onToggle,
    this.onVoices,
    required this.onClose,
    this.cover,
    this.animate = true,
    this.busy = false,
  });

  /// 正在听**这本书**（不是「有任意会话」）。
  final bool listening;

  final bool playing;
  final ReaderThemePreset preset;

  /// 在听时的封面地址；空则画占位圆。
  final String? cover;

  final VoidCallback onCover;
  final VoidCallback onToggle;

  /// 打开音色面板。null = 不可用（未听书 / 系统朗读），按钮置灰。
  final VoidCallback? onVoices;
  final VoidCallback onClose;
  final bool animate;

  /// 章节正在加载或加载失败：播放键置灰，避免点了没反应。
  final bool busy;

  static const double width = 162;
  static const double height = 50;
  static const double coverSize = 42;
  static const double radius = 25;

  static const double _toggleWidth = 32;
  static const double _voicesWidth = 26;
  static const double _closeWidth = 24;

  bool get _eink => preset == ReaderThemePreset.eink;

  @override
  Widget build(BuildContext context) {
    final ink = preset.playerText;
    final voiceEnabled = onVoices != null;
    return Semantics(
      container: true,
      label: '听书控制',
      child: Material(
        key: const ValueKey('reader-listen-capsule'),
        color: preset.playerBackground,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          width: width,
          height: height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 4),
              _Zone(
                zoneKey: 'reader-listen-cover',
                semantics: listening ? '打开听书页' : '从本页开始听',
                width: coverSize,
                onTap: onCover,
                child: _cover(context, ink),
              ),
              const SizedBox(width: 12),
              _Zone(
                zoneKey: 'reader-listen-toggle',
                semantics: playing ? '暂停播放' : '继续播放',
                width: _toggleWidth,
                onTap: busy ? null : onToggle,
                child: Opacity(
                  opacity: busy ? 0.4 : 1,
                  child: _toggle(context, ink),
                ),
              ),
              const SizedBox(width: 8),
              _Zone(
                zoneKey: 'reader-listen-voices',
                semantics: voiceEnabled ? '切换音色' : '开始听书后可切换音色',
                width: _voicesWidth,
                onTap: onVoices,
                child: Opacity(
                  opacity: voiceEnabled ? 1 : 0.4,
                  child: CustomPaint(
                    size: const Size(16, 16),
                    painter: MoreGlyph(ink),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _Zone(
                zoneKey: 'reader-listen-close',
                semantics: listening ? '停止播放' : '收起菜单',
                width: _closeWidth,
                onTap: onClose,
                child: CustomPaint(
                  size: const Size(16, 16),
                  painter: CloseGlyph(ink),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// 42dp 圆：在听显示封面，未听显示「听」。
  Widget _cover(BuildContext context, Color ink) {
    final placeholder = Container(
      width: coverSize,
      height: coverSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // 墨水屏不能叠半透明：会掉成一块灰，直接白底黑边。
        color: _eink ? Colors.white : ink.withValues(alpha: 0.16),
        border: _eink ? Border.all(color: Colors.black, width: 1.5) : null,
      ),
    );
    if (!listening) {
      return DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _eink ? Colors.white : ink.withValues(alpha: 0.16),
          border: _eink ? Border.all(color: Colors.black, width: 1.5) : null,
        ),
        child: SizedBox(
          width: coverSize,
          height: coverSize,
          child: Center(
            child: Text(
              '听',
              style: TextStyle(
                color: ink,
                fontSize: MediaQuery.textScalerOf(
                  context,
                ).scale(18).clamp(14.0, 22.0),
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ),
        ),
      );
    }
    final url = cover;
    if (url == null || url.isEmpty) return placeholder;
    return ClipOval(
      child: SizedBox(
        width: coverSize,
        height: coverSize,
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          memCacheWidth: (coverSize * MediaQuery.devicePixelRatioOf(context))
              .round(),
          fadeInDuration: Duration.zero,
          placeholder: (_, _) => placeholder,
          errorWidget: (_, _, _) => placeholder,
        ),
      ),
    );
  }

  /// 播放环 + 暂停/播放图标（复用全局胶囊的 painter，视觉一致）。
  Widget _toggle(BuildContext context, Color ink) => SizedBox(
    width: _toggleWidth,
    height: height,
    child: Center(
      child: SizedBox(
        width: 32,
        height: 32,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size(32, 32),
              painter: RingPainter(progress: 0, color: ink),
            ),
            CustomPaint(
              size: const Size(14, 14),
              painter: playing ? PauseGlyph(ink) : PlayGlyph(ink),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 一个可点击区域：无 ripple、无 tooltip，与全局胶囊一致。
class _Zone extends StatelessWidget {
  const _Zone({
    required this.zoneKey,
    required this.semantics,
    required this.width,
    required this.onTap,
    required this.child,
  });

  final String zoneKey;
  final String semantics;
  final double width;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    label: semantics,
    child: GestureDetector(
      key: ValueKey(zoneKey),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: ReaderListenCapsule.height,
        child: Center(child: ExcludeSemantics(child: child)),
      ),
    ),
  );
}

/// 状态宿主：订阅 [ListeningSession]，把四个区域接到 [ReaderAudioBridge]。
///
/// 只在「书 / 播放态 / 播完」三元组变化时才重建 —— 会话每秒都会通知一次进度，
/// 整颗胶囊跟着重建没有必要。
class ReaderListenCapsuleHost extends StatefulWidget {
  const ReaderListenCapsuleHost({
    super.key,
    required this.bookId,
    required this.preset,
    required this.animate,
    required this.onStartFromPage,
    required this.onCollapse,
    this.cover,
    this.busy = false,
  });

  final String bookId;
  final ReaderThemePreset preset;
  final bool animate;
  final String? cover;

  /// 未听书时点播放/封面：从本页开始播放。
  final VoidCallback onStartFromPage;

  /// 未听书时点 ×：收起菜单。
  final VoidCallback onCollapse;

  /// 章节加载中 / 出错：播放键置灰。
  final bool busy;

  @override
  State<ReaderListenCapsuleHost> createState() =>
      _ReaderListenCapsuleHostState();
}

class _ReaderListenCapsuleHostState extends State<ReaderListenCapsuleHost> {
  (String?, bool, bool) _snapshot = (null, false, false);

  @override
  void initState() {
    super.initState();
    _snapshot = _read();
    ListeningSession.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    ListeningSession.instance.removeListener(_onChanged);
    super.dispose();
  }

  (String?, bool, bool) _read() {
    final session = ListeningSession.instance;
    final active = session.matchesBook(widget.bookId) && !session.completed;
    return (session.bookId, active && session.playing, session.completed);
  }

  void _onChanged() {
    final next = _read();
    if (next == _snapshot) return;
    setState(() => _snapshot = next);
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final session = ListeningSession.instance;
    // 真人讲书的「边听边读」打开原著时，会话按音频书 id 记账、别名到原著 id。
    final listening = session.matchesBook(widget.bookId) && !session.completed;
    return ReaderListenCapsule(
      listening: listening,
      playing: listening && session.playing,
      preset: widget.preset,
      animate: widget.animate,
      busy: widget.busy,
      cover: widget.cover,
      onCover: () {
        if (!listening) {
          widget.onStartFromPage();
          return;
        }
        ReaderAudioBridge.openPage(context, widget.bookId);
      },
      onToggle: () {
        if (!listening) {
          widget.onStartFromPage();
          return;
        }
        if (!ReaderAudioBridge.toggle(context, widget.bookId)) {
          _toast('当前播放尚未就绪，请稍后重试');
        }
      },
      onVoices: listening
          ? () async {
              final outcome = await ReaderAudioBridge.openVoiceSettings(
                context,
                widget.bookId,
              );
              if (!mounted) return;
              switch (outcome) {
                case VoicePickerOutcome.changed:
                  _toast('已切换声音');
                case VoicePickerOutcome.unavailable:
                  _toast('暂时无法获取音色列表');
                case VoicePickerOutcome.failed:
                  _toast('切换失败，请稍后重试');
                case VoicePickerOutcome.dismissed:
                  break;
              }
            }
          : null,
      onClose: () async {
        if (!listening) {
          widget.onCollapse();
          return;
        }
        final stopped = await ReaderAudioBridge.stop(context, widget.bookId);
        if (!stopped && mounted) _toast('停止播放失败，请稍后重试');
      },
    );
  }
}
