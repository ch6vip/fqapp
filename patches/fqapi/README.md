# App 配套后端改动（补丁已退休）

**状态：补丁已退休，本目录不再参与构建。** 这里只保留决策记录。

## 现在怎么取后端源码

`.github/workflows/android-apk.yml` 中的 `LEGACY_COMMIT` 直接固定一个**真实提交**，
检出后原样使用，不再打任何补丁：

```
b2379115307295651e2e7b09c7ea74e438aa4b46   (ch6vip/ 分支 fqapp-android)
```

本地重建同样从该提交构建：

```powershell
git -C ../ fetch origin
git -C ../ checkout b2379115307295651e2e7b09c7ea74e438aa4b46
.\scripts\build_backend.ps1 -Jni
```

## 为什么曾经有补丁

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

## 退休做了什么

1. 把补丁内容提交到 ``（分支 `fqapp-android`），得提交 `b237911`。
2. 逐文件比对「旧基础 `4048110` + 补丁」与「`b237911`」的 blob：9 个文件全部一致，
   证明退休没有丢失任何改动。
3. 在新提交上**不打补丁**直接跑 `go test -mod=readonly -count=1 ./...`：全绿。
4. 更新 `LEGACY_COMMIT` 为 `b237911`，删除补丁文件、`git apply` 步骤、
   `patches//**` 路径触发，以及构建报告里的补丁 SHA 行。

## 如果将来又需要补丁

只有在后端改动无法及时进入 `` 历史时才这样做，并且要记住补丁会带来持续的
维护成本：补丁越长越难应用，而每个 App 特性都可能继续加长它。

- **生成补丁时必须按文件列举，不要用整仓 `git diff`**。本地可能存在不属于补丁的
  改动，历史上 `internal/endpoints/full.go` 就只出现过行尾差异。
- 在固定基础提交的临时 worktree 中应用并跑完整 Go 测试，再更新 `LEGACY_COMMIT`。
- 不能把补丁冲突当作可忽略错误。

相关决策见
[小说插图 Agent Note](../../.agents/notes/implemented/bug-fix/2026-09-10-reader-illustrations.md)
与[章评端点 Agent Note](../../.agents/notes/implemented/feature/2026-09-10-chapter-ideas-endpoint.md)。
