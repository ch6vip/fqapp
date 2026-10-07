# AGENTS.md — fqapp 项目指南

本文件是任何自动化代理（agent）在本仓库工作的本地法律：一页纸说清工作方式。
面向 AI 编码代理的**索引页**：本文件只存条目与一句话结论，细节在 `docs/` 按主题成页。
约定详情以本文件引用的文档为准；本文件与它们冲突时，以被引用文档为准并提请修正本文件。
注意 `.agents/` 与 `docs/` 均在 gitignore 中（本地留存，不随仓库分发、不上传 GitHub；其中的逆向研究记录尤其不得外发）。公开文件提及 `docs/` 路径时均采用纯文本路径提及，不写链接，免得公开仓库出现死链。文档地图见本地 `docs/README.md`。

## 1. 项目定位
- 一句话：番茄内容聚合 Android 客户端，Flutter UI + 进程内 Rust 原生核心 `fqapi_core`（flutter_rust_bridge 直调，另开 `127.0.0.1:8080` loopback 服务 Web UI 与漫画图）。无独立后端进程，不需要 root。
- 明确不做：无需登录与账号写操作（短剧追剧/点赞/分享等社交入口已裁撤，不计为待办）；不发布独立后端可执行文件（受 Android SELinux 限制）；无写接口时不放假 UI 控件。
- 详情：本地 `docs/架构/项目定位与能力清单.md`。

## 2. 技术栈
- 前端：Flutter 3.44.6 (stable) / Dart 3.12+。
- 核心：Rust stable (`fqapi_core` crate)，flutter_rust_bridge **钉死 2.13.0**。
- 流式解密：原生 C CENC MP4 解密库（CMake 自动编译 `libshortplay_crypto.so`，16 KiB ELF 对齐）。
- 平台与环境：Android SDK 36, NDK 28.2.13676358, JDK 17, Gradle 9.1.0（单目标 ABI：`arm64-v8a`）。
- 状态存储：Hive (`LibraryStore`) 与 SharedPreferences。
- 详情与选型理由：本地 `docs/架构/技术栈.md`。

## 3. 构建、测试与门禁（锚点 A4/A5）
- **按改动面取交集，全部通过才算完成**（命令不可并行，测试必须串行跑）：
  - **Rust（`rust/`）**：手写 `.rs` 逐文件 `rustfmt --check --edition 2021 --config skip_children=true` + `cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings` + `cargo test --manifest-path rust/Cargo.toml --locked`。
  - **Flutter / Dart（`lib/`、`test/`）**：`flutter analyze --no-pub` + `flutter test --no-pub --concurrency=2`（全量，不是只跑相关文件）。
  - **FRB 绑定**：绑定改动必须跑 codegen 并确认可复现（内容哈希一致）；crate/Dart 包/codegen 版本钉死 2.13.0。
  - **APK 交付**：`flutter build apk --release --target-platform android-arm64 --no-pub` + `python scripts/verify_android_apk.py`（签名与 16 KiB 对齐）。
- **门禁避坑与原因（A5）**：
  - Rust 格式门禁不要用 `cargo fmt --all -- --check`（会误入 `frb_generated.rs` 导致常红），也不要只改根文件 `skip_children=true`（漏检手写模块）；CI 与本地一致枚举 git 跟踪的手写 `.rs` 逐个检查。
  - 门禁不可并行的原因：`127.0.0.1:8080` 端口独占、Cargo target 目录与 Gradle 编译锁、FRB 宿主动态库运行时文件锁。
  - 已知环境噪音不作为回归依据：`static_and_loopback` 中 6 项符号链接用例需要 Windows 开发者模式权限。
- 详情：本地 `docs/规范/开发约定.md`。

## 4. 目录结构与模块边界（锚点 A6）
- 分层职责：`lib/`（UI/服务/模型/已提交绑定）、`rust/`（核心实现/协议夹具）、`native/`（C 流式解密）、`android/`（平台打包与 JVM 测试）、`scripts/`（构建验证脚本）。代码阅读入口见本地 `docs/project-structure.md`。
- 接缝与不变量：
  - `rust/src/frb_generated.rs` 与 `lib/src/rust/` 只能通过 codegen 生成，不可手改。
  - 主分支为 `master`；改动直接在分支上提交，完成后推送。
  - `docs/` 与 `.agents/` 仅在本地留存（`.gitignore`），绝对不提交逆向和反编译分析资料。

## 5. 运行与部署（Android APK 交付与安装，锚点 A7/A8）
- APK 构建：先跑 `scripts/build_rust_backend.ps1` 生成 ARM64 Rust 核心，再执行 `flutter build apk --release --target-platform android-arm64 --no-pub`。
- **`.so` 重建判据（CRIT-011）**：上面那条"先跑 build_rust_backend"**不是无条件的第一步**，而取决于改动面。Gradle 只在打包期检查 `jniLibs/arm64-v8a/libfqapi_core.so` **是否存在**，不会重编，而该目录已入 `.gitignore`——所以打版前必须跑 `git log --oneline <上一版归档点>..HEAD -- rust/`：**输出非空就必须重建 `.so`**，否则产出的 APK 会静默缺失最近的 Rust 修复（门禁全绿也拦不住，实例：`v1.0.88` 补发时的 `3187bfb`）。重建后立即用 `node scripts/check_native_alignment.cjs …/libfqapi_core.so` 确认 `0x4000` 对齐。构造/Rust 侧的脚本陷阱见本地 `docs/规范/踩坑判据.md` 的 CRIT-011 / CRIT-012。
- 版本号递增：用户可见功能变更必须递增 `pubspec.yaml` 的 version 与 versionCode。
- 归档纪律：验收后**立即**归档（APK + SHA256SUMS + 验证报告）到 `release-archives/<tag>/`，不许攒批；该目录已入 `.gitignore`、只落本地磁盘。断档实例：`v1.0.82` 之后到 `v1.0.86` 都没有归档包，那几版已无法回滚。
- 签名与安装：签名要求见本地 `docs/release-signing.md`；覆盖安装使用 `adb install -r <apk>`。详情见本地 `docs/运维/构建与发布.md`。

## 6. 清单与经验机制（锚点 A2/A3）
- **开工三查**：扫 A3 判据页、查基线工作树、查 A2 清单分类。
- 遇到错误**先查经验再想方案**：扫本地 `docs/规范/踩坑判据.md`（标题即结论，按症状关键词搜），未命中才开始推导。
- 问题与待办记在本地 `docs/规范/待办清单.md`（条目格式：现象/证据 → 影响 → 建议修法 → 发现处）；**不随手改代码、不只在脑子里记**。
- 机制性会复发的坑按四段格式（症状 → 真因 → 判据 → 固化去处）补进判据页；判据被机器测试固化后删行（退出机制）。
- 跨会话续接点：本地 `docs/rust-migration-progress.md`（迁移断点与未验项）、`docs/real-device-acceptance-checklist.md`（真机验收清单）。两者均不入库。
- 长任务循环驱动完整流程详见本地 `docs/规范/长任务提示词-待办清单循环.md`。

## 7. 授权边界（锚点 A7）
- **必须停下来等人的动作（即便用户说过「不用问我」也要单独确认）**：
  - 修改或替换 release keystore 签名文件及密码；
  - 向番茄上游发起账号操作或写入请求（登录、评论、关注、点赞等）；
  - 远端 force push 改写 Git 历史；
  - 覆盖或删除 `release-archives/` 中已归档的发布包；
  - 恢复已裁撤的社交/账号相关控件；
  - 目录白名单之外的路径读写。
- **敏感件纪律**：签名材料、keystore 密码、真实设备 secret key、凭证、个人配置、构建缓存、下载视频永不入库。
- **自治域**：代码、测试、本地文档、本地临时环境。细节不确定时按最优解执行，但把选择与代价写进条目/报告。

## 8. 文档与知识库分工
- 三层分工：
  - **本文件（`AGENTS.md`）**：代码仓库根目录索引页，存条目与一句话结论（入库）。
  - **本地文档（`docs/`）**：现状性详解、架构、规范三件套（开发约定/踩坑判据/待办清单）、验证报告（本地留存不入库）。
  - **本地笔记（`.agents/notes/`）**：非平凡改动在收尾时写笔记到 `.agents/notes/implemented/<architecture|bug-fix|feature|simplification>/YYYY-MM-DD-<slug>.md`（为什么做、放弃了什么方案、踩了什么坑、怎么验证的；本地留存不入库）。
- 验收用语纪律：未执行的检查一律写“未执行”，绝不写成通过；离线可做的验证与真机/在线验证分开列，不混为一谈；构建成功不代表功能验收通过。
- 引用条目写编号（如 `T-001`、`CRIT-001`），不复制链接、不复述结论。
- 编码风格：相对导入、单引号、Dart 默认风格；注释记录决策与坑（为什么这么写），不复述代码在做什么。

## 9. 已知取舍与不变量（破坏即回归）
- **网络唯一漏斗**：`lib/services/api_client.dart` 的 `_get` 是所有后端请求的唯一漏斗（取消绑定、请求合并、并发上限都在这里）。
- **离线黄金夹具**：设备池、spade 内容密钥、CENC 样本解密有离线测试夹具（`rust/testdata/`），改动协议实现必须保持夹具通过。
- **选流编码门**：bytevc2 变体必须在选流层被丢弃，宁可返回空也不给解不动的流；h264 同画质优先。
