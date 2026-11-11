<p align="center">
  <img src="assets/images/app_logo.webp" width="120" alt="什锦铺">
</p>

<h1 align="center">什锦铺</h1>

<p align="center">
  <strong>让阅读和追剧，简单一点。</strong><br>
  小说 · 听书 · 短剧 · 漫剧 · 漫画
</p>

<p align="center">
  <a href="https://github.com/ch6vip/novel-sound/releases/latest"><img src="https://img.shields.io/github/v/release/ch6vip/novel-sound?label=Release&color=E89B35" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/Android%20%7C%20Windows-087E8B" alt="支持 Android 和 Windows">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-blue" alt="GPL-3.0 开源协议"></a>
</p>

<p align="center">
  <a href="#主要功能">主要功能</a> ·
  <a href="#下载与安装">下载安装</a> ·
  <a href="#常见问题">常见问题</a> ·
  <a href="DEVELOPMENT.md">开发文档</a>
</p>

---

什锦铺是一款支持 **安卓和 Windows** 的开源阅读与影音应用。在线看故事，也能导入自己的电子书，把喜欢的作品和进度留在书架里。

## 主要功能

### 📖 看小说，听故事

- 在线阅读小说，也能导入 TXT / EPUB 电子书。
- 字体、字号、翻页方式随心调，支持深色、纯黑和墨水屏模式。
- 支持系统朗读和真人有声书，可调倍速、定时停止、后台播放。

### 🎬 追短剧，看漫画

- 短剧、漫剧、漫画集中浏览，按作品名称或编号搜索。
- 自动保存阅读和播放进度，下次打开接着看。

### 📚 整理书架，离线慢慢看

- 收藏喜欢的作品，分组整理，导出备份后可在新设备恢复。
- 提前下载内容，没网时继续阅读或播放。

## 下载与安装

前往 [**下载最新版**](https://github.com/ch6vip/novel-sound/releases/latest) 获取安装包和更新说明。

| 平台 | 系统要求 | 下载 |
| --- | --- | --- |
| 安卓 | Android 7.0 及以上 | [推荐安装包](https://github.com/ch6vip/novel-sound/releases/latest/download/app-arm64-v8a-release.apk) |
| Windows | Windows 10 / 11，64 位 | [进入下载页](https://github.com/ch6vip/novel-sound/releases/latest) |

- **安卓**：大多数手机选择推荐安装包；旧款 32 位设备使用[备用安装包](https://github.com/ch6vip/novel-sound/releases/latest/download/app-armeabi-v7a-release.apk)。
- **Windows**：下载 Windows 压缩包，完整解压后打开 `fqapp.exe`，保留同目录的其他文件。更多用法见 [Windows 说明](WINDOWS.md)。

Linux / Arch 社区移植正在推进，见 [#308](https://github.com/ch6vip/novel-sound/issues/308)。目前没有正式的 Linux、iPhone 或 Mac 安装包。

### 开始使用

1. **找作品**：在首页浏览，或搜索作品名称、编号。
2. **导入自己的书**：在书架菜单选择「导入图书」，打开 TXT / EPUB 文件。
3. **下载小说**：在作品详情点「下载」，在「我的 → 离线缓存」管理已下载内容。

看小说时点击屏幕中间，可以调整阅读设置。主题和听书选项在「我的 → 设置」；经典主题点击右上角齿轮。

## 常见问题

<details>
<summary><b>没网也能用吗？</b></summary>

可以看已导入的电子书、读已缓存的章节、播放已下载的媒体。只有已下载完成的内容才能离线使用，搜索和获取新内容仍需要联网。启动时可选择「离线阅读」。

</details>

<details>
<summary><b>一直加载、搜索失败或播放不了，怎么办？</b></summary>

先检查网络，换个网络或重启应用再试。在线内容依赖第三方服务，对方调整或网络波动可能导致暂时不可用。

持续失败请[反馈问题](https://github.com/ch6vip/novel-sound/issues)，附上应用版本、设备型号、作品名称或编号，以及错误截图。

</details>

<details>
<summary><b>换设备怎么搬书架和进度？</b></summary>

在「我的 → 备份与导入」导出备份文件，传到新设备后选择「从备份文件恢复」，预览并确认。

备份包含收藏、书架分组、已保存的阅读和播放进度、已看剧集；不包含本地电子书、下载缓存、阅读时长、划线和设置。导出前先退出阅读或暂停播放，让进度保存，本地书文件请单独保留。

</details>

<details>
<summary><b>系统朗读没有声音？</b></summary>

检查媒体音量，并确认设备安装了语音引擎和中文音色。在「设置 → 听书 → 系统朗读」选择可用语音；Windows 用户可在系统语音设置中安装中文音色。

</details>

## 参与与支持

使用中遇到问题，或有想要的功能，欢迎[提交反馈](https://github.com/ch6vip/novel-sound/issues)。想一起改进项目，可以查看[贡献指南](CONTRIBUTING.md)和[开发文档](DEVELOPMENT.md)。

### 🤝 QQ 交流群

欢迎加入 **樱道** 交流群，分享使用心得、交流问题。用 QQ 扫码，或搜索群号 **726870896** 加入。

<p align="center">
  <a href=".github/qq-group.png">
    <img src=".github/qq-group.png" width="320" alt="QQ 交流群：樱道，群号 726870896">
  </a>
</p>

### ❤️ 赞助

如果什锦铺让你的阅读和追剧更方便，欢迎点个 [⭐ Star](https://github.com/ch6vip/novel-sound/stargazers)。也可以通过[爱发电](https://afdian.com/a/ch6vip)、微信或支付宝请作者喝杯咖啡，支持后续更新。

<p align="center">
  <a href=".github/wechat.png">
    <img src=".github/wechat.png" width="640" alt="赞助什锦铺：微信支付和支付宝收款码">
  </a>
</p>

点击图片可查看原图，方便扫码。

## 👥 贡献者

感谢每一位参与改进什锦铺的朋友。

<a href="https://github.com/ch6vip/novel-sound/graphs/contributors">
  <img src=".github/contributors.svg" alt="贡献者">
</a>

## Star History

<a href="https://www.star-history.com/?repos=ch6vip%2Fnovel-sound&type=date&legend=top-left">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=ch6vip%2Fnovel-sound&type=date&theme=dark&legend=top-left">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=ch6vip%2Fnovel-sound&type=date&legend=top-left">
    <img src="https://api.star-history.com/chart?repos=ch6vip%2Fnovel-sound&type=date&legend=top-left" alt="什锦铺 Star History">
  </picture>
</a>

## 致谢与许可

感谢 [Wenku8 界面项目](assets/licenses/wenku8/PORTING.md)与 [LINUX DO](https://linux.do/) 社区。

项目采用 [GPL-3.0](LICENSE) 开源协议，Copyright © 2026 ch6vip。

在线内容来自第三方，版权归各自权利人。本项目与内容提供方无隶属关系，不托管作品，不绕过付费或访问权限。

书架、进度和缓存保存在设备上。如开启 AI 校对或云端同步，相关内容会发送到你选择的服务，使用前请阅读应用内说明。
