# App 配套后端源码与依赖补丁

原 `app-compat.patch` 已退休。当前构建仅应用
[`x-text-security.patch`](x-text-security.patch)，将 `golang.org/x/text` 从 `v0.3.8`
升级到 `v0.39.0`，修复 [GO-2026-5970](https://pkg.go.dev/vuln/GO-2026-5970)。
该补丁只修改 `go.mod` / `go.sum`，不改后端业务源码。工作流同时核对源码提交、
运行只读依赖模式的 Go 测试与漏洞扫描，并记录补丁 SHA-256。

## 现在怎么取后端源码

[`android-apk.yml`](../../.github/workflows/android-apk.yml) 中的 `LEGACY_COMMIT`
是当前源码提交的唯一来源。不要从旧文档复制 `f667122`：它缺少后续音频内容密钥派生修复，
会使当前客户端收到缺少 `key_hex` 的加密音频。历史兼容改动的提交关系为：

```
b2379115307295651e2e7b09c7ea74e438aa4b46   (ch6vip/ 分支 fqapp-android)
b237911 → ... → f667122 → ...               (后续提交以 LEGACY_COMMIT 为准)
```

在 App 根目录执行以下 PowerShell 命令，首次创建独立构建克隆，保留已有 `../`
工作树。`../-app-build` 已存在时，应检查其提交和补丁状态后复用，或换一个新目录。
这里使用带 `.git` 目录的克隆：Go 1.26.7 的版本探测不识别 worktree 的 `.git` 文件，
嵌在 App 目录内构建时可能把后端版本误记为外层 App 的提交。

```powershell
$pinLine = Select-String -Path .github/workflows/android-apk.yml -Pattern "^\s*LEGACY_COMMIT: '([0-9a-f]{40})'$"
$Commit = $pinLine.Matches.Groups[1].Value
if (-not $Commit) { throw 'LEGACY_COMMIT is missing or invalid' }
$securityPatch = (Resolve-Path patches//x-text-security.patch).Path
git -C ../ fetch origin
if ($LASTEXITCODE -ne 0) { throw 'Backend fetch failed' }
git clone --no-hardlinks --no-checkout ../ ../-app-build
if ($LASTEXITCODE -ne 0) { throw 'Backend clone failed' }
git -C ../-app-build checkout --detach $Commit
if ($LASTEXITCODE -ne 0) { throw 'Pinned backend checkout failed' }
git -C ../-app-build apply --check $securityPatch
if ($LASTEXITCODE -ne 0) { throw 'Security patch does not match the pinned source' }
git -C ../-app-build apply $securityPatch
if ($LASTEXITCODE -ne 0) { throw 'Security patch failed' }
Push-Location ../-app-build
try {
    go test -mod=readonly -count=1 ./...
    if ($LASTEXITCODE -ne 0) { throw 'Backend tests failed' }
    go run golang.org/x/vuln/cmd/govulncheck@v1.8.0 ./...
    if ($LASTEXITCODE -ne 0) { throw 'Backend vulnerability scan failed' }
} finally { Pop-Location }
.\scripts\build_backend.ps1 -Jni ../-app-build
```

Linux / macOS / Git Bash 对应的首次准备命令如下，仍从 App 根目录执行：

```bash
set -euo pipefail
_commit="$(tr -d '\r' < .github/workflows/android-apk.yml | sed -n "s/^  LEGACY_COMMIT: '\([0-9a-f]\{40\}\)'$/\1/p")"
[[ "$_commit" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid LEGACY_COMMIT' >&2; exit 1; }
security_patch="$(pwd)/patches//x-text-security.patch"
git -C ../ fetch origin
git clone --no-hardlinks --no-checkout ../ ../-app-build
git -C ../-app-build checkout --detach "$_commit"
git -C ../-app-build apply --check "$security_patch"
git -C ../-app-build apply "$security_patch"
(
  cd ../-app-build
  go test -mod=readonly -count=1 ./...
  go run golang.org/x/vuln/cmd/govulncheck@v1.8.0 ./...
)
bash scripts/build_backend.sh --jni ../-app-build
```

升级后端固定提交时，先在干净克隆中执行 `git apply --check`。如果新提交已经升级该依赖，
应同时移除安全补丁、CI 应用步骤与此处说明，不能静默忽略补丁失败。

决策与验证见[本轮审查记录](../../.agents/notes/implemented/bug-fix/2026-09-16-cross-review-boundaries.md)。

## 为什么曾经有应用兼容补丁

`` 是私有仓库，App 需要三项后端改动才能完整工作，但这些改动在 App 侧先于
后端仓库落地。旧流程因此把改动存成 `app-compat.patch`，CI 在一个冻结的基础提交
`4048110` 上应用它再构建。

补丁承载三项改动及其测试：

- 小说正文从 JSON `data.content` 解密，仅成功后返回 `content_decrypted=true`，
  兼容旧密文响应头。
- 短剧目录按列表位置显示“第1集…第N集”，与客户端播放及历史索引一致。
- 章评／段评走 item-ideas 服务，并修好恒返回 400 的
  `/api/v1/chapters/{id}/paragraphs/{n}/reviews` 路由；评论列表端点补上
  `group_id`/`group_type`/`comment_source`/`comment_type`/`server_channel`/
  `para_index`/`item_version`/`insert_comment_ids`，默认值与原书评请求逐字段一致。
- 短剧系列详情（演员表）走播放器域的 `/novel/player/video_detail/v1/`，
  暴露为 `/api/v1/series/{id}`；`biz_param.video_id_type` 必须为 1，且不传
  `video_platform`。

## 退休做了什么

1. 把补丁内容提交到 ``（分支 `fqapp-android`），得提交 `b237911`。
2. 逐文件比对「旧基础 `4048110` + 补丁」与「`b237911`」的 blob：9 个文件全部一致，
   证明退休没有丢失任何改动。
3. 在新提交上**不打补丁**直接跑 `go test -mod=readonly -count=1 ./...`：全绿。
4. 更新 `LEGACY_COMMIT` 为 `b237911`，删除补丁文件、`git apply` 步骤、
   `patches//**` 路径触发，以及构建报告里的补丁 SHA 行。

## 如果将来又需要应用兼容补丁

只有在后端改动无法及时进入 `` 历史时才这样做，并且要记住补丁会带来持续的
维护成本：补丁越长越难应用，而每个 App 特性都可能继续加长它。

- **生成补丁时必须按文件列举，不要用整仓 `git diff`**。本地可能存在不属于补丁的
  改动，历史上 `internal/endpoints/full.go` 就只出现过行尾差异。
- 在固定基础提交的临时 worktree 中应用并跑完整 Go 测试，再更新 `LEGACY_COMMIT`。
- 不能把补丁冲突当作可忽略错误。

相关决策见
[小说插图 Agent Note](../../.agents/notes/implemented/bug-fix/2026-09-10-reader-illustrations.md)
与[章评端点 Agent Note](../../.agents/notes/implemented/feature/2026-09-10-chapter-ideas-endpoint.md)。
