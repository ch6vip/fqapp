# AGENTS.md — fqapp 开发约定

本文件是任何自动化代理（agent）在本仓库工作的本地法律：一页纸说清工作方式。
约定详情以本文件引用的文档为准；本文件与它们冲突时，以被引用文档为准并提请修正本文件。

## 项目一句话

番茄内容聚合 Android 客户端：Flutter UI + 进程内 Rust 原生核心 `fqapi_core`
（flutter_rust_bridge 直调，另开 `127.0.0.1:8080` loopback 服务 Web UI 与漫画图）。
无独立后端进程，不需要 root。

目录职责与代码阅读入口见本地 `docs/project-structure.md`，文档分类与历史报告见
`docs/README.md`。这两份只在本地检出时存在（`docs/` 不入库），因此这里用纯文本
提及而不是链接：公开仓库上的访客点不到它们。

## 改代码必过的验证门

按改动面取交集，全部通过才算完成：

| 改动面 | 验证门 |
| --- | --- |
| Rust（`rust/`） | rustfmt 逐文件检查（见下）、`cargo clippy --all-targets -- -D warnings`、`cargo test --locked` |
| Flutter / Dart（`lib/`、`test/`） | `flutter analyze --no-pub`、`flutter test --no-pub --concurrency=2`（全量，不是只跑相关文件） |
| APK 交付 | `flutter build apk --release --target-platform android-arm64 --no-pub` + `python scripts/verify_android_apk.py`（签名与 16 KiB 对齐） |
| FRB 绑定 | 绑定改动必须跑 codegen 并确认可复现（内容哈希）；crate/Dart 包/codegen 版本钉死 2.13.0 |

Rust 格式门禁不要用 `cargo fmt --all -- --check`：rustfmt 会沿 `mod` 声明进入生成文件
`frb_generated.rs`，而 codegen 产物过不了 rustfmt，于是干净树也必然失败，CI 常红。
也不要图省事改成 `rustfmt --config skip_children=true rust/src/lib.rs`——那样只检查
根文件，手写模块的格式问题会被静默放过。CI 的做法是枚举 git 跟踪的手写 `.rs`、
逐个 `rustfmt --check --config skip_children=true`（见 `.github/workflows/android-apk.yml`），
既排除生成文件又保持门禁有效。生成文件的正确性由上面的内容哈希步骤保证。

已知环境噪音，不作为回归依据：`static_and_loopback` 中 6 项符号链接用例需要
Windows 开发者模式权限。

## 笔记约定

非平凡改动（技术选型、架构、非直觉缺陷复盘、裁撤决策）在收尾时写笔记到
`.agents/notes/implemented/<architecture|bug-fix|feature|simplification>/YYYY-MM-DD-<slug>.md`：
为什么做、放弃了什么方案、踩了什么坑、怎么验证的。失败路径与被否方案和成功路径同等重要。
注意 `.agents/` 与 `docs/` 均在 gitignore 中（本地知识，不随仓库分发、不上传 GitHub）；
用户可见的验证与结论写 `docs/`（仅本地留存，其中的逆向研究记录尤其不得外发）。
本文件与 README 中提到的 `docs/` 路径在 GitHub 上都不存在，属于有意为之：写成纯文本
提及而不是链接，免得公开仓库出现一堆点不开的死链。

## 验收用语纪律

- 未执行的检查一律写"未执行"，绝不写成通过；离线可做的验证与需要真机/在线的验证分开列，不混为一谈。
- 构建成功不代表功能验收通过；测试通过只覆盖测试写到的范围。
- 跨会话续接点：本地 `docs/rust-migration-progress.md`（迁移断点与未验项）、
  `docs/real-device-acceptance-checklist.md`（真机验收清单）。两者均不入库。

## 其他约定

- 版本号：用户可见功能变更递增 `pubspec.yaml` 的 version 与 versionCode；验收满意后归档
  （APK + SHA256SUMS + 验证报告）到 `release-archives/<tag>/`，签名要求见本地
  `docs/release-signing.md`（不入库）。
- 不提交密钥、个人配置、构建缓存、下载的视频。签名文件与 keystore 永不入库。
- 相对导入、单引号、Dart 默认风格；注释记录决策与坑（为什么这么写），不复述代码在做什么。
- 主分支为 `master`；改动直接在分支上提交，完成后推送。

## 已知不变量（破坏即回归）

- `lib/services/api_client.dart` 的 `_get` 是所有后端请求的唯一漏斗（取消绑定、请求合并、并发上限都在这里）。
- 设备池、spade 内容密钥、CENC 样本解密有离线测试夹具（`rust/testdata/`），改动协议实现必须保持夹具通过。
- 选流编码门：bytevc2 变体必须被丢弃，宁可返回空也不给解不动的流；h264 同画质优先。
