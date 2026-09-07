# C 流式解密库

本目录是项目自行实现的 CENC MP4 流式解密库，替代之前只有二进制的外部依赖。
Android 仍加载 `libshortplay_crypto.so`，保留 `com.example.shortplay.CryptoNative` 的 JNI 接口；
`` 继续提供 CDN URL 和 16 字节内容密钥，ExoPlayer 按文件偏移读取解密后的 MP4。

## 实现与范围

- [sp_stream.c](crypto_core/sp_stream.c)：只读取顶层 box 头和 `moov` 索引，跳过 `mdat`；
  播放时按需读取，每次最多 64 KiB，按加密样本/子样本交集解密。支持前置/尾置 `moov`、
  64 位偏移、多个 `mdat`、任意字节 seek，保持完整文件长度和所有数据偏移不变。
- [mp4_cenc.c](crypto_core/mp4_cenc.c)：验证每个父子 box 的边界、样本表、轨道间重叠、
  `tenc`、`senc` 和可选的 `saiz/saio`；恢复 `frma` 原格式，将保护信息改成等长 `free`。
- [sp_aes.c](crypto_core/sp_aes.c)：封装 [tiny-AES-c](third_party/tiny_aes/README.md) 的 AES-128。
  CTR 位置按每个样本已消耗的加密字节计算；clear 子样本不消耗密钥流。支持 8/16 字节 IV。
  第三方源码固定版本，原始 Unlicense 与文件哈希随源码保存。
- [jni_bridge.c](android/jni_bridge.c)：将 C 的 I/O 回调接到 OkHttp，保留 open/read/seek/size/close。
  句柄表检查失效句柄，按句柄串行执行，通过引用计数与取消状态保护关闭过程中的并发访问。

首版支持非分片 MP4 的 `cenc` AES-CTR、单个内容密钥、内联 `senc`，包括加密音频和视频、
整样本与子样本加密、固定/逐样本 `stsz`、`stsc`、`stco/co64`。
不支持的分片 MP4、CBC/pattern 模式、密钥轮换、多个 KID、外置辅助加密数据、`stz2`、
加密轨的多个 sample description 等会明确报错。H.264、H.265 和 AAC 有真实媒体回归；
不能由这些测试推断所有编码格式或所有 CDN 文件均已验证。

`moov` 上限为 16 MiB，全文件累计最多 1,000,000 个样本、2,000,000 个子样本和
4,096 个顶层 box。内存主要用于有界的元数据索引与 JNI 缓冲，不随整集文件大小分配。
不会提前下载完整 `mdat`。拖动取消当前请求，后续 read 再从新偏移连接。

## Android 构建

Gradle `externalNativeBuild` 使用本目录 [CMakeLists.txt](CMakeLists.txt)，
固定 NDK `28.2.13676358`、CMake `3.22.1`，自动生成并打包 ARM64 crypto 库。
共享库显式设置 `max-page-size=16384` 和 `common-page-size=16384`，未增加运行时共享库依赖。
Go JNI 库仍由 `scripts/build_backend.ps1 -Jni` / `build_backend.sh --jni` 生成。

升级旧工作区时，把 `android/app/src/main/jniLibs/arm64-v8a/libshortplay_crypto.so`
备份到 `jniLibs` 之外。预编译旧库与 CMake 产物不能同时打包，Gradle 会提示清理旧输入。
JNI 方法名保留，但网络回调增加了长度探测和分两步准备/连接请求，必须将 Kotlin 与新库一起构建。

```powershell
flutter build apk --release --target-platform android-arm64
```

ELF 的 LOAD 段和 APK ZIP 都需要满足 16 KiB 对齐，构建后还需在 16 KiB 页 Android 设备上
验证实际播放、拖动和生命周期；仅通过链接检查不能视为设备验证完成。
可用 `node scripts/check_native_alignment.cjs path/to/library.so` 检查 ARM64 ELF 程序头、
LOAD 段对齐和文件偏移/虚拟地址同余条件；APK 内的所有 `.so` 都应检查。

## I/O 与生命周期

`sp_stream_open` 成功后接管 `sp_io.user`；失败时仍由调用者清理。除 cancel 外，C 核心的
同一句柄操作必须串行；JNI 层负责该串行化。read 在 EOF 返回 0，遇到错误返回负值；
seek 接受 `[0, size]`，失败不改变读取位置。JNI 将错误转为 `IOException`，不会当作正常 EOF。

Android 通过 `Range: bytes=0-0` 的有效 206 响应确认文件长度与 Range 支持。
每个后续请求还验证总长度、范围和编码，短响应按错误处理。Java 在连接前注册请求 ID，
已打开句柄的 close 可取消正在等待响应头或响应体的请求，再等待操作引用释放。

首次同步 open 在读取完元数据后才返回句柄；此阶段不能通过 `close(handle)` 提前取消。
页面的待创建标记会阻止迟到的探测结果创建播放器；网络操作仍需结束或触发传输超时。
预热接口只进行元数据打开/关闭，不保留全局视频数据缓存。

## 验证

主机测试需要 Node.js、可执行本机程序的 C11 编译器，以及带 libx264/libx265/AAC 的 FFmpeg。
Linux/macOS 可用 `cc`/Clang；Windows 可用 Zig 的 `zig cc`，通过 `NATIVE_CC` 指定 `zig.exe`。
NDK 的 Android 编译器用于生成 APK 库，不用于运行主机测试。

```powershell
$env:NATIVE_CC = 'C:\tools\zig\zig.exe'
node --test --test-concurrency=1 test/native_aes_test.cjs test/native_crypto_test.cjs test/native_crypto_media_test.cjs
```

Linux 内存与未定义行为检查：

```bash
NATIVE_CC=clang NATIVE_CFLAGS='-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer' \
  node --test --test-concurrency=1 test/native_aes_test.cjs test/native_crypto_test.cjs test/native_crypto_media_test.cjs
NATIVE_CC=clang NATIVE_JNI_REQUIRED=1 node --test test/native_jni_test.cjs
```

AES 对照使用 NIST 向量和 Node/OpenSSL；MP4 对照由 Node 独立加密、生成明文基准。
原生 driver 检查完整输出、随机 seek、短读、取消、错误、打开时未读取媒体数据，以及损坏输入变异。
FFmpeg 测试比较解密前后的每个 H.264/H.265 视频帧和 AAC 音频帧。
Linux/JDK 测试通过 `-Xcheck:jni` 执行真实 JNI 库，覆盖并发关闭和请求释放；Windows 会明确跳过它。
[GitHub Actions](../.github/workflows/native-crypto.yml) 自动执行这两组 Linux 验证。
