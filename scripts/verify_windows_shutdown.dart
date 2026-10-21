import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:fqapp/services/desktop_platform.dart';

/// Standalone native runner regression: exercises the normal close callback
/// without injecting OS input or reading the user's library.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DesktopPlatform.instance.initialize();
  DesktopPlatform.instance.beforeClose = () async {
    final marker = File('build/validation/windows-shutdown-requested.txt');
    await marker.parent.create(recursive: true);
    await marker.writeAsString('beforeClose completed', flush: true);
  };
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Windows 窗口退出回归测试'))),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Timer(const Duration(seconds: 1), DesktopPlatform.instance.onWindowClose);
  });
}
