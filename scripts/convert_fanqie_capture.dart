import 'dart:convert';
import 'dart:io';

// Kept runnable directly with the bundled Dart SDK, without Flutter startup.
// ignore: avoid_relative_lib_imports
import '../lib/models/fanqie_library_import.dart';
// ignore: avoid_relative_lib_imports
import '../lib/models/media_item.dart';

/// Converts an exported, unpacked capture into a portable local-library backup.
/// No credentials or network requests; output contains personal reading data.
Future<void> main(List<String> args) async {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln(
      'Usage: dart scripts/convert_fanqie_capture.dart <capture-directory> <output.json>',
    );
    exitCode = 64;
    return;
  }
  final root = Directory(args[0]).absolute;
  if (File(args[1]).existsSync()) {
    throw const FormatException('输出文件已存在，请使用新文件名');
  }
  final manifest =
      jsonDecode(await File('${root.path}/manifest.json').readAsString())
          as Map;
  if (manifest['format'] != 'fqapp.fanqie-library-capture') {
    throw const FormatException('Unsupported capture');
  }
  final parser = FanqieLibraryImport();
  for (final name in manifest['parts'] as List? ?? const []) {
    if (name is! String ||
        !RegExp(r'^part-[0-9]+-[a-fA-F0-9-]+\.json$').hasMatch(name)) {
      throw const FormatException('Invalid part name');
    }
    final part =
        jsonDecode(await File('${root.path}/$name').readAsString()) as Map;
    if (part['format'] != 'fqapp.fanqie-library-part' || part['version'] != 1) {
      throw const FormatException('Unsupported part');
    }
    for (final source in part['sources'] as List) {
      parser.addSource(Map<String, dynamic>.from(source as Map));
    }
  }
  if ((manifest['parts'] as List? ?? const []).isEmpty) {
    for (final source in manifest['sources'] as List) {
      parser.addSource(Map<String, dynamic>.from(source as Map));
    }
  }
  final records = parser.records;
  var matched = 0;
  if (args.length == 3) {
    for (final record in records) {
      final file = File('${args[2]}/${record['id']}.json');
      if (!file.existsSync() || record['chapterId'] == null) continue;
      final payload =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final chapters = parseDirectory(payload).expand((v) => v).toList();
      if (resolveFanqieChapter(record, chapters)) matched++;
    }
  }
  await File(args[1]).writeAsString(
    jsonEncode({
      'format': 'fqapp.library-backup',
      'version': 1,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'shelf': [
        for (final record in records) {...record, 'addedAt': record['time']},
      ],
      'history': records,
      'watched': [],
    }),
  );
  stdout.writeln(
    jsonEncode({
      'novels': records.length,
      'withCover': records
          .where((r) => (r['cover'] as String).isNotEmpty)
          .length,
      'withTitle': records
          .where((r) => (r['title'] as String).isNotEmpty)
          .length,
      'withChapterId': records.where((r) => r['chapterId'] != null).length,
      'skippedNonNovelOrDeleted': parser.skipped,
      'receivedResponses': parser.received,
      'failedResponses': parser.failed,
      'directoryMatched': matched,
    }),
  );
}
