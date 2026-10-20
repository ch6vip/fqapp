# 参与 fqapp

感谢你愿意花时间改进这个项目。本文说明**提交问题**和**提交代码**两条路径，以及本项目在质量上的硬性要求。

构建环境、架构说明、API 对接、调试技巧不在这里，见 [DEVELOPMENT.md](DEVELOPMENT.md)。

---

## 一、提交问题

### 先确认是不是已知情况

动手开 issue 前请依次确认：

1. **更新到最新版本**。部分"功能缺失"其实是旧版本没有——项目迭代较快，反馈前请先看 [Releases](https://github.com/ch6vip/fqapp/releases/latest) 的最新包。
2. **在已有 issue 里搜一下**。同一个问题被拆成多条会让处理变慢。
3. **确认是本项目的问题**。上游接口本身返回异常（比如某本书目录为空）不是客户端能修的，但值得记录。

### 报告缺陷时请给出

- 应用版本号（设置 → 关于，形如 `1.0.123`）
- 设备型号与系统版本（如 Redmi K60 Ultra / Android 15）
- 复现步骤：从哪个页面进入、点了什么、期望看到什么、实际看到什么
- 截图或录屏。**一张截图胜过一段描述**，界面问题尤其如此
- 如果能拿到，应用内日志更有帮助（见「调试信息」）

### 提功能建议时请说明

- **你现在怎么做这件事**，以及**哪里不方便**
- 你希望的结果，而不是具体实现方案——实现方式留给维护者权衡

功能建议请注意本项目的产品边界（见第二节）。**建议被拒绝不等于不重视你的意见**，有些能力受上游接口限制无法实现，有些是刻意的设计取舍。

---

## 二、产品边界

这些是明确的范围决定，不因 issue 数量改变。提建议前请先看：

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| 登录 / 账号 | **不做** | 本项目不持有账号，避免把用户凭据带进第三方客户端 |
| 追剧 / 点赞 / 分享 | **已裁撤** | 产品范围收敛后移除，不作为待办恢复 |
| 云同步 | **不做** | 没有可用的上游端点，本地数据不出设备 |
| 上游数据写入 | **不做** | 只读消费公开内容，不回写账号 |
| 客户端"解锁"类功能 | **不做** | 不绕过上游的付费与权限控制 |

反过来，以下方向是欢迎的：阅读体验、播放器、缓存与离线、本地书架组织、无障碍与墨水屏适配、性能与耗电。

不确定你的想法是否在范围内？先开 issue 问一句，比写完代码被拒要好。

---

## 三、提交代码

### 分支与提交

本项目是单人维护，**默认直接在 `master` 上迭代**，不强制走 PR。你提交 PR 也会被正常审阅和合并，但请理解：

- 维护者可能直接在你的分支基础上改动，而不是逐行 review 后要求你返工
- 小改动（错别字、一行修复）直接说明即可，不必纠结流程

提交信息格式：

```
<type>(<scope>): <summary> (#issue)
```

- `type`：`feat` / `fix` / `perf` / `refactor` / `docs` / `chore` / `test`
- `scope`：受影响模块，如 `search`、`reader`、`player`、`android`、`rust`
- 关联 issue 时在末尾带 `(#123)`

示例：

```
feat(search): persist the rating threshold and show the work length (#90)
fix(reader): keep immersive mode when the ideas sheet closes (#57)
```

### 提交前必须通过

```bash
flutter analyze --no-pub
flutter test
```

两者都必须干净。**只跑定向测试不算通过**，涉及共享代码时要跑全量。

改到 `rust/` 时另需：

```bash
cargo test --manifest-path rust/Cargo.toml --locked
cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings
```

仓库已封装了 Dart → Rust 的宿主端集成测试，它会自己起 mock 上游，不碰真机也不打真实上游：

```bash
# Windows PowerShell
.\scripts\run_rust_host_tests.ps1
# macOS / Linux
./scripts/run_rust_host_tests.sh
```

格式检查用 `rustfmt --check --edition 2021 --config skip_children=true <文件>`，逐文件枚举 Git 跟踪的手写 `.rs`，**排除 `frb_generated.rs`**。不要用 `cargo fmt --all -- --check` 代替。

### 不要手改生成代码

以下文件由 codegen 生成，手改会在下次生成时被覆盖：

- `rust/src/frb_generated.rs`
- `lib/src/rust/`

改动绑定接口时执行：

```bash
flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml
```

`flutter_rust_bridge` 的 Rust crate、Dart 包与 codegen **统一固定 2.13.0**，不要单独升级其中一个。

### 改 UI 时

- 跟随现有页面的视觉语言，不引入新的设计体系
- 墨水屏模式（设置 → 外观）会退化配色，新增元素请确认在该模式下仍可读
- 窄屏与大字号要能用，不要写死宽度
- 有交互的控件请带 `Key`，测试需要锚点

### 改协议解析时

`rust/testdata/` 与 `test/fixtures/` 里的样本承载协议语义。**不要为了让测试通过而修改期望值**——如果上游真的变了，请在 PR 里说明依据（抓包、版本号、时间）。

---

## 四、调试信息

应用内日志写入应用私有目录。连接设备后可取出：

```bash
adb shell run-as com.fqapp.fqapp ls files/logs
adb shell run-as com.fqapp.fqapp cat files/logs/<文件名>
```

正式包不可 `run-as` 时，用界面截图 + 版本号 + 复现步骤描述即可，不必卡在日志上。

---

## 五、许可

提交代码即表示你同意你的贡献以本项目的许可证发布。详见 [README.md](README.md) 的「许可与免责声明」。

本项目是第三方客户端，与内容提供方无隶属关系。请勿提交用于绕过上游付费、权限或风控的代码。
