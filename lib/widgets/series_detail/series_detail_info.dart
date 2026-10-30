import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/series_detail.dart' show CastMember;
import '../../services/api_client.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart' show HomeSectionHeader, homeGutter;
import 'series_detail_common.dart';

/// 简介 + 演职人员。
///
/// 详情接口返回空不算失败：没有简介和演员就整块不画（目录仍照常渲染），
/// 只有真的请求失败才在区块内给「详情加载失败 / 重试」。
class SeriesDetailIntroSection extends StatefulWidget {
  const SeriesDetailIntroSection({
    super.key,
    required this.loading,
    required this.failed,
    required this.intro,
    required this.cast,
    required this.onRetry,
  });

  final bool loading;
  final bool failed;
  final String intro;
  final List<CastMember> cast;
  final VoidCallback onRetry;

  @override
  State<SeriesDetailIntroSection> createState() =>
      _SeriesDetailIntroSectionState();
}

class _SeriesDetailIntroSectionState extends State<SeriesDetailIntroSection> {
  static const _collapsedLines = 3;

  bool _expanded = false;
  Object? _cacheKey;
  String? _cacheValue;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final hasIntro = widget.intro.isNotEmpty;
    final hasCast = widget.cast.isNotEmpty;
    if (!widget.loading && !widget.failed && !hasIntro && !hasCast) {
      return const SizedBox.shrink(
        key: ValueKey('series-detail-intro-section'),
      );
    }
    return Column(
      key: const ValueKey('series-detail-intro-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HomeSectionHeader(title: '简介'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.loading)
                const SeriesDetailSkeleton()
              else if (widget.failed)
                SeriesRetryInline(message: '详情加载失败', onRetry: widget.onRetry)
              else ...[
                if (hasIntro) _introBlock(palette),
                if (hasCast) ...[
                  const SizedBox(height: 20),
                  Text(
                    '演职人员',
                    key: const ValueKey('series-detail-cast-title'),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: palette.ink,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _castRow(palette),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ---- 简介 ----

  /// 折叠态最多 3 行；官方「展开」叠在正文右下角，Flutter 没有原生末行
  /// 留白，用 TextPainter 二分出恰好容纳「…＋标签宽」的前缀。
  Widget _introBlock(HomePalette palette) {
    final bodyStyle = TextStyle(fontSize: 14, height: 1.4, color: palette.body);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (_expanded) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.intro,
                key: const ValueKey('series-detail-intro'),
                style: bodyStyle,
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: _toggleLabel(palette, '收起'),
              ),
            ],
          );
        }
        final prefix = _collapsedPrefix(widget.intro, maxWidth, bodyStyle);
        if (prefix == null) {
          return Text(
            widget.intro,
            key: const ValueKey('series-detail-intro'),
            style: bodyStyle,
          );
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expanded = true),
          child: Stack(
            children: [
              Text(
                '$prefix…',
                key: const ValueKey('series-detail-intro'),
                style: bodyStyle,
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: _toggleLabel(palette, '展开'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _toggleLabel(HomePalette palette, String label) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => setState(() => _expanded = !_expanded),
    child: Text(label, style: TextStyle(fontSize: 14, color: palette.muted)),
  );

  String? _collapsedPrefix(String text, double maxWidth, TextStyle style) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final cacheKey = (text, maxWidth, style, scaler, direction);
    if (_cacheKey == cacheKey) return _cacheValue;
    _cacheKey = cacheKey;
    _cacheValue = null;
    final overflowProbe = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
    )..layout(maxWidth: maxWidth);
    final fits = overflowProbe.computeLineMetrics().length <= _collapsedLines;
    overflowProbe.dispose();
    if (fits) return null;
    final labelProbe = TextPainter(
      text: const TextSpan(text: ' 展开', style: TextStyle(fontSize: 14)),
      textDirection: direction,
      textScaler: scaler,
    )..layout();
    final reserved = labelProbe.width + 8;
    labelProbe.dispose();
    String? best;
    var lo = 0;
    final characters = text.characters.toList();
    var hi = characters.length;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final probe = TextPainter(
        text: TextSpan(text: '${characters.take(mid).join()}…', style: style),
        textDirection: direction,
        textScaler: scaler,
      )..layout(maxWidth: maxWidth);
      final metrics = probe.computeLineMetrics();
      probe.dispose();
      if (metrics.length > _collapsedLines ||
          metrics.last.width > maxWidth - reserved) {
        hi = mid - 1;
      } else {
        best = characters.take(mid).join();
        lo = mid + 1;
      }
    }
    return _cacheValue = best ?? '';
  }

  // ---- 演职人员 ----

  Widget _castRow(HomePalette palette) => SizedBox(
    key: const ValueKey('series-detail-cast'),
    height: 64 + 38 * MediaQuery.textScalerOf(context).scale(11) / 11,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: widget.cast.length,
      separatorBuilder: (_, _) => const SizedBox(width: 16),
      itemBuilder: (context, index) => _castMember(palette, widget.cast[index]),
    ),
  );

  Widget _castMember(HomePalette palette, CastMember member) => SizedBox(
    width: 80,
    child: Column(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: palette.soft,
            shape: BoxShape.circle,
            border: palette.eink ? Border.all(color: palette.line) : null,
          ),
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.center,
          child: member.avatar.isEmpty
              ? _initial(palette, member)
              : CachedNetworkImage(
                  imageUrl: ApiClient.instance.absoluteUrl(member.avatar),
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => _initial(palette, member),
                ),
        ),
        const SizedBox(height: 6),
        Text(
          member.actor,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: palette.muted),
        ),
        if (member.role.isNotEmpty)
          Text(
            '饰 ${member.role}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: palette.muted),
          ),
      ],
    ),
  );

  Widget _initial(HomePalette palette, CastMember member) =>
      Text(member.initial, style: TextStyle(fontSize: 20, color: palette.ink));
}
