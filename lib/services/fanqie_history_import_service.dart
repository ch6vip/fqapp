import 'platform_channel.dart';
import 'package:flutter/services.dart';

import '../models/fanqie_history.dart';

class FanqieHistoryImportService {
  static const _files = AppMethodChannel('fqapp/library_backup');

  Future<FanqieHistoryPreview?> pickFile() async {
    final bytes = await _files.invokeMethod<Uint8List>('openBackup');
    return bytes == null ? null : FanqieHistoryPreview.fromBytes(bytes);
  }
}
