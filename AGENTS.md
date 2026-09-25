# AGENTS.md — fqapp 开发约定

本文件是任何自动化代理（agent）在本仓库工作的本地法律：一页纸说清工作方式。
约定详情以本文件引用的文档为准；本文件与它们冲突时，以被引用文档为准并提请修正本文件。

## 项目一句话

番茄内容聚合 Android 客户端：Flutter UI + 进程内 Rust 原生核心 `fqapi_core`
（flutter_rust_bridge 直调，另开 `127.0.0.1:8080` loopback 服务 Web UI 与漫画图）。
无独立后端进程，结构精简，不需要 root。

## 改代码必过的验证门

按改动面取交集，全部通过才算完成：

| 改动面 | 验证门 |
| --- | --- |
| Rust（`rust/`） | `cargo fmt --check`、`cargo clippy --all-targets -- -D warnings`、`cargo test --locked` |
| Flutter / Dart（`lib/`、`test/`） | `flutter analyze --no-pub`、`flutter test --no-pub --concurrency=2`（全量，不是只跑相关文件） |
| APK 交付 | `flutter build apk --release --target-platform android-arm64 --no-pub` + `python scripts/verify_android_apk.py`（签名与 16 KiB 对齐） |
| FRB 绑定 | 绑定改动必须跑 codegen 并确认可复现（内容哈希）；crate/Dart 包/codegen 版本钉死 2.13.0 |

已知环境噪音，不作为回归依据：`cargo fmt --check` 对生成文件 `frb_generated.rs` 的格式漂移（勿手改生成文件）；
`static_and_loopback` 中 6 项符号链接用例需要 Windows 开发者模式权限。

## 笔记约定

非平凡改动（技术选型、架构、非直觉缺陷复盘、裁撤决策）在收尾时写笔记到
`.agents/notes/implemented/<architecture|bug-fix|feature|simplification>/YYYY-MM-DD-<slug>.md`：
为什么做、放弃了什么方案、踩了什么坑、怎么验证的。失败路径与被否方案和成功路径同等重要。
注意 `.agents/` 在 gitignore 中（本地知识，不随仓库分发）；用户可见的验证与结论写 `docs/`。

## 验收用语纪律

- 未执行的检查一律写"未执行"，绝不写成通过；离线可做的验证与需要真机/在线的验证分开列，不混为一谈。
- 构建成功不代表功能验收通过；测试通过只覆盖测试写到的范围。
- 跨会话续接点：[`docs/rust-migration-progress.md`](docs/rust-migration-progress.md)（迁移断点与未验项）、
  [`docs/real-device-acceptance-checklist.md`](docs/real-device-acceptance-checklist.md)（真机验收清单）。

## 其他约定

- 版本号：用户可见功能变更递增 `pubspec.yaml` 的 version 与 versionCode；验收满意后归档
  （APK + SHA256SUMS + 验证报告）到 `release-archives/<tag>/`，签名要求见
  [`docs/release-signing.md`](docs/release-signing.md)。
- 不提交密钥、个人配置、构建缓存、下载的视频。签名文件与 keystore 永不入库。
- 相对导入、单引号、Dart 默认风格；注释记录决策与坑（为什么这么写），不复述代码在做什么。
- 主分支为 `master`；改动直接在分支上提交，完成后推送。

## 已知不变量（破坏即回归）

- `lib/services/api_client.dart` 的 `_get` 是所有后端请求的唯一漏斗（取消绑定、请求合并、并发上限都在这里）。
- 设备池、spade 内容密钥、CENC 样本解密有离线测试夹具（`rust/testdata/`），改动协议实现必须保持夹具通过。
- 选流编码门：bytevc2 变体必须被丢弃，宁可返回空也不给解不动的流；h264 同画质优先。
