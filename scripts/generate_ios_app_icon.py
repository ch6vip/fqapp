#!/usr/bin/env python3
"""Generate the iOS AppIcon set from assets/branding/app_icon_source.png.

复用 Android 生成器里的「去掉纸张外框、让色板铺满画板」逻辑，输出 iOS 需要的
1024x1024 无 alpha 方图（iOS 自己会加圆角遮罩，所以不能自带圆角与留白），并把
AppIcon.appiconset 改成 Xcode 15+ 的单尺寸 1024 形式。

Requires Pillow >= 9.1。从仓库根目录：python scripts/generate_ios_app_icon.py
普通 Flutter 构建直接使用生成后的文件，不需要每次运行。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image, ImageOps

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_app_icons import ROOT, SOURCE, measure_plate, strip_page_margin  # noqa: E402

ICON_SET = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
ICON_SIZE = 1024
ICON_NAME = "Icon-App-1024x1024@1x.png"


def main() -> None:
    if not SOURCE.is_file():
        raise SystemExit(f"找不到图标母版：{SOURCE}")
    with Image.open(SOURCE) as original:
        source = ImageOps.exif_transpose(original).convert("RGBA")
    if source.width != source.height or source.width < ICON_SIZE:
        raise SystemExit("图标母版必须是正方形且不小于 1024x1024。")

    # 与 Android 生成器一致：母版若带透明洞，先把它们压平，再让外框重涂成色板色。
    holes = None
    if source.getextrema()[3][0] < 255:
        holes = source.getchannel("A").point(lambda value: 255 if value < 255 else 0)
        flattened = Image.new("RGBA", source.size, (255, 255, 255, 255))
        flattened.alpha_composite(source)
        source = flattened

    plate = measure_plate(source)
    tile = strip_page_margin(source, plate, holes)

    ICON_SET.mkdir(parents=True, exist_ok=True)
    # iOS 图标不能带 alpha（且不能自带圆角），所以先铺满色板再转 RGB。
    canvas = Image.new("RGB", (ICON_SIZE, ICON_SIZE), plate)
    canvas.paste(tile.resize((ICON_SIZE, ICON_SIZE), Image.Resampling.LANCZOS), (0, 0))
    canvas.save(ICON_SET / ICON_NAME, format="PNG", optimize=True)

    # 删掉模板里旧的逐尺寸图标，避免残留未引用的资源。
    for stale in ICON_SET.glob("Icon-App-*.png"):
        if stale.name != ICON_NAME:
            stale.unlink()

    contents = {
        "images": [
            {
                "filename": ICON_NAME,
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (ICON_SET / "Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n", encoding="utf-8"
    )
    print(f"wrote {ICON_SET / ICON_NAME} and Contents.json")


if __name__ == "__main__":
    main()
