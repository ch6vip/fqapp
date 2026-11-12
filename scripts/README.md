# 构建与维护脚本

除单独注明工作目录外，下列命令从仓库根目录执行。脚本路径被 CI、Gradle 或测试引用；调整位置时同时更新调用方。

## 常用入口

| 脚本 | 用途 | 依赖与输出 |
| --- | --- | --- |
| [format_all.ps1](format_all.ps1) / [.sh](format_all.sh) | 格式化 Dart、手写 Rust 和 `scripts/` 中的 JavaScript；支持只检查与按改动范围执行 | Git、Node.js 22+、Dart、rustfmt、锁定的 Prettier；安装与范围见下文 |
| [build_rust_backend.ps1](build_rust_backend.ps1) / [.sh](build_rust_backend.sh) | 生成 FRB 绑定并交叉编译 Rust 核心（arm64-v8a + armeabi-v7a） | Rust、NDK、FRB codegen 2.13.0；输出到 `android/app/src/main/jniLibs/<abi>/` |
| [run_rust_host_tests.ps1](run_rust_host_tests.ps1) / [.sh](run_rust_host_tests.sh) | 构建宿主核心，运行真实 Dart → FRB → Rust 集成测试 | Rust、Flutter；使用本地 Mock 上游和临时运行目录 |
| [verify_android_apk.py](verify_android_apk.py) | 检查 APK 签名、库、版本、资源及 16 KiB 对齐 | Python 3、Android Build-Tools；报告目录由参数指定 |
| [check_native_alignment.cjs](check_native_alignment.cjs) | 检查一个或多个 ELF 库（ARM64/ARM）的 LOAD 段对齐 | Node.js；只读取指定 `.so` |
| [check_line_budget.sh](check_line_budget.sh) | 仅供参考的源码行数报告，无固定上限，不判断通过/失败 | Bash、Python 3、Git；只读已跟踪源码，列出最大的 20 个文件；无预算更新操作，CI 不因此阻塞 |
| [check_so_freshness.cjs](check_so_freshness.cjs) | 打版前检查 `libfqapi_core.so` 是否比 `rust/` 的最新改动新（判据 CRIT-011）；mtime 不是内容证明，`--expect-sha256` 可比对内容哈希 | Node.js、git；只读取文件时间与 git 历史；未接入 CI（CI 每次重编 Rust） |
| [verify_audio_cenc.cjs](verify_audio_cenc.cjs) | 检查播放响应和加密 AAC 样本 | Node.js；会按响应中的地址有限下载 HTTPS 音频，属于在线诊断 |
| [generate_app_icons.py](generate_app_icons.py) | 从品牌源图生成 Android 图标、Windows 图标及应用 Logo | Python 3、Pillow ≥ 9.1；修改已提交图片，普通构建直接使用现有图片 |
| [make_test_media.py](make_test_media.py) | 用 ffmpeg 内置信号源合成播放夹具（MP4 + HLS + 密钥素材） | Python 3、ffmpeg/ffprobe；缺工具时 `--check` 退出码 2，输出到 `build/test-media/`；参数错误先于工具链检查报告，回归见 `test/make_test_media_test.cjs` |

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

FRB 绑定发生变化时，还需再次生成并比较内容哈希，确认可复现。生成的文件位置见本地 `docs/project-structure.md`（不入库）。

## 统一代码格式

首次安装使用 `npm ci --ignore-scripts`（只安装开发工具 Prettier，不影响 App 依赖），
并运行 `flutter pub get --enforce-lockfile`，使 Dart 格式器读到与包一致的语言版本。
CI 固定 Flutter 3.47.9 / Dart 3.13.7、Rust 1.99.1 和 Node.js 22；Prettier 3.10.0
由 `package.json` 与 `package-lock.json` 锁定。Rust 缺格式器时运行
`rustup component add rustfmt --toolchain 1.99.1`。本地建议使用相同版本，入口会打印
实际使用的工具版本；可通过进程环境 `RUSTUP_TOOLCHAIN=1.99.1` 选择该 Rust 工具链。

Windows PowerShell：

```powershell
.\scripts\format_all.ps1                         # 格式化全部支持的源码
.\scripts\format_all.ps1 -Check                  # 只检查，不写源码
.\scripts\format_all.ps1 -Since origin/master    # 仅处理本分支改动涉及的文件
.\scripts\format_all.ps1 -Check -Language rust
```

Linux / macOS / Git Bash：

```bash
bash scripts/format_all.sh
bash scripts/format_all.sh --check
bash scripts/format_all.sh --since origin/master
bash scripts/format_all.sh --check --language rust
```

两个入口共用 `format_all.cjs`，可从任意工作目录调用；也可使用 `npm run format`、
`npm run format:check -- --since origin/master`。`-Language` / `--language` 可选
`all`、`dart`、`rust`、`javascript`。`-Since` / `--since` 以指定引用与 HEAD 的
merge base 为起点，同时包含暂存、未暂存和未被 Git 忽略的新文件；删除文件不处理，
引用不存在则报错。文件按 NUL 分隔读取并分批传给工具，支持空格路径与 Windows 命令行长度限制。
共享入口的工具准备或参数错误退出 2，检查发现格式问题退出 1，格式器自身错误也以非零
退出；成功（或增量范围内无匹配文件）退出 0。PowerShell 参数绑定错误遵循其退出码。
全量范围为空时报错，所需工具会在写入前统一检查，脚本不会自行下载依赖。

首阶段范围遵循 [#326 的维护者说明](https://github.com/ch6vip/novel-sound/issues/326#issuecomment-6805536952)：

| 语言 | 文件范围 | 固定规则 |
| --- | --- | --- |
| Dart | `lib/`、`test/`、`integration_test/`、`scripts/` 中的 `.dart` | `analysis_options.yaml` 的 `formatter`：80 列、自动尾逗号 |
| Rust | `rust/` 中的手写 `.rs`，含 `build.rs` 与已有测试 | 根目录 `rustfmt.toml`：edition/style edition 2021、100 列、4 空格 |
| JavaScript | `scripts/` 中的 `.js`、`.cjs`、`.mjs` | `.prettierrc.json`：80 列、2 空格、单引号、分号、尾逗号 |

`lib/src/rust/`、`frb_generated*.rs`、Dart 的 `.g.dart` / `.freezed.dart`、第三方代码、
构建目录及 Git 忽略的本地资料不在范围内。Rust 显式枚举各文件并传入
`--config skip_children=true`，防止沿 `mod` 进入生成绑定；stable rustfmt 会忽略 TOML
中的该选项，因此必须放在命令行。不要用 `cargo fmt --all` 替代此入口。
`.editorconfig` 与 `.gitattributes` 保持支持语言的缩进和 LF 换行一致；旧 Windows
工作区保留的 CRLF 也会被 `--check` 报告，格式化后统一为 LF。
Dart 原生格式器保留原换行，因此入口会额外检查，并在格式化成功后规范为 LF；
该步骤同样遵守增量范围和生成文件排除规则。
C/C++、Kotlin/Java、Python、PowerShell/Shell 的自动格式化留待各自规则确定后扩展。

`.github/workflows/format.yml` 在 PR 与 master push 中检查本次改动的文件，并全量检查
已有 Rust 和本次建立的 JavaScript 格式基线；手动触发检查这两项全量基线。
历史 Dart 格式随相关文件后续修改逐步收敛；当前全量 `--check` 可能报告已有差异，
本次工具接入不批量改写 Dart 或既有测试。CI 始终只检查，不写入、不自动提交格式修改。

## 常规验证

```powershell
.\scripts\format_all.ps1 -Check -Language rust
cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path rust/Cargo.toml --locked
flutter analyze --no-pub
flutter test --no-pub --concurrency=2
node --test test/web_assets_test.cjs test/verify_audio_cenc_test.cjs test/build_rust_backend_scripts_test.cjs
```

`flutter test` 在宿主动态库存在时会运行 FRB 集成；库缺失时相关测试会明确跳过。`run_rust_host_tests.*` 可先重建宿主库再执行这组测试。C/JNI 主机回归和编译器要求见 [native/README.md](../native/README.md)。Android JVM 测试须在 `android/` 目录中执行：Windows 使用 `.\gradlew.bat :app:testDebugUnitTest`，Linux/macOS 使用 `./gradlew :app:testDebugUnitTest`。

## APK、诊断与资源

### 合成媒体夹具

真机播放检查不必依赖上游抓包（文案、域名、凭据都会变，换台机器就复现不了）。
`make_test_media.py` 用 ffmpeg 内置信号源生成一份可重放的夹具：

```powershell
python scripts/make_test_media.py --check            # 只报工具链是否齐全，缺工具退出码 3
python scripts/make_test_media.py                    # build/test-media/：clear.mp4 + HLS + key.bin
python scripts/make_test_media.py --seconds 12 --size 640x360 --force
```

产物全部落在 `build/`（已忽略）。给定 `--seconds/--size` 时，**同一套 ffmpeg 构建**下逐字节可复现，
因此 `fixture.json` 里的 `clip_sha256` 可以当断言用；`fixture.json` 同时记录了 `ffmpeg` 版本，
换机器后哈希不同先对版本，而不是怀疑夹具本身。

生成的 `clear.m3u8` 是**明文**播放列表（分片没有加密，播放列表里没有 `EXT-X-KEY` 行）。
`key.bin` 只是提供与解密清单同形的密钥素材——16 字节原始密钥加一个 `key-info.txt` 指针，
供需要加密播放列表的用例自行用 `-hls_key_info_file` 重新生成，不要以为它已经被接上了。

顺带说清上游身份参数的位置：`version_name`/`version_code`/UA 这类**设备注册**用的值改
`assets/config/config.json` 的 `upstream` 段、重新打包即可（缺省值与改动前一致）。范围仅限
设备注册：正文 / 目录 / 搜索 / 短剧端点的版本号仍写死在 `rust/src/endpoints/*.rs`，通用请求 UA
在 `rust/src/upstream/client.rs` 的 `DEFAULT_USER_AGENT`。`config.json` 随包发布，设备上的部署
副本每次启动都会被包内副本覆盖；身份在后端每次启动时重新读取，但要换配置仍需重新打包并重启
App。上游改的是签名算法或注册协议（逻辑）时同样要发版。

改的时候注意三点（细节见 `DEVELOPMENT.md`）：`version_name` 和 `version_code` 是同一个版本的两种
写法、无法互相推导，**必须一起写**，只写一个后端会当作配置错误拒绝启动；段内字段名写错
（`useragent` 而不是 `user_agent`）同样会让 `Config::load` 失败，不会被静默忽略；改了版本号后，
**用旧版本号注册的设备会在后端启动时退役**，不会继续被发出去。

### 番茄采集的本机转换

将应用导出的原始 ZIP 解包到独立目录后，可直接使用 Dart 转换为兼容本机备份格式的 JSON：

```powershell
dart scripts/convert_fanqie_capture.dart <解包目录> <新输出文件.json> [目录响应缓存目录]
```

转换器与 Android 导入共用小说筛选、去重和章节 ID 匹配代码；输出包含书架和历史。
可选缓存目录中的 `<bookId>.json` 为现有 `/api/directory` 接口的完整响应。
没有目录时保留章节 ID，不猜章节序号；不会下载正文或访问账号。输出含个人阅读数据，请勿入库。

```powershell
flutter build apk --release --target-platform android-arm,android-arm64 --split-per-abi --no-pub
python scripts/verify_android_apk.py --help
node scripts/check_native_alignment.cjs android/app/src/main/jniLibs/arm64-v8a/libfqapi_core.so android/app/src/main/jniLibs/armeabi-v7a/libfqapi_core.so
node scripts/check_so_freshness.cjs android/app/src/main/jniLibs/arm64-v8a/libfqapi_core.so --since v1.0.88

`check_so_freshness.cjs` 未接入 CI：CI 每次都从源码重编 Rust 核心，不需要它。且它的 mtime 比较不是内容证明——`touch`、时钟偏差、用不同源码重编出相同 mtime 都能骗过它；git 历史比较也只看到已提交的 `rust/` 改动，未提交文件只靠 mtime。它只是本地快速辅查，可靠做法是重编，或用 `--expect-sha256 <构建时记录的哈希>` 比对库内容。
node scripts/verify_audio_cenc.cjs build/diagnostics/play-response.json
python scripts/generate_app_icons.py
```

APK 校验须传入 `--apk`、`--build-tools`、`--report-dir` 以及预期签名指纹，完整示例见本地
`docs/release-signing.md`（不入库）。只在没有正式签名材料的场景（fork、本地检视构建）才加
`--allow-unsigned`，此时报告里 `signature.signed` 为 `false`，其余检查照常执行。
`--help` 只显示参数，不算通过 APK 验证。

`verify_audio_cenc.cjs` 的 AAC 样本头匹配是诊断线索，不等于解码器播放成功。图标生成细节见 [品牌资源说明](../assets/branding/README.md)。诊断输出放在 `build/`；经用户验收的发布资料按版本存入 `release-archives/`。
