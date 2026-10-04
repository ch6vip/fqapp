import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_log.dart';
import '../services/playlet_share.dart';

/// 日志来源。
enum _LogSource {
  /// 应用日志：内存环形缓冲 + 上次会话从 `app.log` 回读的部分。
  app('应用'),

  /// Rust 核心日志：`runtime_dir/rust.log` 的落盘副本（Android 应用读不到 logcat）。
  rust('Rust');

  const _LogSource(this.label);

  final String label;
}

/// 日志查看页。
///
/// 工具条提供来源切换、级别筛选与自动滚动；AppBar 提供复制/导出分享/清空。
/// Rust 来源是另一个写入者，只能轮询文件，因此切到该来源时按 [rustRefresh]
/// 周期重读。
class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  /// Rust 日志的轮询间隔。
  static const Duration rustRefresh = Duration(seconds: 2);

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  final _scrollController = ScrollController();
  bool _autoScroll = true;
  LogLevel? _filter; // null = 全部级别
  _LogSource _source = _LogSource.app;
  List<LogEntry> _rustEntries = const [];
  Timer? _rustTimer;
  final _searchController = TextEditingController();
  String _query = '';
  Duration? _timeWindow; // null = 不限时间

  @override
  void dispose() {
    _rustTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<LogEntry> get _activeEntries =>
      _source == _LogSource.app ? AppLog.instance.entries : _rustEntries;

  List<LogEntry> _visible() {
    Iterable<LogEntry> entries = _activeEntries;
    final filter = _filter;
    if (filter != null) entries = entries.where((e) => e.level == filter);
    final window = _timeWindow;
    if (window != null) {
      final since = DateTime.now().subtract(window);
      entries = entries.where((e) => e.time.isAfter(since));
    }
    final query = _query.trim().toLowerCase();
    if (query.isNotEmpty) {
      entries = entries.where(
        (e) =>
            e.message.toLowerCase().contains(query) ||
            e.tag.toLowerCase().contains(query),
      );
    }
    return entries.toList();
  }

  /// 读 Rust 落盘副本。文件不存在（核心还没写过）时给空列表，不报错。
  Future<void> _loadRust() async {
    final text = await RustLogSource.read();
    if (!mounted) return;
    final entries = <LogEntry>[];
    if (text != null) {
      final lines = text.split('\n');
      while (lines.isNotEmpty && lines.last.isEmpty) {
        lines.removeLast();
      }
      entries.addAll(AppLog.parseLogLines(lines));
    }
    setState(() => _rustEntries = entries);
  }

  void _selectSource(_LogSource source) {
    if (source == _source) return;
    setState(() => _source = source);
    _rustTimer?.cancel();
    _rustTimer = null;
    if (source == _LogSource.rust) {
      unawaited(_loadRust());
      _rustTimer = Timer.periodic(
        LogViewerPage.rustRefresh,
        (_) => unawaited(_loadRust()),
      );
    }
  }

  void _scrollToBottom() {
    if (!_autoScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  Future<void> _copyAll() async {
    final count = _activeEntries.length;
    await Clipboard.setData(
      ClipboardData(text: formatLogLines(_activeEntries)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已复制 $count 条日志')));
  }

  Future<void> _share() async {
    final outcome = await SharePlusLite.share(
      title: '${_source.label}日志',
      text: formatLogLines(_activeEntries, maxLines: 500),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          outcome == ShareLaunchOutcome.launched ? '已调起分享' : '没有可用的分享应用',
        ),
      ),
    );
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('确定清空当前内存中的日志吗？不会删除已落盘文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    AppLog.instance.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isApp = _source == _LogSource.app;
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.content_copy),
            tooltip: '复制全部',
            onPressed: _copyAll,
          ),
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: '导出分享',
            onPressed: _share,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            // Rust 日志文件由核心追加写入，应用内不删除它，因此该项禁用。
            tooltip: isApp ? '清空' : 'Rust 日志由核心写入，不能在应用内清空',
            onPressed: isApp ? _confirmClear : null,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildToolbar(),
          const Divider(height: 1),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: AppLog.instance.revision,
              builder: (context, _, _) {
                final visible = _visible();
                // 列表更新后滚动到底部（自动滚动开启时）。
                _scrollToBottom();
                if (visible.isEmpty) {
                  return Center(
                    child: Text(
                      _emptyText(),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: visible.length,
                  itemBuilder: (context, index) =>
                      _LogRow(entry: visible[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _emptyText() {
    if (_query.trim().isNotEmpty) return '没有匹配「${_query.trim()}」的日志';
    if (_filter != null) return '该级别暂无日志';
    if (_timeWindow != null) return '该时间范围内暂无日志';
    return _source == _LogSource.app ? '暂无日志' : '暂无 Rust 日志';
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 12),
              SegmentedButton<_LogSource>(
                segments: [
                  for (final source in _LogSource.values)
                    ButtonSegment<_LogSource>(
                      value: source,
                      label: Text(source.label),
                    ),
                ],
                selected: {_source},
                showSelectedIcon: false,
                onSelectionChanged: (selection) =>
                    _selectSource(selection.first),
              ),
              const Spacer(),
              const Text('自动滚动', style: TextStyle(fontSize: 12)),
              Switch(
                value: _autoScroll,
                onChanged: (v) => setState(() => _autoScroll = v),
              ),
              const SizedBox(width: 4),
            ],
          ),
          // 搜索与时间范围单独一行：与来源/自动滚动挤在一行会溢出。
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: TextField(
                      controller: _searchController,
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '搜索标签或内容',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close, size: 16),
                                tooltip: '清除搜索',
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _query = '');
                                },
                              ),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.schedule, size: 20),
                  tooltip: '时间范围：${_timeWindowLabel()}',
                  onPressed: _pickTimeWindow,
                ),
              ],
            ),
          ),
          // 级别筛选单独一行并横向滚动：与来源/自动滚动挤在一行会溢出。
          SizedBox(
            height: 44,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _chip('全部', _filter == null, () => setState(() => _filter = null)),
                  for (final level in LogLevel.values)
                    _chip(
                      level.label,
                      _filter == level,
                      () => setState(() => _filter = level),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _timeWindowLabel() {
    final window = _timeWindow;
    if (window == null) return '不限';
    if (window.inMinutes < 60) return '最近 ${window.inMinutes} 分钟';
    return '最近 ${window.inHours} 小时';
  }

  /// 选时间范围。用单元素列表包一层，才能把「选了不限」与「取消」区分开。
  Future<void> _pickTimeWindow() async {
    final options = <(String, Duration?)>[
      ('不限时间', null),
      ('最近 5 分钟', const Duration(minutes: 5)),
      ('最近 30 分钟', const Duration(minutes: 30)),
      ('最近 2 小时', const Duration(hours: 2)),
    ];
    final picked = await showModalBottomSheet<List<Duration?>>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (label, window) in options)
              ListTile(
                title: Text(label),
                selected: _timeWindow == window,
                onTap: () => Navigator.pop(c, [window]),
              ),
          ],
        ),
      ),
    );
    // 取消（点空白/返回）时保持原选择不变。
    if (!mounted || picked == null) return;
    setState(() => _timeWindow = picked.first);
}

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (entry.level) {
      LogLevel.debug => theme.colorScheme.outline,
      LogLevel.info => theme.colorScheme.onSurface,
      LogLevel.warn => Colors.orange.shade800,
      LogLevel.error => theme.colorScheme.error,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            color: theme.colorScheme.onSurface,
          ),
          children: [
            TextSpan(
              text: '[${entry.level.token}]',
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text: ' ${_time(entry.time)} ${entry.tag}: ${entry.message}',
            ),
          ],
        ),
      ),
    );
  }

  String _time(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}