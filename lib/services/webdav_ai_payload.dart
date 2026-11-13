import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'ai_reading/ai_backup.dart';

typedef WebDavAiPayload = ({AiBackupPayload payload, String fingerprint});

/// Decompression and validation run outside the UI isolate. The limit applies
/// to expanded bytes, rather than the much smaller base64/gzip representation.
Future<WebDavAiPayload> decodeWebDavAi(
  String encoded, {
  int maxBytes = 64 * 1024 * 1024,
}) => Isolate.run(() {
  final output = _LimitedBytes(maxBytes);
  final decoder = gzip.decoder.startChunkedConversion(output);
  final compressed = base64Decode(encoded);
  for (var offset = 0; offset < compressed.length; offset += 4096) {
    final end = offset + 4096 < compressed.length
        ? offset + 4096
        : compressed.length;
    decoder.add(Uint8List.sublistView(compressed, offset, end));
  }
  decoder.close();
  final raw = jsonDecode(utf8.decode(output.bytes.takeBytes()));
  final payload = AiBackupPayload.fromJson(raw);
  final canonical = Map<String, dynamic>.from(raw as Map)..remove('createdAt');
  return (
    payload: payload,
    fingerprint: sha256.convert(utf8.encode(jsonEncode(canonical))).toString(),
  );
});

class _LimitedBytes implements Sink<List<int>> {
  _LimitedBytes(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw const FormatException('AI 备份解压后超过大小限制');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}
