import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

class DesktopLogin extends StatefulWidget {
  const DesktopLogin({super.key});
  static final _controller = WebviewController();
  static Future<void>? _initializing;
  static VoidCallback? _cancel;
  static Future<void> _initialize() => _initializing ??=
      (() async {
        final root = await getApplicationSupportDirectory();
        final profile = await Directory(
          '${root.path}/webview',
        ).create(recursive: true);
        await WebviewController.initializeEnvironment(
          userDataPath: profile.path,
        );
        await _controller.initialize();
      })().catchError((Object e) {
        _initializing = null;
        throw e;
      });
  static Future<String?> open(BuildContext context) async {
    await _initialize();
    if (!context.mounted) return null;
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const DesktopLogin(),
    );
  }

  static void cancel() => _cancel?.call();
  static Future<void> clearSession() async {
    await _initialize();
    await _controller.clearCookies();
    await _controller.clearCache();
  }

  @override
  State<DesktopLogin> createState() => _DesktopLoginState();
}

class _DesktopLoginState extends State<DesktopLogin> {
  String _hint = '请在番茄官方网页完成登录和验证，再点击“读取书架”。账号只用于读取。';
  bool _reading = false;
  StreamSubscription<String>? _navigation;
  @override
  void initState() {
    super.initState();
    DesktopLogin._cancel = () {
      if (mounted) Navigator.pop(context);
    };
    _navigation = DesktopLogin._controller.url.listen((url) {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          ![
            'fanqienovel.com',
            'snssdk.com',
            'bytedance.com',
            'zijieapi.com',
          ].any((host) => uri.host == host || uri.host.endsWith('.$host'))) {
        unawaited(DesktopLogin._controller.stop());
        if (mounted) setState(() => _hint = '已阻止离开官方登录域名。');
      }
    });
    unawaited(
      DesktopLogin._controller.setPopupWindowPolicy(
        WebviewPopupWindowPolicy.deny,
      ),
    );
    unawaited(
      DesktopLogin._controller.loadUrl(
        'https://fanqienovel.com/main/writer/login',
      ),
    );
  }

  @override
  void dispose() {
    DesktopLogin._cancel = null;
    _navigation?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    if (_reading) return;
    setState(() => _reading = true);
    try {
      final result = await DesktopLogin._controller.getFanqieCookies();
      final cookies = (result['cookies'] as List? ?? []).whereType<Map>().where(
        (cookie) {
          final domain = (cookie['domain'] as String? ?? '').replaceFirst(
            RegExp(r'^\.'),
            '',
          );
          return domain == 'fanqienovel.com' ||
              domain.endsWith('.fanqienovel.com');
        },
      ).toList();
      if (!cookies.any(
        (cookie) =>
            ['sessionid', 'sessionid_ss', 'sid_tt'].contains(cookie['name']) &&
            (cookie['value'] as String? ?? '').isNotEmpty,
      )) {
        if (mounted) setState(() => _hint = '尚未取得有效登录态，请先完成官方登录。');
        return;
      }
      final value = cookies.map((c) => '${c['name']}=${c['value']}').join('; ');
      if (value.length > 12 * 1024) throw StateError('cookie size');
      if (mounted) Navigator.pop(context, value);
    } catch (_) {
      if (mounted) setState(() => _hint = '无法读取官方登录态，请重试。');
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(24),
    child: SizedBox(
      width: 1000,
      height: 700,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '番茄官方登录 · 只读导入',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: Webview(
              DesktopLogin._controller,
              permissionRequested: (_, _, _) async =>
                  WebviewPermissionDecision.deny,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(child: Text(_hint)),
                const SizedBox(width: 16),
                FilledButton(
                  onPressed: _reading ? null : _read,
                  child: Text(_reading ? '正在读取…' : '读取书架'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
