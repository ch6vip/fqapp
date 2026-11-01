import '../src/rust/frb_generated.dart';

/// 初始化 flutter_rust_bridge 运行时（Web 平台，无原生库）。
///
/// Web 目标当前不用于发货包，但保留与 native 一致的入口，避免调用方做平台分支。
Future<void> initRustRuntime() => RustLib.init();
