# 构建与维护脚本

除单独注明工作目录外，下列命令从仓库根目录执行。脚本路径被 CI、Gradle 或测试引用；调整位置时同时更新调用方。

## 常用入口

| 脚本 | 用途 | 依赖与输出 |
| --- | --- | --- |
| [build_rust_backend.ps1](build_rust_backend.ps1) / [.sh](build_rust_backend.sh) | 生成 FRB 绑定并交叉编译 Rust ARM64 核心 | Rust、NDK、FRB codegen 2.13.0；输出到 `android/app/src/main/jniLibs/arm64-v8a/` |
| [run_rust_host_tests.ps1](run_rust_host_tests.ps1) / [.sh](run_rust_host_tests.sh) | 构建宿主核心，运行真实 Dart → FRB → Rust 集成测试 | Rust、Flutter；使用本地 Mock 上游和临时运行目录 |
| [verify_android_apk.py](verify_android_apk.py) | 检查 APK 签名、库、版本、资源及 16 KiB 对齐 | Python 3、Android Build-Tools；报告目录由参数指定 |
| [check_native_alignment.cjs](check_native_alignment.cjs) | 检查一个或多个 ARM64 ELF 库的 LOAD 段对齐 | Node.js；只读取指定 `.so` |
| [verify_audio_cenc.cjs](verify_audio_cenc.cjs) | 检查播放响应和加密 AAC 样本 | Node.js；会按响应中的地址有限下载 HTTPS 音频，属于在线诊断 |
| [generate_app_icons.py](generate_app_icons.py) | 从品牌源图生成 Android 图标及应用 Logo | Python 3、Pillow；修改已提交图片，普通构建直接使用现有图片 |

## Rust 构建与宿主集成

先准备 Flutter 依赖，再生成绑定：

```powershell
flutter pub get --enforce-lockfile
.\scripts\build_rust_backend.ps1
.\scripts\run_rust_host_tests.ps1
```

Linux/macOS 对应：

```bash
flutter pub get --enforce-lockfile
bash scripts/build_rust_backend.sh
bash scripts/run_rust_host_tests.sh
```

Windows 构建开关为 `-SkipCodegen`、`-HostLib`、`-Profile debug`；Shell 版对应 `--skip-codegen`、`--host-lib`、`--profile debug`。宿主测试的 `-SkipBuild` / `--skip-build` 只在宿主库已经更新时使用。

FRB 绑定发生变化时，还需再次生成并比较内容哈希，确认可复现。生成的文件位置见 [目录说明](../docs/project-structure.md)。

## 常规验证

```powershell
cargo fmt --manifest-path rust/Cargo.toml --check
cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path rust/Cargo.toml --locked
flutter analyze --no-pub
flutter test --no-pub --concurrency=2
node --test test/web_assets_test.cjs test/verify_audio_cenc_test.cjs test/build_rust_backend_scripts_test.cjs
```

`flutter test` 在宿主动态库存在时会运行 FRB 集成；库缺失时相关测试会明确跳过。`run_rust_host_tests.*` 可先重建宿主库再执行这组测试。C/JNI 主机回归和编译器要求见 [native/README.md](../native/README.md)。Android JVM 测试须在 `android/` 目录中执行：Windows 使用 `.\gradlew.bat :app:testDebugUnitTest`，Linux/macOS 使用 `./gradlew :app:testDebugUnitTest`。

## APK、诊断与资源

```powershell
flutter build apk --release --target-platform android-arm64 --no-pub
python scripts/verify_android_apk.py --help
node scripts/check_native_alignment.cjs android/app/src/main/jniLibs/arm64-v8a/libfqapi_core.so
node scripts/verify_audio_cenc.cjs build/diagnostics/play-response.json
python scripts/generate_app_icons.py
```

APK 校验须传入 `--apk`、`--build-tools`、`--report-dir` 以及预期签名指纹，完整示例见 [发布签名](../docs/release-signing.md)。`--help` 只显示参数，不算通过 APK 验证。

`verify_audio_cenc.cjs` 的 AAC 样本头匹配是诊断线索，不等于解码器播放成功。图标生成细节见 [品牌资源说明](../assets/branding/README.md)。诊断输出放在 `build/`；经用户验收的发布资料按版本存入 `release-archives/`。
