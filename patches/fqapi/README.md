# App 配套后端补丁

可复现的后端源码由 `.github/workflows/android-apk.yml` 中固定的基础提交
`40481102257f9405c8086c614b50796873091a4e` 和 `app-compat.patch` 共同组成。
补丁不包含运行时配置、设备池或二进制。

补丁包含三项 App 配套改动及其测试：

- 小说正文从 JSON `data.content` 解密，兼容旧密文响应头，仅成功后返回
  `content_decrypted=true`；合成 DH/AES 用例覆盖图文 HTML、错误密文和非法 UTF-8。
- 短剧目录按列表位置显示“第1集…第N集”，与客户端播放及历史索引一致。
- 章评／段评改为走真正的 item-ideas 服务（`/novel/commentapi/idea/list/`），
  并修好恒返回 400 的 `/api/v1/chapters/{id}/paragraphs/{n}/reviews` 路由。
  同时给评论列表端点补上官方段评配方所需的参数（`group_id`/`group_type`/
  `comment_source`/`comment_type`/`server_channel`/`para_index`/`item_version`），
  默认值与原书评请求逐字段一致。

## 章评／段评为什么不能复用书评端点

书评走 `POST /novel/commentapi/comment/list/{book_id}/v1`，章评与段评走
`POST /novel/commentapi/idea/list/{item_id}/v1`。两者是不同的服务：

- 书评端点把 `comment_type` 锁死在 2（Book）。传 item／paragraph 类型时上游返回
  `103001 invalid param`，`debug_info` 为 `comment_type invalid`；把 `group_id`
  指向章节 forum 也只能得到 `total=0`。
- 段评列表仍然用书评端点，但要用官方客户端配方：`comment_source=2`
  （NovelParaComment）、`comment_type=1`（Paragraph）、`group_type=15`
  （UgcRelativeType.Item）、`server_channel=43`（NovelParaUserCommentList），
  `group_id` 为**章节 ID**，`business_param` 同时需要真实 `book_id`、`para_index`
  与 `item_version`。三者缺一，上游即返回
  `103001 book_id, item_version, or para_index invalid`。
  `item_version` 取自目录接口 `data.item_data_list[i].version`。
- `idea/list` 返回按段号索引的数量与评论 ID（`infos` 只带 `comment_id`），
  不含评论正文；正文需再用上面的配方向评论列表端点取。

CI 在干净的固定提交上先执行 `git apply --check`，再应用补丁并运行完整 Go 测试，
然后构建 JNI 库。构建报告同时记录基础提交与补丁 SHA-256，避免 Flutter 更新后
仍打包旧解密逻辑。

本地已有这些修改时不要重复应用。检查已应用状态（在 App 根目录执行）：

```powershell
git -C ../ apply --reverse --check "$((Get-Location).Path)/patches//app-compat.patch"
```

从干净基础提交重建时，先检查和应用补丁，然后正常构建：

```powershell
git -C ../ apply --check "$((Get-Location).Path)/patches//app-compat.patch"
git -C ../ apply "$((Get-Location).Path)/patches//app-compat.patch"
.\scripts\build_backend.ps1 -Jni
```

后端仓库发布包含全部这些改动的提交后，将 CI 固定到该真实提交，并在同一批改动中
删除已被包含的补丁和应用步骤。更新基础提交前必须验证补丁及接口测试；不能将补丁
冲突当作可忽略错误。

补丁只覆盖 9 个文件。**生成补丁时必须按文件列举，不要用整仓 `git diff`**：
本地 `internal/endpoints/full.go` 等改动不属于补丁，README 早先已说明
「本地其它未提交的后端改动不进入云端构建」。验证方式是在固定基础提交的
临时 worktree 中应用补丁并运行 `go test -mod=readonly -count=1 ./...`。

决定与验证依据见
[小说插图 Agent Note](../../.agents/notes/implemented/bug-fix/2026-09-10-reader-illustrations.md)
与[章评端点 Agent Note](../../.agents/notes/implemented/feature/2026-09-10-chapter-ideas-endpoint.md)。
