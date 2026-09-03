import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../widgets/media_card.dart';
import 'detail_page.dart';

class SearchPage extends StatefulWidget {
  final String? initialQuery;

  const SearchPage({super.key, this.initialQuery});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _ctrl = TextEditingController();
  List<SearchTab> _tabs = [];
  String _query = '';
  bool _loading = false;
  String? _error;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuery?.trim() ?? '';
    if (initial.isNotEmpty) {
      _ctrl.text = initial;
      _search(initial);
    }
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) return;
    setState(() {
      _query = q.trim();
      _loading = true;
      _error = null;
      _tabIndex = 0;
    });
    try {
      final d = await ApiClient.instance.search(_query);
      final tabs = parseSearchTabs(d);
      setState(() {
        _tabs = tabs;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeTab = _tabs.isNotEmpty
        ? _tabs[_tabIndex.clamp(0, _tabs.length - 1)]
        : null;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: false,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜索短剧、小说、漫画...',
            border: InputBorder.none,
            suffixIcon: IconButton(
              icon: const Icon(Icons.search),
              onPressed: () => _search(_ctrl.text),
            ),
          ),
          onSubmitted: _search,
        ),
      ),
      body: Column(
        children: [
          if (_tabs.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: List.generate(_tabs.length, (i) {
                  final t = _tabs[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(t.title),
                      selected: i == _tabIndex,
                      onSelected: (_) => setState(() => _tabIndex = i),
                    ),
                  );
                }),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  )
                : activeTab == null
                ? const Center(child: Text('输入关键词搜索'))
                : activeTab.items.isEmpty
                ? const Center(child: Text('无结果'))
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: 0.52,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                    itemCount: activeTab.items.length,
                    itemBuilder: (context, i) => MediaCard(
                      item: activeTab.items[i],
                      onTap: () => _openItem(activeTab.items[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  void _openItem(MediaItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailPage(item: item)),
    );
  }
}
