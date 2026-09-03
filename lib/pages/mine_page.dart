import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/backend_service.dart';

class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  String _status = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final ok = await ApiClient.instance.health();
    if (!mounted) return;
    setState(() {
      _status = ok ? '运行中' : '已停止';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的'), centerTitle: true),
      body: ListView(
        children: [
          const SizedBox(height: 20),
          const CircleAvatar(
            radius: 36,
            backgroundColor: Color(0xFFE8532D),
            child: Icon(Icons.person, size: 40, color: Colors.white),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              '番茄小铺',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              '本地服务: $_status',
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          const SizedBox(height: 24),
          ListTile(
            leading: const Icon(Icons.memory),
            title: const Text('本地后端'),
            subtitle: Text(BackendService.instance.baseUrl),
            trailing: IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _refresh,
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('关于'),
            subtitle: const Text(
              '番茄小说 / 短剧 / 漫画 / 听书聚合客户端\n后端:  (Go) 本地运行',
            ),
          ),
        ],
      ),
    );
  }
}
