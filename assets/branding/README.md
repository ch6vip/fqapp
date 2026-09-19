# 应用图标

`app_icon_source.png` 保存设计原图。它不在 Flutter 的 assets 清单中，不会把
2048×2048 的原图打进 APK。

更换原图后，在项目根目录执行：

```sh
python -m pip install Pillow
python scripts/generate_app_icons.py
```

脚本生成以下资源，生成结果随源码保存，正常构建无需安装 Python 或 Pillow：

- Android 五档密度的桌面图标（48 / 72 / 96 / 144 / 192 像素）及圆形图标。
- Android 8.0 及以上的自适应图标：米白底色，60dp 原图置于 108dp 前景画布中央，
  为圆形、圆角方形等系统裁切保留空间。
- `assets/images/app_logo.webp`：384×384，供应用内“关于”页使用。该页以 96dp 绘制，
  384px 覆盖到 4 倍 DPI；用 WebP 而非 PNG 是为了让入包体积小一个数量级。
- `assets/web/favicon.png`：64×64，供内置网页使用。

图标配置见 `android/app/src/main/AndroidManifest.xml`，Flutter 资源声明见
`pubspec.yaml`。桌面图标需要重新构建并安装 APK 后更新，热重载不会更新桌面图标。
