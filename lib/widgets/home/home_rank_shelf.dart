import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_detail.dart' show formatCounter;
import '../../models/media_item.dart';
import '../../services/app_style_tokens.dart';
import '../../services/poster_cache.dart';
import 'home_archive.dart';
import 'home_design.dart';
import 'home_media_card.dart';
import 'home_rank_scroll_physics.dart';

// 排行榜的立体书架。
//
// 参照 Wenku8_Flutter 发现页的 archive shelf：一排在斜向投影里排开的书，
// 当前那本从书架里抽出来、侧面露出封面，名次印在书脊上。这里用
// CustomPainter 自绘（不为每本书建 widget），上面铺一层透明的横向滚动区
// 负责手势和吸附；颜色、减少动效、墨水屏都走同一套几何。
//
// 几何与抽出波形参考 mikufoxxx/Wenku8_Flutter 的 ebcd7f1（GPL-3.0）；
// 这里保留有限排行榜，不复制上游循环书架的虚拟名次。

const double _shelfMaxWidth = 520;

class _ShelfGeometry {
  const _ShelfGeometry({
    required this.width,
    required this.spine,
    required this.pitch,
    required this.cover,
    required this.bodyHeight,
    required this.base,
    required this.anchor,
    required this.height,
    required this.scale,
    required this.flatHeight,
  });

  final double width;
  final double spine;
  final double pitch;
  final double cover;
  final double bodyHeight;
  final double height;
  final double scale;
  final double flatHeight;

  double get flatCover => (width * .29).clamp(96.0, 118.0);
  // Preserve book proportions in paint units; scrolling uses screen units.
  double get paintWidth => width / scale;
  double get paintPitch => pitch / scale;

  /// 未被抽出时书脊的顶边 y。
  final double base;

  /// 未抽出书脊的锚点；当前书抽出后，完整投影恰好居中。
  final double anchor;

  factory _ShelfGeometry.of(
    double width, {
    double maxHeight = double.infinity,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    width = math.min(width, _shelfMaxWidth);
    final spine = (width * 0.043).clamp(14.0, 18.0);
    final cover = (width * 0.32).clamp(100.0, 128.0);
    final bodyHeight = (cover - 20) * 166 / 118 + 54;
    final base = cover * 0.30 + bodyHeight * 0.60 + 12;
    final naturalHeight = base + bodyHeight + 60;
    final height = math.min(naturalHeight, math.max(200.0, maxHeight));
    final scale = height / naturalHeight;
    final flatCover = (width * .29).clamp(96.0, 118.0);
    return _ShelfGeometry(
      width: width,
      spine: spine,
      pitch: (spine + 11) * scale,
      cover: cover,
      bodyHeight: bodyHeight,
      base: base,
      anchor: (width / scale - spine - cover * 0.66) / 2 + cover * 0.84 * 0.66,
      height: height,
      scale: scale,
      flatHeight: math.max(
        flatCover * 1.4 + textScaler.scale(8) * 1.35 + 22,
        math.min(math.max(240.0, bodyHeight + 48), height),
      ),
    );
  }

  /// 斜向纵深：封面向右上方退去的投影向量。
  double get depthX => cover * 0.66;
  double get depthY => cover * -0.30;

  double contentWidth(int count) =>
      math.max(width, (count - 1) * pitch + width);

  (int, int) visibleRange(double focus, int count) => (
    math.max(0, (focus - (anchor + spine + depthX) / paintPitch).floor()),
    math.min(
      count - 1,
      (focus + (paintWidth - anchor + cover * 0.84 * 0.66) / paintPitch).ceil(),
    ),
  );

  Path outline(_Pose pose) => Path()
    ..moveTo(pose.x, pose.y)
    ..lineTo(pose.x + depthX, pose.y + depthY)
    ..lineTo(pose.x + spine + depthX, pose.y + depthY)
    ..lineTo(pose.x + spine + depthX, pose.y + depthY + bodyHeight)
    ..lineTo(pose.x + spine, pose.y + bodyHeight)
    ..lineTo(pose.x, pose.y + bodyHeight)
    ..close();
}

class _Pose {
  const _Pose(this.weight, this.x, this.y);
  final double weight;
  final double x;
  final double y;
}

_Pose _poseAt(int index, double focus, _ShelfGeometry g) {
  final d = index - focus;
  const radius = 1.48;
  final crest = d.abs() < radius ? math.cos(d / radius * math.pi / 2) : 0.0;
  final weight = crest * crest;
  final rail = d.clamp(-7.0, 7.0);
  final pull = g.cover * 0.84 * weight * (1.24 - 0.24 * weight);
  final lift = weight * weight * (3 - 2 * weight);
  return _Pose(
    weight,
    g.anchor + d * g.paintPitch - pull * 0.66,
    g.base +
        rail * 2.5 +
        rail * rail * 0.45 +
        pull * 0.30 -
        g.bodyHeight * 0.60 * lift,
  );
}

/// 排行榜书架：书脊阵列 + 当前书的信息 + 翻页器。
class HomeRankShelf extends StatefulWidget {
  const HomeRankShelf({
    super.key,
    required this.books,
    required this.onOpen,
    this.stepped = false,
    this.flat = false,
  });

  final List<MediaItem> books;
  final ValueChanged<MediaItem> onOpen;

  /// 墨水屏 / 减少动效：不做连续波动，按整本切换。
  final bool stepped;

  /// 强制使用平面封面轨道（测试和低性能设备的显式入口）。
  ///
  /// 运行时探针判定设备吃力时会自动把 [degraded] 置位，之后所有书架都走
  /// 平面轨道；这里给测试和外部降级留一个人工开关。
  final bool flat;

  /// 本进程是否已因帧耗时过高降级到平面轨道。
  ///
  /// 进程级而非页面级：书架在首屏和切换榜单时都会重建，一旦判定吃力就没
  /// 必要每处再重新试探。
  static bool degraded = false;

  static _ShelfGeometry _geometryFor(BuildContext context, double width) {
    final media = MediaQuery.of(context);
    final viewport = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    final viewportHeight = viewport != null && viewport.hasViewportDimension
        ? viewport.viewportDimension
        : media.size.height - media.padding.top;
    // Reserve a quarter of the feed for its headings, plus the dock and the
    // unscaled controls. Keep a readable rail on short or large-text screens.
    final available =
        (viewportHeight - media.padding.bottom) * .75 -
        _InfoRow.heightFor(media.textScaler) -
        _Pager.heightFor(media.textScaler) -
        8;
    return _ShelfGeometry.of(
      width,
      maxHeight: available,
      textScaler: media.textScaler,
    );
  }

  static double loadingHeight(BuildContext context, double width) {
    final geometry = _geometryFor(context, width);
    final scaler = MediaQuery.textScalerOf(context);
    return (degraded ? geometry.flatHeight : geometry.height) +
        _InfoRow.heightFor(scaler) +
        _Pager.heightFor(scaler);
  }

  @override
  State<HomeRankShelf> createState() => _HomeRankShelfState();
}

class _HomeRankShelfState extends State<HomeRankShelf> {
  final ScrollController _scroll = ScrollController(keepScrollOffset: false);
  final Map<String, ui.Image> _images = {};
  final Map<String, ImageStream> _streams = {};
  final Map<String, ImageStreamListener> _listeners = {};

  ImageConfiguration _config = ImageConfiguration.empty;
  _ShelfGeometry? _geometry;
  int _focus = 0;
  bool _scrollAlignmentPending = false;
  int? _targetIndex;
  int _scrollCommand = 0;

  /// 平面封面轨道（低性能后备）的滚动控制器。
  ///
  /// 不用 [PageView]：`padEnds: false` 时最后一页到不了左对齐位，翻页器
  /// 能显示 12/12、轨道却停在 09/12。ListView + 吸附物理能让每本书都停在
  /// 轨道起点，和立体书架的名次口径一致。
  final ScrollController _flatScroll = ScrollController(
    keepScrollOffset: false,
  );
  double _flatPitch = 1;
  late bool _flat;

  // 低性能探针：预热若干帧后取中位帧耗时，超过阈值就永久降级。
  bool _probing = false;
  int _warmupFrames = 0;
  final List<double> _frameSamples = [];

  static const int _probeWarmup = 60;
  static const int _probeSampleCount = 90;

  /// 重建一层书架的中位帧耗时超过 40ms（25fps）就认为立体绘制吃力。
  /// 阈值故意保守：宁可多留一档动画，也不要误伤中端机。
  static const double _slowFrameMs = 40;

  @override
  void initState() {
    super.initState();
    _flat = widget.flat || HomeRankShelf.degraded;
    _scroll.addListener(_onScroll);
    _flatScroll.addListener(_onFlatScroll);
    _startProbe();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _config = createLocalImageConfiguration(context);
    _resolveImages();
  }

  @override
  void didUpdateWidget(covariant HomeRankShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.flat && !_flat) {
      _switchToFlat();
    }
    if (!_sameBooks(oldWidget.books, widget.books)) {
      // 换榜才回到第一本；同一批书的父级重建不能冲掉当前名次。
      _focus = 0;
      _scrollAlignmentPending = true;
      _targetIndex = null;
      _scrollCommand++;
      if (!_flat) {
        _releaseImages();
        _resolveImages();
      }
    }
  }

  @override
  void dispose() {
    _stopProbe();
    _flatScroll
      ..removeListener(_onFlatScroll)
      ..dispose();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _releaseImages();
    super.dispose();
  }

  /// 只在 release 里探测：debug 的帧耗时没有参考意义。
  void _startProbe() {
    if (_flat || widget.stepped || HomeRankShelf.degraded || !kReleaseMode) {
      return;
    }
    _probing = true;
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  void _stopProbe() {
    if (!_probing) return;
    _probing = false;
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    if (!mounted || !_probing) return;
    for (final timing in timings) {
      if (_warmupFrames < _probeWarmup) {
        _warmupFrames++;
        continue;
      }
      final total = timing.buildDuration + timing.rasterDuration;
      _frameSamples.add(total.inMicroseconds / 1000);
      if (_frameSamples.length >= _probeSampleCount) break;
    }
    if (_frameSamples.length < _probeSampleCount) return;
    _stopProbe();
    final sorted = List<double>.of(_frameSamples)..sort();
    if (sorted[sorted.length ~/ 2] < _slowFrameMs) return;
    HomeRankShelf.degraded = true;
    _switchToFlat();
  }

  void _switchToFlat() {
    if (_flat) return;
    _stopProbe();
    setState(() {
      _flat = true;
      _scrollAlignmentPending = true;
      _targetIndex = null;
      _scrollCommand++;
    });
    // 降级后平面轨道自己加载封面，3D 解好的图和流监听不再需要。
    _releaseImages();
  }

  /// 只为书架上的书解析封面；解析好的图交给 painter 直接画。
  ///
  /// 平面轨道由 [StoryCover] 自己加载封面，这里不重复解码。
  void _resolveImages() {
    if (_flat) return;
    for (final book in widget.books) {
      if (book.cover.isEmpty) continue;
      final key = _keyOf(book);
      if (_streams.containsKey(key)) continue;
      final provider = CachedNetworkImageProvider(
        book.cover,
        cacheManager: PosterCache.instance,
        maxWidth: 360,
      );
      final stream = provider.resolve(_config);
      final listener = ImageStreamListener((info, _) {
        if (!mounted || _flat || !identical(_streams[key], stream)) {
          info.dispose();
          return;
        }
        final previous = _images[key];
        setState(() => _images[key] = info.image);
        previous?.dispose();
      }, onError: (_, _) {});
      // 缓存命中时 addListener 会同步回调，必须先登记订阅。
      _streams[key] = stream;
      _listeners[key] = listener;
      stream.addListener(listener);
    }
  }

  void _releaseImages() {
    for (final entry in _streams.entries) {
      final listener = _listeners[entry.key];
      if (listener != null) entry.value.removeListener(listener);
    }
    _streams.clear();
    _listeners.clear();
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
  }

  /// 两批书是不是同一个榜单。只比顺序和身份，不比对象实例：父级重建会
  /// 重新 `flatten()` 出新的 List，但榜单并没有换。
  static bool _sameBooks(List<MediaItem> a, List<MediaItem> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].kind != b[i].kind) return false;
    }
    return true;
  }

  void _onScroll() {
    final geometry = _geometry;
    if (_flat ||
        _scrollAlignmentPending ||
        geometry == null ||
        !_scroll.hasClients) {
      return;
    }
    final next = (_scroll.offset / geometry.pitch)
        .round()
        .clamp(0, math.max(0, widget.books.length - 1))
        .toInt();
    if (next != _focus) setState(() => _focus = next);
  }

  void _onFlatScroll() {
    if (!_flat ||
        _scrollAlignmentPending ||
        !_flatScroll.hasClients ||
        _flatPitch <= 0) {
      return;
    }
    final next = (_flatScroll.offset / _flatPitch)
        .round()
        .clamp(0, math.max(0, widget.books.length - 1))
        .toInt();
    if (next != _focus) setState(() => _focus = next);
  }

  void _alignScrollAfterLayout(Duration _) {
    if (!mounted || !_scrollAlignmentPending || widget.books.isEmpty) return;
    final geometry = _geometry;
    final controller = _flat ? _flatScroll : _scroll;
    if (geometry == null ||
        !controller.hasClients ||
        !controller.position.hasContentDimensions) {
      return;
    }
    final index = _focus.clamp(0, widget.books.length - 1);
    final pitch = _flat ? _flatPitch : geometry.pitch;
    final position = controller.position;
    _targetIndex = null;
    _scrollCommand++;
    _scrollAlignmentPending = false;
    controller.jumpTo(
      (index * pitch).clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  static String _keyOf(MediaItem item) => '${item.kind}:${item.id}';

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final books = widget.books;
    if (books.isEmpty) return const SizedBox.shrink();
    final index = _focus.clamp(0, books.length - 1);
    return Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _shelfMaxWidth),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final geometry = HomeRankShelf._geometryFor(
              context,
              constraints.maxWidth,
            );
            if (_geometry?.width != geometry.width ||
                _geometry?.pitch != geometry.pitch) {
              _scrollAlignmentPending = true;
            }
            _geometry = geometry;
            if (_scrollAlignmentPending) {
              // 换轨道或改宽度后，等新布局就绪再对齐，期间不让旧偏移改写焦点。
              WidgetsBinding.instance.addPostFrameCallback(
                _alignScrollAfterLayout,
              );
            }
            final scaler = MediaQuery.textScalerOf(
              context,
            ).clamp(minScaleFactor: 1, maxScaleFactor: 1.3);
            if (_flat) {
              return _buildFlat(context, palette, books, geometry);
            }
            final volumes = [
              for (var i = 0; i < books.length; i++)
                _Volume.build(
                  books[i],
                  i,
                  geometry,
                  palette,
                  scaler,
                  _images[_keyOf(books[i])],
                ),
            ];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: geometry.height,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) =>
                        _handleTap(details.localPosition, geometry),
                    child: ClipRect(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: RepaintBoundary(
                              child: CustomPaint(
                                painter: _ShelfPainter(
                                  controller: _scroll,
                                  books: books,
                                  volumes: volumes,
                                  geometry: geometry,
                                  palette: palette,
                                  coverRadius: AppStyleTokens.of(
                                    context,
                                  ).coverRadius,
                                  stepped: widget.stepped,
                                ),
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: NotificationListener<ScrollNotification>(
                              onNotification: _onScrollNotification,
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                controller: _scroll,
                                physics: widget.stepped
                                    ? const ClampingScrollPhysics()
                                    : HomeRankScrollPhysics(
                                        pitchFor: (_) => _geometry!.pitch,
                                      ),
                                child: SizedBox(
                                  width: geometry.contentWidth(books.length),
                                  height: geometry.height,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                _InfoRow(book: books[index], onOpen: () => _open(index)),
                _Pager(
                  index: index,
                  count: books.length,
                  readLabel: _readLabel(books[index]),
                  onPrevious: () => _step(-1),
                  onNext: () => _step(1),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 低性能后备：一条平面封面轨道，不画立体书架和透视。
  ///
  /// 横向 ListView 按页宽吸附，信息行和翻页器与立体书架共用；唯一
  /// 的区别是每一本只有封面和顶部编号，没有书脊、侧封和方格纸。
  Widget _buildFlat(
    BuildContext context,
    HomePalette palette,
    List<MediaItem> books,
    _ShelfGeometry geometry,
  ) {
    final index = _focus.clamp(0, books.length - 1);
    final coverRadius = AppStyleTokens.of(context).coverRadius;
    final innerWidth = math.max(1.0, geometry.width - 32);
    const gap = 12.0;
    final pitch = geometry.flatCover + gap;
    _flatPitch = pitch;
    // 尾部补足「视口宽 - 一页宽」：最后一本也能停在左对齐位。少了这段，
    // 最大偏移只够把末本露出来，名次却到不了最后。
    final trailing = math.max(0.0, innerWidth - pitch);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: geometry.flatHeight,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: ListView.builder(
              key: const Key('home_rank_flat_rail'),
              controller: _flatScroll,
              scrollDirection: Axis.horizontal,
              itemExtent: pitch,
              physics: widget.stepped
                  ? const ClampingScrollPhysics()
                  : HomeRankScrollPhysics(
                      pitchFor: (width) =>
                          _ShelfGeometry.of(width).flatCover + gap,
                    ),
              padding: EdgeInsets.only(left: 16, right: 16 + trailing),
              itemCount: books.length,
              itemBuilder: (context, i) {
                final book = books[i];
                return Center(
                  child: HomePressable(
                    onTap: () => _open(i),
                    semanticLabel: '打开 ${book.title}',
                    borderRadius: BorderRadius.circular(coverRadius),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        HomeCode(
                          'NO.${(i + 1).toString().padLeft(3, '0')}',
                          size: 8,
                          color: palette.ink,
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: geometry.flatCover,
                          child: AspectRatio(
                            aspectRatio: 5 / 7,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(coverRadius),
                              child: StoryCover(
                                item: book,
                                cacheWidth:
                                    (geometry.flatCover *
                                            MediaQuery.devicePixelRatioOf(
                                              context,
                                            ))
                                        .ceil(),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        _InfoRow(book: books[index], onOpen: () => _open(index)),
        _Pager(
          index: index,
          count: books.length,
          readLabel: _readLabel(books[index]),
          onPrevious: () => _step(-1),
          onNext: () => _step(1),
        ),
      ],
    );
  }

  void _handleTap(Offset position, _ShelfGeometry geometry) {
    if (!_scroll.hasClients || _scrollAlignmentPending) return;
    position = position / geometry.scale;
    final raw = _scroll.offset / geometry.pitch;
    final focus = widget.stepped ? raw.roundToDouble() : raw;
    final (first, last) = geometry.visibleRange(focus, widget.books.length);
    // 从前往后命中整个实体，与 painter 的遮挡顺序一致，不能穿过前排点后排。
    for (var i = last; i >= first; i--) {
      final pose = _poseAt(i, focus, geometry);
      if (geometry.outline(pose).contains(position)) {
        if ((raw - i).abs() < .03 &&
            !_scroll.position.isScrollingNotifier.value) {
          _open(i);
        } else {
          unawaited(_centre(i));
        }
        return;
      }
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0 || _scrollAlignmentPending) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _targetIndex = null;
      _scrollCommand++;
    } else if (notification is ScrollEndNotification && widget.stepped) {
      unawaited(_centre(_focus, animate: false));
    }
    return false;
  }

  void _step(int delta) => unawaited(_centre((_targetIndex ?? _focus) + delta));

  void _open(int index) {
    if (widget.books.isEmpty) return;
    final next = index.clamp(0, widget.books.length - 1);
    final book = widget.books[next];
    unawaited(_centre(next, animate: false));
    widget.onOpen(book);
  }

  Future<void> _centre(int index, {bool animate = true}) async {
    final count = widget.books.length;
    final geometry = _geometry;
    if (count == 0 || geometry == null) return;
    final next = index.clamp(0, count - 1);
    final controller = _flat ? _flatScroll : _scroll;
    final command = ++_scrollCommand;
    _targetIndex = next;
    if (!controller.hasClients || _scrollAlignmentPending) {
      setState(() {
        _focus = next;
        _scrollAlignmentPending = true;
      });
      _targetIndex = null;
      return;
    }
    final target = (next * (_flat ? _flatPitch : geometry.pitch)).clamp(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    );
    if ((controller.offset - target).abs() < .01) {
      _targetIndex = null;
      if (!animate && controller.position.isScrollingNotifier.value) {
        controller.jumpTo(target);
      }
      return;
    }
    if (!animate || widget.stepped) {
      controller.jumpTo(target);
    } else {
      await controller.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: const Cubic(.2, 1.06, .35, 1),
      );
    }
    if (mounted && command == _scrollCommand) _targetIndex = null;
  }
}

/// 在读人数：上游可能给裸数字（`12345`）或现成文案（`286万人在读`）。
/// 前者先格式化成 `1.2万` 再补「人在读」，后者原样保留；没有数据时返回
/// 空串，信息行只留名次，不用媒介名冒充人数。
String _readLabel(MediaItem book) {
  final raw = book.readCount.trim();
  if (raw.isEmpty) return '';
  final text = formatCounter(raw);
  return text.endsWith('在读') ? text : '$text人在读';
}

/// 整个信息区都是打开入口；预留两行标题，换书时不推动下面的内容。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.book, required this.onOpen});

  final MediaItem book;
  final VoidCallback onOpen;

  static double heightFor(TextScaler scaler) =>
      16 + scaler.scale(17) * 1.35 * 2 + scaler.scale(12) * 1.4;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final status = switch (book.creationStatus) {
      0 => '完结',
      1 => '连载中',
      4 => '停更',
      _ => '',
    };
    final meta = [
      if (book.author.isNotEmpty) book.author,
      if (status.isNotEmpty) status,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: HomePressable(
        onTap: onOpen,
        semanticLabel: '打开 ${book.title}',
        borderRadius: BorderRadius.circular(
          AppStyleTokens.of(context).panelRadius,
        ),
        child: SizedBox(
          height: heightFor(MediaQuery.textScalerOf(context)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          height: 1.35,
                          fontWeight: FontWeight.w700,
                          color: palette.ink,
                        ),
                      ),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: palette.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ExcludeSemantics(
                  child: Icon(
                    LucideIcons.arrow_up_right,
                    size: 20,
                    color: palette.ink,
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

/// 名次与在读人数靠左，翻页动作靠右，不再占用单独的编号行。
class _Pager extends StatelessWidget {
  const _Pager({
    required this.index,
    required this.count,
    required this.readLabel,
    required this.onPrevious,
    required this.onNext,
  });

  final int index;
  final int count;
  final String readLabel;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  static double heightFor(TextScaler scaler) =>
      6 + math.max(36, scaler.scale(9) * 1.35);

  static String _pad(int value) => value.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final serial = (index + 1).toString().padLeft(3, '0');
    return SizedBox(
      height: heightFor(MediaQuery.textScalerOf(context)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 10, 2),
        child: Row(
          children: [
            Expanded(
              child: HomeCode(
                readLabel.isEmpty ? 'NO.$serial' : 'NO.$serial / $readLabel',
              ),
            ),
            const SizedBox(width: 8),
            _button(
              key: const Key('home_rank_previous'),
              icon: LucideIcons.chevron_left,
              label: '上一本',
              onTap: index > 0 ? onPrevious : null,
              palette: palette,
            ),
            Semantics(
              label: '第 ${index + 1} 本，共 $count 本',
              excludeSemantics: true,
              child: HomeCode(
                '${_pad(index + 1)} / ${_pad(count)}',
                color: palette.ink,
                align: TextAlign.center,
              ),
            ),
            _button(
              key: const Key('home_rank_next'),
              icon: LucideIcons.chevron_right,
              label: '下一本',
              onTap: index < count - 1 ? onNext : null,
              palette: palette,
            ),
          ],
        ),
      ),
    );
  }

  Widget _button({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    required HomePalette palette,
  }) {
    return IconButton(
      key: key,
      onPressed: onTap,
      tooltip: label,
      style: IconButton.styleFrom(
        foregroundColor: palette.ink,
        disabledForegroundColor: palette.muted.withValues(alpha: 0.35),
        fixedSize: const Size.square(36),
        minimumSize: const Size.square(36),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, size: 15),
    );
  }
}

/// 一本书在画布上的全部预排版结果（文字不逐帧重排）。
class _Volume {
  const _Volume({
    required this.rank,
    required this.title,
    required this.sideTitle,
    required this.sideRank,
    required this.sideRk,
    required this.sideAuthor,
    required this.image,
    required this.gradient,
  });

  final TextPainter rank;
  final TextPainter title;
  final TextPainter sideTitle;

  /// 侧封顶部的名次编号（`NO.001`）。
  final TextPainter sideRank;

  /// 侧封底部的档案号（`RK-00001`）。
  final TextPainter sideRk;

  /// 侧封封面图底部的作者名。
  final TextPainter sideAuthor;
  final ui.Image? image;
  final List<Color> gradient;

  static _Volume build(
    MediaItem item,
    int index,
    _ShelfGeometry g,
    HomePalette palette,
    TextScaler scaler,
    ui.Image? image,
  ) {
    final code = homeCodeStyle(palette, size: 7);
    final titleSize = scaler.scale(9);
    final maxChars = math.max(
      3,
      ((g.bodyHeight - 64) / (titleSize * 1.16)).floor(),
    );
    final sideRank = (index + 1).toString().padLeft(3, '0');
    final sideRk = (index + 1).toString().padLeft(5, '0');
    return _Volume(
      rank: _text(
        (index + 1).toString().padLeft(2, '0'),
        code,
        maxWidth: g.spine,
      ),
      title: _text(
        item.title,
        homeSerifStyle(
          size: titleSize,
          color: palette.ink,
          weight: FontWeight.w500,
          height: 1.16,
        ),
        maxWidth: math.max(1, g.spine - 2),
        align: TextAlign.center,
        maxLines: maxChars,
      ),
      sideTitle: _text(
        item.title,
        homeSerifStyle(
          size: scaler.scale(15),
          color: palette.eink ? Colors.black : const Color(0xF0FFFFFF),
        ),
        // 一行一个字：mockup 的侧封是竖排书名，不是横排换行。
        maxWidth: scaler.scale(16),
        align: TextAlign.right,
        maxLines: 8,
      ),
      sideRank: _text('NO.$sideRank', code, maxWidth: g.cover),
      sideRk: _text('RK-$sideRk', code, maxWidth: g.cover),
      sideAuthor: _text(
        item.author,
        TextStyle(
          fontSize: scaler.scale(8),
          height: 1.2,
          fontWeight: FontWeight.w500,
          color: palette.eink ? Colors.black : const Color(0xBFFFFFFF),
          shadows: palette.eink
              ? null
              : const [Shadow(color: Color(0x99000000), blurRadius: 2)],
        ),
        maxWidth: math.max(1, g.cover - 26),
        maxLines: 1,
      ),
      image: image,
      gradient: _fallbackGradient(item.kind),
    );
  }

  static TextPainter _text(
    String value,
    TextStyle style, {
    required double maxWidth,
    TextAlign align = TextAlign.left,
    int? maxLines,
  }) => TextPainter(
    text: TextSpan(text: value, style: style),
    textDirection: TextDirection.ltr,
    textAlign: align,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
  )..layout(maxWidth: maxWidth);

  static List<Color> _fallbackGradient(String kind) => switch (kind) {
    'video' => const [Color(0xFF734740), Color(0xFF242428)],
    'manju' => const [Color(0xFF8B557E), Color(0xFF35283D)],
    'manga' => const [Color(0xFF6F6887), Color(0xFF343349)],
    'audio' => const [Color(0xFF426C78), Color(0xFF233B42)],
    _ => const [Color(0xFF6A7964), Color(0xFF293C35)],
  };
}

class _ShelfPainter extends CustomPainter {
  _ShelfPainter({
    required this.controller,
    required this.books,
    required this.volumes,
    required this.geometry,
    required this.palette,
    required this.coverRadius,
    required this.stepped,
  }) : super(repaint: controller);

  final ScrollController controller;
  final List<MediaItem> books;
  final List<_Volume> volumes;
  final _ShelfGeometry geometry;
  final HomePalette palette;
  final double coverRadius;
  final bool stepped;

  @override
  void paint(Canvas canvas, Size size) {
    _paintGrid(canvas, size);
    canvas.save();
    canvas.scale(geometry.scale);
    final focus = _focus();
    final (first, last) = geometry.visibleRange(focus, books.length);
    for (var i = first; i <= last; i++) {
      _paintVolume(canvas, i, focus);
    }
    canvas.restore();
  }

  double _focus() {
    if (!controller.hasClients) return 0;
    final raw = controller.offset / geometry.pitch;
    return stepped ? raw.roundToDouble() : raw;
  }

  void _paintGrid(Canvas canvas, Size size) {
    final color = palette.grid;
    if (color.a == 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var y = 8.0; y < size.height; y += 44) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (var x = 0.0; x < size.width; x += 44) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  void _paintVolume(Canvas canvas, int index, double focus) {
    final g = geometry;
    final pose = _poseAt(index, focus, g);
    final volume = volumes[index];
    final x = pose.x;
    final y = pose.y;
    final ox = g.depthX;
    final oy = g.depthY;
    final front = palette.eink
        ? Colors.white
        : (palette.dark ? const Color(0xFF2D2D2D) : const Color(0xFFFDFCF8));
    final side = palette.eink
        ? Colors.white
        : (palette.dark ? const Color(0xFF323232) : const Color(0xFFF7F6F0));
    final top = palette.eink
        ? Colors.white
        : (palette.dark ? const Color(0xFF3A3A3A) : const Color(0xFFECEAE3));
    final stroke = palette.eink
        ? Colors.black
        : (palette.dark ? const Color(0x1AFFFFFF) : const Color(0x29000000));
    final strokeWidth = palette.eink ? 1.0 : 0.8;

    if (pose.weight > 0.05 && !palette.eink && !palette.oled) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(
            x + g.spine / 2 + ox * 0.5,
            y + g.bodyHeight + 16 + oy * 0.5,
          ),
          width: g.cover * 1.1,
          height: 18,
        ),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.10 * pose.weight)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }

    _quad(
      canvas,
      [
        Offset(x, y),
        Offset(x + g.spine, y),
        Offset(x + g.spine + ox, y + oy),
        Offset(x + ox, y + oy),
      ],
      top,
      stroke,
      strokeWidth,
    );

    _quad(
      canvas,
      [
        Offset(x + g.spine, y),
        Offset(x + g.spine + ox, y + oy),
        Offset(x + g.spine + ox, y + oy + g.bodyHeight),
        Offset(x + g.spine, y + g.bodyHeight),
      ],
      side,
      stroke,
      strokeWidth,
    );

    if (pose.weight > 0.25) _paintSideArt(canvas, volume, x, y, pose.weight);

    _quad(
      canvas,
      [
        Offset(x, y),
        Offset(x + g.spine, y),
        Offset(x + g.spine, y + g.bodyHeight),
        Offset(x, y + g.bodyHeight),
      ],
      front,
      stroke,
      strokeWidth,
    );

    final centreX = x + g.spine / 2;
    volume.title.paint(
      canvas,
      Offset(centreX - volume.title.width / 2, y + 24),
    );
    volume.rank.paint(canvas, Offset(centreX - volume.rank.width / 2, y + 7));

    if (!palette.isClassic) {
      final circle = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = palette.muted;
      canvas.drawCircle(Offset(centreX, y + g.bodyHeight - 12), 2.2, circle);
    }
  }

  /// 抽出后露出的侧封：有图就画图（斜切进侧面的平行四边形），没有就退到
  /// 按媒介取色的渐变加竖排书名；顶部 `NO.001`、底部 `RK-00001`、图上一行
  /// 作者，和 mockup 的 sideArt 同一套字段。
  void _paintSideArt(
    Canvas canvas,
    _Volume volume,
    double x,
    double y,
    double weight,
  ) {
    final g = geometry;
    final eink = palette.eink;
    final alpha = eink
        ? 1.0
        : math.min(1.0, (weight - 0.25) / 0.45).clamp(0.0, 1.0);
    canvas.save();
    final matrix = Matrix4.identity()
      ..setEntry(0, 0, 0.66)
      ..setEntry(1, 0, -0.30)
      ..setEntry(0, 3, x + g.spine)
      ..setEntry(1, 3, y);
    canvas.transform(matrix.storage);
    // 整块侧封统一乘透明度：编号、作者和封面图「一起被抽出来」。
    canvas.saveLayer(
      Rect.fromLTWH(0, 0, g.cover, g.bodyHeight),
      Paint()..color = Colors.white.withValues(alpha: alpha),
    );
    const margin = 9.0;
    final art = Rect.fromLTWH(
      margin,
      20,
      g.cover - margin * 2,
      g.bodyHeight - 46,
    );
    canvas.save();
    if (palette.isClassic) {
      canvas.clipRRect(
        RRect.fromRectAndRadius(art, Radius.circular(coverRadius)),
      );
    }
    final image = volume.image;
    if (image != null) {
      canvas.drawImageRect(
        image,
        _coverSource(image, art.width / art.height),
        art,
        Paint()..colorFilter = eink ? einkCoverFilter : null,
      );
      if (eink) {
        canvas.drawRect(
          art,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = Colors.black,
        );
      }
    } else if (eink) {
      canvas.drawRect(art, Paint()..color = Colors.white);
      canvas.drawRect(
        art,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = Colors.black,
      );
    } else {
      canvas.drawRect(
        art,
        Paint()
          ..shader = LinearGradient(
            // mockup 的侧封渐变从左上角打到「40% 宽、满高」，不是对角。
            begin: Alignment.topLeft,
            end: const Alignment(-0.2, 1),
            colors: volume.gradient,
          ).createShader(art),
      );
      volume.sideTitle.paint(
        canvas,
        Offset(art.right - volume.sideTitle.width - 9, art.top + 12),
      );
    }
    if (volume.sideAuthor.width > 0) {
      volume.sideAuthor.paint(canvas, Offset(art.left + 8, art.bottom - 16));
    }
    canvas.restore();
    volume.sideRank.paint(canvas, Offset(margin, 7));
    if (!palette.isClassic) {
      volume.sideRk.paint(canvas, Offset(margin, g.bodyHeight - 18));
    }
    canvas.restore();
    canvas.restore();
  }

  static Rect _coverSource(ui.Image image, double aspect) {
    final width = image.width.toDouble();
    final height = image.height.toDouble();
    if (width / height > aspect) {
      final target = height * aspect;
      return Rect.fromLTWH((width - target) / 2, 0, target, height);
    }
    final target = width / aspect;
    return Rect.fromLTWH(0, (height - target) / 2, width, target);
  }

  void _quad(
    Canvas canvas,
    List<Offset> points,
    Color fill,
    Color stroke,
    double strokeWidth,
  ) {
    final path = Path()..moveTo(points[0].dx, points[0].dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = stroke,
    );
  }

  @override
  bool shouldRepaint(_ShelfPainter oldDelegate) => true;
}
