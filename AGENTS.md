# AGENTS.md — fqapp 协作指南

本文件是代理在本仓库的执行入口，记录项目边界、常用命令和交付要求。使用中文沟通，先完成用户要求的工作，再报告结果与未验项。

用户当前的明确要求优先于本文件和本地文档；已经给出的授权与限制在任务续接时仍有效。本文定义默认工作方式，`docs/` 提供实现细节与历史证据，旧文档不得扩大本轮任务、测试或发布范围。版本与命令以受 Git 跟踪的配置和脚本为准。

`docs/`、`.agents/` 和 `release-archives/` 只保存在本地，不随源码分发。新检出缺少这些目录时，先依据本文件、`README.md`、`DEVELOPMENT.md` 和 `scripts/README.md` 工作，不把缺少本地历史资料当成阻塞。

<!-- Note: 重写依据见 .agents/notes/implemented/simplification/2026-10-12-agent-guide-rewrite.md（仅本地）。 -->

## 1. 项目与技术基线

- fqapp 是内容聚合 Android 客户端，提供小说阅读、听书、短剧、漫剧和漫画。Flutter UI 通过 flutter_rust_bridge 调用进程内 Rust 核心 `fqapi_core`；`127.0.0.1:8080` loopback 服务承载 Web UI 与漫画图。无需 root，不部署独立后端进程。
- 提供只读的番茄账号导入（网页登录后读取书架/历史/进度，不回写账号）；除此之外不提供登录或上游账号写操作。已裁撤的追剧、点赞、分享等入口不作为待办恢复。已有本机书架与详情页收藏按现有产品范围保留；没有真实能力时不放占位控件。
- 基线：Flutter **3.44.6 stable**、Dart **^3.12.2**、Rust stable；FRB 的 Rust crate、Dart 包和 codegen **统一固定 2.13.0**。
- Android：SDK 36、NDK **28.2.13676358**、JDK 17、Gradle **9.1.0**；构建 `arm64-v8a` + `armeabi-v7a` 两个 ABI，`--split-per-abi` 分包出两个 APK。原生 C CENC 库由 CMake 生成 `libshortplay_crypto.so`，原生库须满足 **16 KiB** 对齐。
- 状态存储使用 Hive（`LibraryStore`）与 SharedPreferences。依赖、工具链或架构调整须服务于当前任务，不顺手升级。

| 路径 | 职责 |
| --- | --- |
| `lib/`、`test/` | Flutter 页面、组件、服务、模型及测试 |
| `rust/src/`、`rust/tests/`、`rust/testdata/` | 原生核心、协议回归与离线黄金夹具 |
| `native/` | C 流式解密与原生测试 |
| `android/` | 平台插件、签名打包配置与 JVM 测试 |
| `assets/`、`rust/assets/` | Flutter 部署资源与 Rust 内嵌资源，各有加载入口 |
| `scripts/`、`.github/workflows/` | 构建、校验脚本与 CI 配置 |

## 2. 开工与范围控制

1. **查基线**：执行 `git status --short --branch`，核对当前提交、暂存区和工作区差异；区分既有修改与本轮改动。保留用户的未提交文件和不相关未跟踪文件，禁止为得到干净工作树而重置或清理它们。
2. **查经验**：按本轮症状检索本地 `docs/规范/踩坑判据.md`，相关错误先查既有判据，再推导修法。
3. **查任务**：阅读本地 `docs/规范/待办清单.md` 的相关条目，确认已完成、挂起和排除的范围。用户只问建议时给建议，不自动开始下一项开发。
4. 先定位调用入口与现有实现，再做最小必要改动。无关问题记入本地清单，不顺手重构、清缓存、升级依赖或恢复被裁撤的功能。
5. 搜索优先用 `rg` / `rg --files`；独立只读检查可并行。构建、测试、同文件写入及 Git 提交必须串行，避免端口和文件锁冲突。

## 3. 验证：用测试确认改动

代码改动要用测试验证，不靠“看起来对”下结论。定位失败、确认修复、验证改动时都跑测试。代码修改后先做必要的静态分析（`flutter analyze --no-pub`、`git diff --check`）与语法/类型排查，再跑测试确认。

**编译/验证/验收的时机：先把本轮要求的改动全部实现完，再统一编译、统一验证、统一验收。** 不要每改一处就构建一次 APK、每加一行就装一次机、或边写边反复跑全量测试——那会把时间耗在重复构建上，也让人看不清整体是否成立。实现阶段只做必要的语法/类型排查（编辑器内报错、单文件 `analyze`），等改动齐了再：`flutter analyze --no-pub` → 定向测试 → 全量测试 → 构建 → 装机验收，一次走完。中途只有两种情况可以提前打断：编译已经不可能通过（语法/类型错误累积过多），或者实现路线本身被证伪需要换方案。

- 优先跑定向测试（单文件 / 单用例）快速定位和确认。
- 改动涉及共享代码、跨模块行为或有回归风险时，扩大测试范围，覆盖受影响的用例。
- 全量测试套件在需要回归覆盖时跑；CI 会跑全量，本地不必每次都全量，但不能以“没跑”代替验证。

| 改动面 | 验证方式 |
| --- | --- |
| 纯文档、注释、排版 | 检查差异、路径和命令准确性，执行 `git diff --check`；无需构建与测试，不递增版本 |
| Flutter / Dart 逻辑 | `flutter analyze --no-pub` 静态排查；跑定向 `flutter test` 验证，必要时扩大范围 |
| Android 插件 / Kotlin | 选择相关编译任务排查；涉及系统 UI、生命周期时做真机验收；跑定向单元测试 |
| Rust | 检查 `.rs` 格式与 Clippy 静态检查；跑定向 `cargo test` |
| FRB 接口 / 绑定 | 用 2.13.0 codegen 生成，验证代码生成一致性；跑相关绑定测试 |
| C / 构建脚本 / 资源 | 静态差异检查；跑相关测试脚本 |
| APK 交付 | 构建并检查签名、库、版本、资源和 16 KiB 对齐；真机由用户或按需验收 |

- Rust 格式检查使用 `rustfmt --check --edition 2021 --config skip_children=true <文件>`。覆盖检查时枚举 Git 跟踪的全部手写 `.rs`，并包含本轮新增文件；排除 `frb_generated.rs`。禁止使用 `cargo fmt --all -- --check`，也不能只查 `rust/src/lib.rs` 冒充全部检查。
- 需要 Clippy 时使用 `cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings`。协议实现变更必须覆盖受影响的黄金夹具，未执行部分如实列出。
- 门禁串行的原因：loopback `8080` 端口、Cargo target、Gradle 与 FRB 宿主动态库存在独占资源。Windows 符号链接权限导致的已知失败须核实原因后单列，不能记为通过或一概忽略。
- 不为低风险可逆修改添加只复述实现的测试。未执行、跳过、环境失败、代码失败分别记录；定向测试通过不等于全量回归通过。

## 4. 代码边界与不变量

- `rust/src/frb_generated.rs`、`lib/src/rust/` 只能由 codegen 更新，禁止手改。入口命令为 `flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml`。
- Flutter 业务层访问后端统一经过 `lib/services/api_client.dart` 的 `_get`，保留取消绑定、请求合并和并发上限，不绕过它直接调用底层 Transport。
- 保持 `rust/testdata/` 中设备池、spade 内容密钥及 CENC 夹具的协议语义；不得为通过测试而改写期望值掩盖回归。
- 选流层必须过滤 `bytevc2`，同画质优先 `h264`；不能解码时返回无可用流，不把不支持的流交给播放器。
- 修改 loopback 时保留 Host / Origin 校验、访问控制与请求体上限；涉及缓存解密和设备池持久化时检查幂等性与并发保护。
- Dart 沿用相对导入、单引号和默认格式；注释解释决策及限制。整理看似重复的资源前先确认各自加载路径。

## 5. APK 构建、安装与本地归档

仅在任务需要 APK 交付或真机验证时执行；普通文档改动不触发此流程。

1. **版本**：用户可见功能变更递增 `pubspec.yaml` 的 `version: <versionName>+<versionCode>`，同步核对 About 页版本展示。仅文档或无行为变化的整理不升版。
2. **Rust 库新鲜度**：检查 `git log --oneline <上一归档提交或标签>..HEAD -- rust/`，同时检查未提交及新增的 Rust 文件。Rust 已改变、`.so` 缺失或无法证明来源时，执行 `scripts/build_rust_backend.ps1` 重建；仅 Dart 改动且库已证实匹配时可复用。Gradle 只检查 `.so` 存在，不会重编 Rust。
3. **原生校验**：重建后运行 `node scripts/check_native_alignment.cjs android/app/src/main/jniLibs/arm64-v8a/libfqapi_core.so android/app/src/main/jniLibs/armeabi-v7a/libfqapi_core.so`。可用 `node scripts/check_so_freshness.cjs <so路径> --since <归档提交或标签>` 辅查提交时间，但时间戳不能证明未提交代码已编入。
4. **打包**：执行 `flutter build apk --release --target-platform android-arm,android-arm64 --split-per-abi --no-pub`，然后对两个产物各运行一次 `python scripts/verify_android_apk.py --apk <APK路径> --abi <arm64-v8a|armeabi-v7a> --build-tools <SDK构建工具目录> --report-dir <报告目录> --expected-signer-sha256 <正式证书SHA256>`。占位符须替换为实际值；正式证书指纹核对 `.github/workflows/android-apk.yml` 与本地签名记录，不输出密码。
5. **安装验收**：在用户已授权的设备上使用 `adb -s <设备序列号> install -r <APK路径>`，核对包名 `com.fqapp.fqapp`、版本和实际画面。点击、滑动或返回前重新确认前台包名；用户切到其他应用时停止输入。以截图 / UI XML 证明页面状态，日志只作辅助；不要为覆盖安装擅自卸载应用或清除数据。
6. **归档**：验收后立即将 APK、`SHA256SUMS` 和实际验证报告保存到 `release-archives/<tag>/`，注明对应提交及未验项。目录名不代表已创建 Git tag 或已发布 Release；不得覆盖已有归档。

构建故障先查本地 CRIT-011 / CRIT-012；签名细节见 `docs/release-signing.md`，完整流程见 `docs/运维/构建与发布.md`。

## 6. Git 与发布边界

- 主分支为 `master`，默认沿用当前工作分支。提交和普通推送按用户授权执行；已授权的操作无需反复确认，不擅自改远端、重写历史或混入其他任务。
- 提交前检查暂存差异，按明确文件路径暂存，避免 `git add .` / `git add -A` 混入本地文件。推送后核对远端提交，不仅凭命令退出码判断成功。
- **推送代码、本地构建、本地归档、GitHub Release 是不同动作。** “上传 gh”在源码语境下按提交 / 推送代码处理，不自动创建 Release、发布 tag 或上传 APK。用户要求“不要发布”时保持该限制，直到明确变更授权。
- 发布 Release、推送发布 tag、上传发布资产及在 issue 中回复或关单，均须有覆盖该动作的明确授权。需要审批时先准备可审阅的产物和说明，再申请；用户已授权时直接完成并核对远端结果。
- 推送前检查 workflow 触发条件；用户要求不跑 CI 时，按需使用提交消息 `[skip ci]`，不手动触发 workflow，不擅自修改 CI 配置规避检查。

## 7. 文件与敏感操作边界

- 日常读写限于仓库和本轮临时目录；已配置的技能、SDK 与工具链可按任务需要读取或调用。其他无关路径不扫描、不改动；超出已授权范围时先说明具体路径和用途。
- 修改签名文件或密码、上游账号操作 / 写请求、force push、覆盖或删除已有归档、恢复已裁撤的账号 / 社交控件，需要针对该动作的明确授权；泛泛的“自行处理”不包含这些操作。
- 签名材料、密码、真实设备 secret key、凭证、个人配置、构建缓存和下载内容永不入库。不得用 `git add -f` 绕过对这些文件及本地研究资料的忽略规则。
- 删除或覆盖文件前核对路径与归属；保留不属于本轮的修改。构建失败不能作为清空工作树、清除手机数据或重置环境的理由。

## 8. 本地资料与续接

公开文件只用纯文本路径提及本地资料，不创建指向未入库文件的 Markdown 链接。

| 本地路径 | 用途 |
| --- | --- |
| `docs/README.md`、`docs/project-structure.md` | 文档导航与代码入口 |
| `docs/架构/项目定位与能力清单.md`、`docs/架构/技术栈.md` | 产品范围和技术选择 |
| `docs/规范/开发约定.md`、`docs/规范/踩坑判据.md` | 细则与 CRIT 判据；验证范围服从本文第 3 节及用户要求 |
| `docs/规范/待办清单.md` | T 编号任务、挂起原因与完成证据 |
| `docs/rust-migration-progress.md`、`docs/real-device-acceptance-checklist.md` | 迁移与真机验收续接点 |
| `docs/validation/`、`.agents/notes/implemented/` | 验证报告与决策笔记 |

新问题按“现象 / 证据 → 影响 → 建议修法 → 发现处”记入清单；机制性问题补充“症状 → 真因 → 判据 → 固化去处”。已有条目优先更新，引用 `T-xxx` / `CRIT-xxx` 编号，不重复铺开历史。非平凡改动把原因、被否方案、代价和验证写入本地笔记。

## 9. 收尾口径

- 复查 `git diff --check` 与工作树，确认只包含本轮预期改动；报告改了什么、验证了什么、还缺什么，涉及提交 / 推送 / 安装 / 发布时分别说明实际状态。
- diff 为空只代表所选比较范围没有变化，不能称为全库审计通过。既有未跟踪文件不自动纳入审查或提交范围。
- 构建成功、静态检查通过、真机功能通过分别表述；未执行检查明确写“未执行”，不沿用旧版本结果冒充本轮验证。
- 更新相关本地清单和续接记录后结束本轮；后续建议保持为建议，等待用户选择，不自行开启下一批开发或发布。
