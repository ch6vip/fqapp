import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/series_detail.dart' show CastMember;
import '../../services/api_client.dart';
import '../home/home_design.dart';
import 'series_detail_common.dart';

/// 简介 + 演职人员。
///
/// 版式稿：正文 13/1.5 最多 3 行，没有「展开」链接——点正文本身展开 /
/// 收起；演员是 40dp 圆头像 + 11sp 名字。
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
  bool _expanded = false;

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
    return SeriesSection(
      key: const ValueKey('series-detail-intro-section'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SeriesSectionHeader(title: '简介'),
          if (widget.loading)
            const SeriesDetailSkeleton()
          else if (widget.failed)
            SeriesRetryInline(message: '详情加载失败', onRetry: widget.onRetry)
          else ...[
            if (hasIntro) _intro(palette),
            if (hasCast) ...[const SizedBox(height: 10), _castRow(palette)],
          ],
        ],
      ),
    );
  }

  Widget _intro(HomePalette palette) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => setState(() => _expanded = !_expanded),
    child: Text(
      widget.intro,
      key: const ValueKey('series-detail-intro'),
      maxLines: _expanded ? null : 3,
      overflow: _expanded ? TextOverflow.clip : TextOverflow.ellipsis,
      style: TextStyle(fontSize: 13, height: 1.5, color: palette.ink),
    ),
  );

  Widget _castRow(HomePalette palette) => SingleChildScrollView(
    key: const ValueKey('series-detail-cast'),
    scrollDirection: Axis.horizontal,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widget.cast.length; i++) ...[
          if (i > 0) const SizedBox(width: 14),
          _castMember(palette, widget.cast[i]),
        ],
      ],
    ),
  );

  Widget _castMember(HomePalette palette, CastMember member) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 40,
        height: 40,
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
      const SizedBox(height: 3),
      Text(
        member.actor,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: palette.ink),
      ),
    ],
  );

  Widget _initial(HomePalette palette, CastMember member) =>
      Text(member.initial, style: TextStyle(fontSize: 14, color: palette.ink));
}
