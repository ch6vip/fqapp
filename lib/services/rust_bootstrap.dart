/// 平台相关的 Rust 运行时初始化入口。
///
/// 原生平台（含 iOS）用 `rust_bootstrap_io.dart`，Web 用 `rust_bootstrap_stub.dart`。
/// iOS 需要专门处理：Rust 静态库直接链进主二进制，只能通过
/// `ExternalLibrary.process()` 查找符号，不能按文件名 dlopen。
library;

export 'rust_bootstrap_stub.dart' if (dart.library.io) 'rust_bootstrap_io.dart';
