import 'dart:convert';
import 'dart:typed_data';

/// A collection of upstream responses, deliberately separate from local
/// reading state. Unknown fields survive until their meaning is established.
class FanqieLibraryCapture {
  static const maxBytes = 16 * 1024 * 1024;
  final Map<String, dynamic> document;

  FanqieLibraryCapture(this.document);

  List<Map<String, dynamic>> get sources =>
      (document['sources'] as List).cast<Map<String, dynamic>>();
  int get received => sources.where((s) => s['status'] == 'received').length;
  int get failed => sources.where((s) => s['status'] == 'failed').length;
  String get stopReason => document['stopReason'] as String? ?? '';
  List<String> get parts =>
      (document['parts'] as List? ?? const []).cast<String>();

  Uint8List encode() {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(document)));
    if (bytes.length > maxBytes) throw const FormatException('采集文件超过 16 MB');
    return bytes;
  }

  factory FanqieLibraryCapture.decode(Uint8List bytes) {
    if (bytes.length > maxBytes) throw const FormatException('采集文件超过 16 MB');
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Map<String, dynamic> ||
        raw['format'] != 'fqapp.fanqie-library-capture' ||
        !const [1, 2].contains(raw['version']) ||
        raw['sources'] is! List ||
        (raw['sources'] as List).any((s) => s is! Map<String, dynamic>)) {
      throw const FormatException('不是支持的番茄书架采集文件');
    }
    return FanqieLibraryCapture(raw);
  }
}
