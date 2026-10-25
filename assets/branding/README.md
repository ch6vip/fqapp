# 应用图标

`app_icon_source.png` 保存设计原图。它不在 Flutter 的 assets 清单中，不会把
2048×2048 的原图打进 APK。

更换原图后，在项目根目录执行：

```sh
python -m pip install "Pillow>=9.1"
python scripts/generate_app_icons.py
```

脚本生成以下资源，生成结果随源码保存，正常构建无需安装 Python 或 Pillow：

- Android 五档密度的桌面图标（48 / 72 / 96 / 144 / 192 像素）：方形版本按底板的
  15% 圆角裁切，另有圆形版本。Android 7.x 没有自适应图标，桌面直接使用这两组图。
- Android 8.0 及以上的自适应图标：底板色与前景一致，原图铺满 108dp 前景的 72dp
  视觉区；圆形、圆角方形遮罩会切掉 72dp 方形的四角，关键图形需留在 66dp 安全区内。
- `windows/runner/resources/app_icon.ico`：16–256 七档，供 Windows 运行器与安装包
  使用。
- `assets/images/app_logo.webp`：384×384，供应用内“关于”页使用。该页以 88dp 绘制，
  384px 覆盖到 4 倍 DPI；用 WebP 而非 PNG 是为了让入包体积小一个数量级。

设计原图自带白色页边与圆角底板。脚本会把页边刷成底板色，让底板铺满整个画板；
否则系统底板与画在内层的底板会叠成双层背景。原图若带透明通道，会先铺到白底上再
处理；四角找不到白页边、页边占比异常或页边没灌满时脚本直接报错，不会产出错色图标。

图标配置见 `android/app/src/main/AndroidManifest.xml`，Flutter 资源声明见
`pubspec.yaml`。桌面图标需要重新构建并安装 APK 后更新，热重载不会更新桌面图标；
Windows 图标由同一脚本生成，构建安装包前无需手工替换。
