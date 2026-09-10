# App 配套后端补丁

可复现的后端源码由 `.github/workflows/android-apk.yml` 中固定的基础提交
`40481102257f9405c8086c614b50796873091a4e` 和 `app-compat.patch` 共同组成。
补丁不包含运行时配置、设备池或二进制。

补丁包含两项已有的 App 配套改动及其测试：

- 小说正文从 JSON `data.content` 解密，兼容旧密文响应头，仅成功后返回
  `content_decrypted=true`；合成 DH/AES 用例覆盖图文 HTML、错误密文和非法 UTF-8。
- 短剧目录按列表位置显示“第1集…第N集”，与客户端播放及历史索引一致。

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
冲突当作可忽略错误。决定与验证依据见
[小说插图 Agent Note](../../.agents/notes/implemented/bug-fix/2026-09-10-reader-illustrations.md)。
