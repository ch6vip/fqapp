import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../services/library_store.dart';
import 'detail_page.dart';

/// Reading statistics page modeled after the legado ReadRecordFragment:
/// overview cards, a 16-week heatmap, recent books, daily records, recent
/// covers, a reading rank and a daily goal card.
///
/// fqapp has no real reading-duration tracking yet, so per-entry minutes are
/// estimated: video history uses its stored duration, book history counts a
/// flat 10 minutes per entry. The layout follows the legado stats screen.
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

const _goalKey = 'stats_daily_goal_minutes';
const double _flatBookMinutes = 10;

class _StatsPageState extends State<StatsPage> {
  DateTime _selected = DateTime.now();
  List<Map<String, dynamic>> _history = [];
  Map<String, Map<String, double>> _readTimeMap = {};
  int _favCount = 0;
  int _goalMinutes = 30;
  bool _loading = true;

  Map<String, double> get _dayMinutes {
    final map = <String, double>{};
    void add(String day, double minutes) =>
        map[day] = (map[day] ?? 0) + minutes;
    // Real recorded reading time (seconds → minutes).
    for (final days in _readTimeMap.values) {
      days.forEach((day, secs) => add(day, secs / 60));
    }
    // Fallback estimates for books without real data yet, so older history
    // still shows up during the transition. Drops out once real data exists.
    final withRealData = _readTimeMap.keys.toSet();
    for (final entry in _history) {
      final id = '${entry['bookId'] ?? entry['id']}';
      if (withRealData.contains(id)) continue;
      final day = _dayKey(
        DateTime.fromMillisecondsSinceEpoch(
          (entry['time'] as num?)?.toInt() ?? 0,
        ),
      );
      add(day, _flatBookMinutes);
    }
    return map;
  }

  double get _totalMinutes => _dayMinutes.values.fold(0, (a, b) => a + b);

  double _todayMinutes() =>
      _dayMinutes[_dayKey(_selected)] ?? 0;

  double _monthMinutes() {
    var sum = 0.0;
    _dayMinutes.forEach((key, value) {
      if (key.startsWith(_monthPrefix(_selected))) sum += value;
    });
    return sum;
  }

  int get _activeDays =>
      _dayMinutes.values.where((m) => m > 0).length;

  bool get _hasStats => _dayMinutes.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    final history = await LibraryStore.instance.history();
    final favs = await LibraryStore.instance.favorites();
    final timeMap = await LibraryStore.instance.readTimeMap();
    if (!mounted) return;
    setState(() {
      _history = history;
      _readTimeMap = timeMap;
      _favCount = favs.length;
      _goalMinutes = sp.getInt(_goalKey) ?? 30;
      _loading = false;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selected,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _selected = picked);
  }

  Future<void> _editGoal() async {
    final ctrl = TextEditingController(text: '$_goalMinutes');
    final value = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('每日阅读目标'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '分钟'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [15, 30, 60, 120].map((m) {
                return ActionChip(
                  label: Text('$m 分钟'),
                  onPressed: () {
                    ctrl.text = '$m';
                    Navigator.pop(c, m);
                  },
                );
              }).toList(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text) ?? 30;
              Navigator.pop(c, v.clamp(1, 1440));
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (value != null) {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_goalKey, value);
      if (mounted) setState(() => _goalMinutes = value);
    }
  }

  void _showRank() {
    final rank = _rankItems();
    showDialog<void>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('阅读排行'),
        children: [
          for (final item in rank)
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(c);
                _openHistory(item.entry);
              },
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${item.index}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: item.index <= 3
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      item.entry['title']?.toString() ?? '未知',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    _formatDuring(item.minutes),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<_RankItem> _rankItems() {
    final byBook = <String, _RankItem>{};
    // Real recorded reading time.
    _readTimeMap.forEach((bookId, days) {
      final totalMin = days.values.fold<double>(0, (a, b) => a + b) / 60;
      if (totalMin <= 0) return;
      final entry = _history.firstWhere(
        (e) => '${e['bookId'] ?? e['id']}' == bookId,
        orElse: () => <String, dynamic>{
          'title': bookId,
          'bookId': bookId,
          'id': bookId,
        },
      );
      byBook[bookId] = _RankItem(entry: entry, minutes: totalMin, index: 0);
    });
    // Fallback for history books without real data yet.
    final withRealData = _readTimeMap.keys.toSet();
    for (final entry in _history) {
      final id = '${entry['bookId'] ?? entry['id']}';
      if (withRealData.contains(id)) continue;
      final existing = byBook[id];
      if (existing == null) {
        byBook[id] = _RankItem(
          entry: entry,
          minutes: _flatBookMinutes,
          index: 0,
        );
      } else {
        existing.minutes += _flatBookMinutes;
      }
    }
    final list = byBook.values.toList()
      ..sort((a, b) => b.minutes.compareTo(a.minutes));
    for (var i = 0; i < list.length; i++) {
      list[i].index = i + 1;
    }
    return list;
  }

  void _openHistory(Map<String, dynamic> entry) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailPage(
          item: MediaItem(
            id: '${entry['id'] ?? ''}',
            title: '${entry['title'] ?? ''}',
            cover: '${entry['cover'] ?? ''}',
            author: '${entry['author'] ?? ''}',
            badge: '',
            ep: '',
            kind: '${entry['kind'] ?? 'book'}',
            seriesId: entry['seriesId']?.toString(),
            episodeId: entry['episodeId']?.toString(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final heatmap = _heatmapCells();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _dateHeader(),
          const SizedBox(height: 18),
          _OverviewCard(
            today: _todayMinutes(),
            month: _monthMinutes(),
            total: _totalMinutes,
            activeDays: _activeDays,
            favCount: _favCount,
          ),
          const SizedBox(height: 12),
          _Card(
            title: '阅读热力图',
            subtitle: '最近 16 周',
            child: _Heatmap(cells: heatmap),
          ),
          const SizedBox(height: 12),
          _RecentBooksCard(
            history: _history,
            readTimeMap: _readTimeMap,
            onTap: _openHistory,
          ),
          const SizedBox(height: 12),
          _DailyRecordsCard(
            dayMinutes: _dayMinutes,
            selected: _selected,
            hasStats: _hasStats,
          ),
          const SizedBox(height: 12),
          _RecentCoversCard(history: _history, onTap: _openHistory),
          const SizedBox(height: 12),
          _RankCard(items: _rankItems().take(5).toList(), onMore: _showRank),
          const SizedBox(height: 12),
          _GoalCard(
            today: _todayMinutes(),
            total: _totalMinutes,
            readBookCount: _rankItems().length,
            goalMinutes: _goalMinutes,
            onEdit: _editGoal,
          ),
        ],
      ),
    );
  }

  Widget _dateHeader() {
    final textStyle = Theme.of(context).textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.bold,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: GestureDetector(
            onTap: _pickDate,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formatDate(_selected),
                  style: textStyle,
                ),
                const SizedBox(height: 4),
                Text(
                  _hasStats ? '每日阅读时长持续统计中' : '继续阅读后会开始生成日统计和热力图',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<_HeatCell> _heatmapCells() {
    final dayMinutes = _dayMinutes;
    final start = _selected.subtract(const Duration(days: 111));
    return List.generate(112, (i) {
      final date = start.add(Duration(days: i));
      return _HeatCell(date, dayMinutes[_dayKey(date)] ?? 0);
    });
  }
}

// ---------- shared helpers ----------

String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

String _monthPrefix(DateTime d) => '${d.year}-${d.month}';

String _formatDate(DateTime d) => '${d.year}年${d.month}月${d.day}日';

String _formatMonth(DateTime d) => '${d.month}月';

/// Minutes for one history entry: real recorded time if the book has any,
/// otherwise the flat per-entry estimate (pre-tracking history).
double _bookMinutesOf(
  Map<String, dynamic> entry,
  Map<String, Map<String, double>> timeMap,
) {
  final id = '${entry['bookId'] ?? entry['id']}';
  final days = timeMap[id];
  if (days != null && days.isNotEmpty) {
    return days.values.fold<double>(0, (a, b) => a + b) / 60;
  }
  return _flatBookMinutes;
}

String _formatDuring(double minutes) {
  final totalMin = minutes.round();
  if (totalMin <= 0) return '0分钟';
  final days = totalMin ~/ (24 * 60);
  final hours = (totalMin % (24 * 60)) ~/ 60;
  final mins = totalMin % 60;
  final parts = <String>[
    if (days > 0) '$days天',
    if (hours > 0) '$hours小时',
    if (mins > 0) '$mins分钟',
  ];
  return parts.join();
}

String _daySubtitle(DateTime date) {
  final today = DateTime.now();
  final d = DateTime(date.year, date.month, date.day);
  final t = DateTime(today.year, today.month, today.day);
  if (d == t) return '今天';
  if (d == t.subtract(const Duration(days: 1))) return '昨天';
  const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return weekdays[date.weekday - 1];
}

// ---------- card shell ----------

class _Card extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final Widget child;

  const _Card({this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
          ],
          child,
        ],
      ),
    );
  }
}

// ---------- overview ----------

class _OverviewCard extends StatelessWidget {
  final double today;
  final double month;
  final double total;
  final int activeDays;
  final int favCount;

  const _OverviewCard({
    required this.today,
    required this.month,
    required this.total,
    required this.activeDays,
    required this.favCount,
  });

  @override
  Widget build(BuildContext context) {
    final stats = <(String, String)>[
      ('今日', today > 0 ? _formatDuring(today) : '--'),
      ('本月', month > 0 ? _formatDuring(month) : '--'),
      ('总计', _formatDuring(total)),
      ('活跃天数', '$activeDays 天'),
    ];
    return _Card(
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 2.6,
        children: [
          for (final (label, value) in stats)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ---------- heatmap ----------

class _HeatCell {
  final DateTime date;
  final double minutes;

  _HeatCell(this.date, this.minutes);
}

class _Heatmap extends StatelessWidget {
  final List<_HeatCell> cells;

  const _Heatmap({required this.cells});

  int _level(double minutes) {
    if (minutes <= 0) return 0;
    if (minutes < 10) return 1;
    if (minutes < 30) return 2;
    if (minutes < 60) return 3;
    return 4;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final primary = scheme.primary;
    // 112 days = 16 columns x 7 rows (GitHub-style weeks).
    final start = cells.first.date;
    final end = cells.last.date;
    final monthLabels = [
      _formatMonth(start),
      _formatMonth(cells[cells.length ~/ 2].date),
      _formatMonth(end),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (final m in monthLabels)
              Expanded(
                child: Text(
                  m,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const [
                Text('周一', style: TextStyle(fontSize: 10, color: Colors.grey)),
                Text('周三', style: TextStyle(fontSize: 10, color: Colors.grey)),
                Text('周五', style: TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                children: [
                  for (var row = 0; row < 7; row++) ...[
                    if (row > 0) const SizedBox(height: 3),
                    Row(
                      children: [
                        for (var col = 0; col < 16; col++) ...[
                          if (col > 0) const SizedBox(width: 3),
                          _cell(primary, scheme, col * 7 + row),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _cell(Color primary, ColorScheme scheme, int index) {
    final cell = index < cells.length ? cells[index] : null;
    final level = cell == null ? 0 : _level(cell.minutes);
    final color = switch (level) {
      1 => primary.withValues(alpha: 0.15),
      2 => primary.withValues(alpha: 0.35),
      3 => primary.withValues(alpha: 0.6),
      4 => primary,
      _ => scheme.surfaceContainerHighest,
    };
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

// ---------- recent books ----------

class _RecentBooksCard extends StatelessWidget {
  final List<Map<String, dynamic>> history;
  final Map<String, Map<String, double>> readTimeMap;
  final void Function(Map<String, dynamic>) onTap;

  const _RecentBooksCard({
    required this.history,
    required this.readTimeMap,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final items = history.take(6).toList();
    return _Card(
      title: '最近阅读',
      child: items.isEmpty
          ? const _EmptyHint('暂无最近阅读')
          : Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _bookRow(context, items[i], onTap),
                ],
              ],
            ),
    );
  }

  Widget _bookRow(
    BuildContext context,
    Map<String, dynamic> entry,
    void Function(Map<String, dynamic>) onTap,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final title = entry['title']?.toString() ?? '未知';
    final chapter = entry['chapterId']?.toString() ?? '';
    final isVideo = entry['kind'] == 'video';
    final time = DateTime.fromMillisecondsSinceEpoch(
      (entry['time'] as num?)?.toInt() ?? 0,
    );
    final meta = [
      if (chapter.isNotEmpty)
        (isVideo ? '看到第${((entry['episode'] as num?)?.toInt() ?? 0) + 1}集' : '读到第${((entry['episode'] as num?)?.toInt() ?? 0) + 1}章'),
      '最近打开 ${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
    ].join(' · ');

    return InkWell(
      onTap: () => onTap(entry),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            _cover(entry['cover']?.toString() ?? '', 40, 52),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              _formatDuring(_bookMinutesOf(entry, readTimeMap)),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover(String url, double w, double h) {
    if (url.isEmpty) {
      return Container(
        width: w,
        height: h,
        color: Colors.grey.shade200,
        child: const Icon(Icons.book, color: Colors.grey, size: 20),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        url,
        width: w,
        height: h,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: w,
          height: h,
          color: Colors.grey.shade200,
          child: const Icon(Icons.book, color: Colors.grey, size: 20),
        ),
      ),
    );
  }
}

// ---------- daily records ----------

class _DailyRecordsCard extends StatelessWidget {
  final Map<String, double> dayMinutes;
  final DateTime selected;
  final bool hasStats;

  const _DailyRecordsCard({
    required this.dayMinutes,
    required this.selected,
    required this.hasStats,
  });

  @override
  Widget build(BuildContext context) {
    final rows = <(DateTime, double)>[];
    for (var i = 13; i >= 0; i--) {
      final date = selected.subtract(Duration(days: i));
      rows.add((date, dayMinutes[_dayKey(date)] ?? 0));
    }
    final scheme = Theme.of(context).colorScheme;
    return _Card(
      title: '每日记录',
      child: hasStats
          ? Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${rows[i].$1.month}月${rows[i].$1.day}日',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        Text(
                          _daySubtitle(rows[i].$1),
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          rows[i].$2 > 0 ? _formatDuring(rows[i].$2) : '--',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            )
          : const _EmptyHint('暂无每日统计'),
    );
  }
}

// ---------- recent covers ----------

class _RecentCoversCard extends StatelessWidget {
  final List<Map<String, dynamic>> history;
  final void Function(Map<String, dynamic>) onTap;

  const _RecentCoversCard({required this.history, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final items = history.take(5).toList();
    return _Card(
      title: '最近封面',
      child: items.isEmpty
          ? const _EmptyHint('暂无最近阅读')
          : SizedBox(
              height: 110,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final entry = items[i];
                  final url = entry['cover']?.toString() ?? '';
                  return GestureDetector(
                    onTap: () => onTap(entry),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: url.isEmpty
                          ? Container(
                              width: 74,
                              height: 110,
                              color: Colors.grey.shade200,
                              child: const Icon(
                                Icons.book,
                                color: Colors.grey,
                              ),
                            )
                          : Image.network(
                              url,
                              width: 74,
                              height: 110,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(
                                width: 74,
                                height: 110,
                                color: Colors.grey.shade200,
                                child: const Icon(
                                  Icons.book,
                                  color: Colors.grey,
                                ),
                              ),
                            ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

// ---------- rank ----------

class _RankItem {
  final Map<String, dynamic> entry;
  double minutes;
  int index;

  _RankItem({required this.entry, required this.minutes, required this.index});
}

class _RankCard extends StatelessWidget {
  final List<_RankItem> items;
  final VoidCallback onMore;

  const _RankCard({required this.items, required this.onMore});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Card(
      title: '阅读排行',
      child: Column(
        children: [
          if (items.isEmpty)
            const _EmptyHint('暂无排行数据')
          else
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Row(
                  children: [
                    SizedBox(
                      width: 28,
                      child: Text(
                        '${items[i].index}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: items[i].index <= 3
                              ? scheme.primary
                              : Colors.grey,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        items[i].entry['title']?.toString() ?? '未知',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    Text(
                      _formatDuring(items[i].minutes),
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: items.isEmpty ? null : onMore,
              icon: const Icon(Icons.arrow_forward, size: 16),
              label: const Text('查看全部'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- goal card ----------

class _GoalCard extends StatelessWidget {
  final double today;
  final double total;
  final int readBookCount;
  final int goalMinutes;
  final VoidCallback onEdit;

  const _GoalCard({
    required this.today,
    required this.total,
    required this.readBookCount,
    required this.goalMinutes,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final goalMs = goalMinutes * 60.0;
    final percent = goalMinutes <= 0
        ? 0
        : ((today / goalMs) * 100).round().clamp(0, 100);
    return _Card(
      title: '阅读目标',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '今日 ${today > 0 ? _formatDuring(today) : '--'} · 总计 ${_formatDuring(total)} · 读过 $readBookCount 本',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit, size: 18),
                onPressed: onEdit,
                visualDensity: VisualDensity.compact,
                tooltip: '编辑目标',
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: percent / 100,
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '今日 ${today > 0 ? _formatDuring(today) : '--'} / $goalMinutes 分钟 · $percent%',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
