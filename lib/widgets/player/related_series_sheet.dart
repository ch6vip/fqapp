import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/related_series.dart';
import '../../services/api_client.dart';
import '../../services/backend_transport.dart';
import '../../services/user_facing_error.dart';

/// 同系列剧的双列区块（官方 `catalogdialog/view/s`，`enableDoubleRow`）。
///
/// 两种宿主：
/// * 选集弹层里**内嵌**（官方形态）——随弹层自己的滚动体一起滚；
/// * 独立底部弹层 [RelatedSeriesSheet]（详情页/播放器入口）。
///
/// 两种宿主都提供滚动，所以这里的网格始终 `shrinkWrap` + 不自己滚动。
class RelatedSeriesBlock extends StatefulWidget {
  const RelatedSeriesBlock({
    super.key,
    required this.seriesId,
    this.loader,
    this.onSelected,
    this.title = '同系列剧',
  });

  final String seriesId;
  final Future<List<RelatedSeries>> Function(String)? loader;
  final ValueChanged<RelatedSeries>? onSelected;
  final String title;

  @override
  State<RelatedSeriesBlock> createState() => _RelatedSeriesBlockState();
}

class _RelatedSeriesBlockState extends State<RelatedSeriesBlock> {
  BackendRequest? _request;
  bool _loading = true;
  String? _error;
  List<RelatedSeries> _items = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _request?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _request?.cancel();
    final request = _request = BackendRequest();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await ApiClient.instance
          .withCancellation(
            request,
            () =>
                widget.loader?.call(widget.seriesId) ??
                ApiClient.instance.relatedSeries(widget.seriesId),
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted || !identical(request, _request)) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (error) {
      request.cancel();
      if (!mounted || !identical(request, _request)) return;
      setState(() {
        _error = userFacingError(error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('暂无可切换的同系列剧')),
      );
    }
    return Column(
      key: const ValueKey('related-series-block'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              widget.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 14,
            crossAxisSpacing: 12,
            // 固定卡高：封面按剩余空间铺满，标题与集数始终落在可见区内。
            mainAxisExtent: 240,
          ),
          itemCount: _items.length,
          itemBuilder: (context, index) => _card(context, _items[index]),
        ),
      ],
    );
  }

  Widget _card(BuildContext context, RelatedSeries item) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.movie_outlined)),
    );
    return Material(
      // 区块可能挂在非 Material 宿主上（测试的 MaterialApp.home），
      // InkWell 必须有自己的 Material 祖先。
      type: MaterialType.transparency,
      child: InkWell(
        key: ValueKey('related-series-${item.id}'),
        borderRadius: BorderRadius.circular(8),
        onTap: item.unavailable
            ? null
            : () {
                if (widget.onSelected != null) {
                  widget.onSelected!(item);
                } else {
                  Navigator.pop(context, item);
                }
              },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: double.infinity,
                  child: item.cover.isEmpty
                      ? placeholder
                      : CachedNetworkImage(
                          imageUrl: ApiClient.instance.absoluteUrl(item.cover),
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => placeholder,
                        ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Text(
              item.unavailable
                  ? '暂不可播放'
                  : item.episodeCount > 0
                  ? '共 ${item.episodeCount} 集'
                  : '查看剧集',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 独立底部弹层形态（详情页/播放器入口）：标题行 + [RelatedSeriesBlock]。
///
/// Note: 选集弹层里已改为内嵌区块，不再从这里开二级弹层 — 见
/// .agents/notes/implemented/feature/2026-10-15-related-series.md
class RelatedSeriesSheet extends StatelessWidget {
  const RelatedSeriesSheet({super.key, required this.seriesId, this.loader});

  final String seriesId;
  final Future<List<RelatedSeries>> Function(String)? loader;

  static Future<RelatedSeries?> show(BuildContext context, String seriesId) =>
      showModalBottomSheet<RelatedSeries>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => RelatedSeriesSheet(seriesId: seriesId),
      );

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * 0.65,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '同系列剧',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              bottom: MediaQuery.paddingOf(context).bottom + 16,
            ),
            child: RelatedSeriesBlock(
              seriesId: seriesId,
              loader: loader,
              title: '',
            ),
          ),
        ),
      ],
    ),
  );
}
