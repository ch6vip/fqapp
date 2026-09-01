import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/library_store.dart';

class PlayerPage extends StatefulWidget {
  final String bookId;
  final String title;
  final List<Chapter> eps;
  final int startIndex;

  const PlayerPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.eps,
    required this.startIndex,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late int _index;
  VideoPlayerController? _ctrl;
  bool _initVideo = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex;
    _loadVideo();
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _loadVideo() async {
    final ep = widget.eps[_index];
    setState(() {
      _initVideo = true;
      _error = null;
    });

    // 先释放旧控制器
    final old = _ctrl;
    _ctrl = null;
    old?.dispose();

    try {
      // 后端返回解密后的视频直链
      final d = await ApiClient.instance.content(ep.itemId, tab: '短剧');
      final data = d['data'];
      var url = '';
      if (data is Map) {
        url = '${data['video_url'] ?? data['play_url'] ?? ''}';
        // 也尝试从嵌套结构里取
        if (url.isEmpty) {
          final vi = data['video_info'];
          if (vi is Map) {
            url = '${vi['video_url'] ?? ''}';
          }
        }
      }
      if (url.isEmpty) throw ApiException('获取播放地址失败');

      final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
      await ctrl.initialize();
      if (!mounted) {
        ctrl.dispose();
        return;
      }
      setState(() {
        _ctrl = ctrl;
        _initVideo = false;
      });
      ctrl.setLooping(false);
      ctrl.play();
      ctrl.addListener(() {
        if (ctrl.value.isCompleted) {
          _next();
        }
      });
      await LibraryStore.instance.addHistory({
        'id': widget.bookId,
        'kind': 'video',
        'title': widget.title,
        'bookId': widget.bookId,
        'episode': _index,
        'progress': 0,
        'cover': '',
        'time': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _initVideo = false;
        });
      }
    }
  }

  void _prev() {
    if (_index <= 0) return;
    setState(() => _index--);
    _loadVideo();
  }

  void _next() {
    if (_index >= widget.eps.length - 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已是最后一集')));
      return;
    }
    setState(() => _index++);
    _loadVideo();
  }

  @override
  Widget build(BuildContext context) {
    final ep = widget.eps[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(ep.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          Text('${_index + 1}/${widget.eps.length}',
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _initVideo
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  )
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, style: const TextStyle(color: Colors.red)),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: _loadVideo,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    : _ctrl == null
                        ? const Center(
                            child: CircularProgressIndicator(color: Colors.white),
                          )
                        : GestureDetector(
                            onTap: () {
                              if (_ctrl!.value.isPlaying) {
                                _ctrl!.pause();
                              } else {
                                _ctrl!.play();
                              }
                              setState(() {});
                            },
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                VideoPlayer(_ctrl!),
                                if (!_ctrl!.value.isPlaying)
                                  const Icon(Icons.play_circle_outline,
                                      size: 64, color: Colors.white70),
                              ],
                            ),
                          ),
          ),
          const Spacer(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.skip_previous, color: Colors.white, size: 40),
                    onPressed: _index > 0 ? _prev : null,
                  ),
                  const SizedBox(width: 24),
                  IconButton(
                    icon: const Icon(Icons.skip_next, color: Colors.white, size: 40),
                    onPressed: _index < widget.eps.length - 1 ? _next : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
