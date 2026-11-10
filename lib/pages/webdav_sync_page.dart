import 'package:flutter/material.dart';

import '../services/webdav_client.dart';
import '../services/webdav_sync_service.dart';
import '../services/app_style_tokens.dart';
import '../widgets/wenku/wenku_ui.dart';
import '../widgets/settings/settings_widgets.dart';

class WebDavSyncPage extends StatefulWidget {
  const WebDavSyncPage({super.key});
  @override
  State<WebDavSyncPage> createState() => _WebDavSyncPageState();
}

class _WebDavSyncPageState extends State<WebDavSyncPage> {
  final _service = WebDavSyncService.instance;
  final _form = GlobalKey<FormState>();
  late final TextEditingController _directory;
  late final TextEditingController _username;
  late final TextEditingController _password;
  bool _enabled = false;
  bool _saving = false;
  bool _obscure = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    final config = _service.config;
    _directory = TextEditingController(text: config?.directory);
    _username = TextEditingController(text: config?.username);
    _password = TextEditingController(text: config?.password);
    _enabled = config?.enabled ?? true;
  }

  @override
  void dispose() {
    _directory.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save({bool sync = false}) async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await _service.configure(
        WebDavConfig(
          directory: _directory.text.trim(),
          username: _username.text.trim(),
          password: _password.text,
          enabled: _enabled,
        ),
      );
      if (sync || _enabled) await _service.sync();
      if (mounted) {
        setState(
          () => _message = sync || _enabled ? _service.status.value : '设置已安全保存',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is WebDavException
              ? error.message
              : '保存或同步失败，请检查连接设置及设备安全存储后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _shell(BuildContext context, Widget body) =>
      AppStyleTokens.of(context).isClassic
      ? SettingsScaffold(title: 'WebDAV 同步', body: body)
      : ArchiveFeaturePage(
          title: 'WebDAV 同步',
          code: 'SYNC / WEBDAV',
          child: body,
        );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_service.busy, _service.status]),
      builder: (context, _) {
        final busy = _saving || _service.busy.value;
        final classic = AppStyleTokens.of(context).isClassic;
        return _shell(
          context,
          SafeArea(
            top: classic,
            bottom: classic,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Form(
                  key: _form,
                  child: ListView(
                    padding: classic
                        ? const EdgeInsets.all(16)
                        : featurePadding(context),
                    children: [
                      const Text(
                        '云端优先覆盖书架与阅读进度',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '填写 HTTPS WebDAV 目录，目录不存在时自动创建，并保存 fqapp-sync.json。其他设备填写相同目录即可同步。',
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        controller: _directory,
                        enabled: !busy,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'WebDAV 目录地址',
                          hintText: 'https://dav.example.com/fqapp/',
                        ),
                        validator: (value) {
                          try {
                            WebDavConfig(
                              directory: value ?? '',
                              username: '',
                              password: '',
                              enabled: false,
                            ).fileUri;
                            return null;
                          } on WebDavException catch (error) {
                            return error.message;
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _username,
                        enabled: !busy,
                        autocorrect: false,
                        decoration: const InputDecoration(labelText: '用户名'),
                        validator: (value) =>
                            value?.contains(':') == true ? '用户名不能包含冒号' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        enabled: !busy,
                        obscureText: _obscure,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: '密码 / 应用专用密码',
                          suffixIcon: IconButton(
                            tooltip: _obscure ? '显示密码' : '隐藏密码',
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('自动同步'),
                        subtitle: const Text('启动、返回应用、数据变更后及前台每 2 分钟按云端覆盖本机'),
                        value: _enabled,
                        onChanged: busy
                            ? null
                            : (value) => setState(() => _enabled = value),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _service.status.value,
                        key: const Key('webdav-status'),
                      ),
                      if (_message != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(_message!),
                        ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          OutlinedButton(
                            onPressed: busy ? null : () => _save(),
                            child: const Text('保存设置'),
                          ),
                          FilledButton(
                            onPressed: busy ? null : () => _save(sync: true),
                            child: Text(busy ? '请稍候…' : '保存并立即同步'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        '云端已有同步文件时，强制覆盖本机在线书架、阅读进度与已看剧集。本机独有收藏会移除，本机新增收藏和阅读进度不会自动上传；删除已同步的收藏、历史和已看记录会同步到云端，离线删除将在联网后补传。只有云端文件不存在时，才用本机数据建立初始备份。AI 资产沿用备份恢复的合并规则。\n\n'
                        '同步期间的本机修改不会被本次云端响应覆盖；期间删除的记录会继续同步。若云端包含本机存储无法区分的同 ID 跨类型历史，将停止同步并保留双方数据。\n\n'
                        '不上传本地书籍、下载缓存或账号密码。密码保存在设备安全存储中；云端同步文件包含书架与进度，请使用私人目录。服务器需支持 ETag 和条件写入。',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
