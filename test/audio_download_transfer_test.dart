import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/audio_download_transfer.dart';

void main() {
  group('isRetryableAudioDownloadFailure', () {
    test('network-side and timeout failures are retried', () {
      for (final reason in [
        '下载超时',
        '下载不完整',
        '续传响应范围无效',
        'SocketException: 连接被重置',
        '下载失败（HTTP 408）',
        '下载失败（HTTP 429）',
        '下载失败（HTTP 503）',
      ]) {
        expect(
          isRetryableAudioDownloadFailure(reason),
          isTrue,
          reason: '$reason 值得再试',
        );
      }
    });

    test('permanent and deterministic failures are not', () {
      for (final reason in [
        '无效的章节或音色',
        '取流结果与章节不匹配',
        '该章没有可下载的音频地址',
        '下载失败（HTTP 404）',
        '下载失败（HTTP 416）',
      ]) {
        expect(
          isRetryableAudioDownloadFailure(reason),
          isFalse,
          reason: '$reason 重试也是同一个结果',
        );
      }
    });
  });

  group('audioDownloadFailureReason', () {
    test('turns a transport timeout into a readable reason', () {
      expect(
        audioDownloadFailureReason(TimeoutException('Future not completed')),
        '下载超时',
      );
    });

    test('keeps other exception text for the task panel', () {
      expect(
        audioDownloadFailureReason(const FileSystemException('写入失败')),
        contains('写入失败'),
      );
    });
  });

  group('commitAudioDownload', () {
    late Directory temp;
    late File part;
    late String finalPath;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('fqapp-audio-commit-');
      part = File('${temp.path}${Platform.pathSeparator}chapter.m4a.part')
        ..writeAsBytesSync([1, 2, 3, 4]);
      finalPath = '${temp.path}${Platform.pathSeparator}chapter.m4a';
    });

    tearDown(() async {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    });

    test('renames, then saves, when the download was not aborted', () async {
      var saved = false;
      final committed = await commitAudioDownload(
        partFile: part,
        finalPath: finalPath,
        isAborted: () => false,
        save: () async => saved = true,
      );

      expect(committed, isTrue);
      expect(saved, isTrue);
      expect(File(finalPath).readAsBytesSync(), [1, 2, 3, 4]);
      expect(part.existsSync(), isFalse);
    });

    test('an abort before the rename leaves nothing behind', () async {
      var saved = false;
      final committed = await commitAudioDownload(
        partFile: part,
        finalPath: finalPath,
        isAborted: () => true,
        save: () async => saved = true,
      );

      expect(committed, isFalse);
      expect(saved, isFalse);
      expect(part.existsSync(), isTrue);
      expect(File(finalPath).existsSync(), isFalse);
    });

    test('an abort during the rename never resurrects the record', () async {
      // 第一次检查（改名之前）说没放弃，第二次（改名之后、登记之前）说已放弃：
      // 这正是 discard 落在 `await partFile.rename(...)` 上的那一拍。
      var checks = 0;
      var saved = false;
      final committed = await commitAudioDownload(
        partFile: part,
        finalPath: finalPath,
        isAborted: () => ++checks > 1,
        save: () async => saved = true,
      );

      expect(checks, 2, reason: '登记前必须再查一次放弃信号');
      expect(committed, isFalse);
      expect(saved, isFalse, reason: '用户刚删掉的下载不能被旧协程写回记录');
      expect(File(finalPath).existsSync(), isTrue, reason: '改名已经发生');
    });

    test(
      'a rename that cannot replace the target still saves the chapter',
      () async {
        // 目标路径被目录占住：改名必然抛 FileSystemException，走「以已存在
        // 终稿为准」的分支，半成品要删掉、记录照写。
        Directory(finalPath).createSync();
        var saved = false;
        final committed = await commitAudioDownload(
          partFile: part,
          finalPath: finalPath,
          isAborted: () => false,
          save: () async => saved = true,
        );

        expect(committed, isTrue);
        expect(saved, isTrue);
        expect(part.existsSync(), isFalse);
        expect(Directory(finalPath).existsSync(), isTrue);
      },
    );
  });
}
