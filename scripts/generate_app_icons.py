#!/usr/bin/env python3
"""Generate checked-in app icons from assets/branding/app_icon_source.png.

The design master paints a rounded plate on a white page margin. Pasting that
picture into an adaptive foreground made the white margin and the plate show up
as a second background on top of the launcher's own background layer. The
generator repaints the page margin with the plate colour and lets the plate
bleed to the edge of every artboard, so a launcher only ever sees one surface.

The generator writes the Android launcher icons, the Windows .ico used by the
runner and the installer, and the in-app WebP logo.

Requires Pillow >= 9.1 (Image.Resampling, ICO bitmap_format):
python -m pip install "Pillow>=9.1"
From the repository root: python scripts/generate_app_icons.py
Normal Flutter / Android builds use the generated files without running this.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/branding/app_icon_source.png"
RES = ROOT / "android/app/src/main/res"
WINDOWS_ICON = ROOT / "windows/runner/resources/app_icon.ico"
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
WINDOWS_ICON_SIZES = (16, 24, 32, 48, 64, 128, 256)

# Android masks the 108dp adaptive layer down to 72dp, so the plate fills the
# whole visible board: no inner square, and the drawing keeps the proportions
# of the legacy artboard. Both launchers share the same 72dp visible size.
ADAPTIVE_SIZE = 108
VISIBLE_SIZE = 72

# Anything at or above this channel value belongs to the white page margin the
# design master was exported on. The plate's darkest channel stays well below
# it; re-measure both values after replacing the master.
PAGE_MARGIN_MIN_CHANNEL = 232

# The plate is a rounded rectangle whose corners cut in at about 15% of the
# side (304px on the 2048px master). API 24-25 launchers draw the legacy PNG
# as-is, so the same mask keeps the plate silhouette instead of a square block.
PLATE_CORNER_SHARE = 0.15

# The margin is four corner cut-outs (roughly 2% of the source). Anything much
# larger means the threshold or the source changed, so the run must stop
# instead of repainting most of the artwork.
PAGE_MARGIN_SHARE_LIMIT = 0.25

# Anti-aliasing can leave a few paper-coloured specks on the artboard border;
# a real under-fill (threshold too high or a gradient margin) leaves a long run.
# The tolerance follows the border length (about 64px on the 2048px master).
BORDER_PAPER_SHARE = 0.008

# The about page draws the in-app logo at 88dp, so 384px covers 4x DPI with
# headroom to spare. WebP keeps the bundled file an order of magnitude smaller
# than the same picture as a PNG.
LOGO_SIZE = 384
LOGO_QUALITY = 88


def save_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)
    print(f"{path.relative_to(ROOT).as_posix()} ({image.width}x{image.height})")


def save_webp(image: Image.Image, path: Path, *, quality: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Drop the alpha channel: the design master's alpha is fully opaque, and
    # carrying it into WebP only makes the encoder store a 255 plane.
    image.convert("RGB").save(path, "WEBP", quality=quality, method=6)
    print(
        f"{path.relative_to(ROOT).as_posix()} "
        f"({image.width}x{image.height}, q{quality})"
    )


def save_ico(image: Image.Image, path: Path, sizes: tuple[int, ...]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    largest = max(sizes)
    # Pillow drops entries larger than the source without any error.
    if min(image.size) < largest:
        raise SystemExit(f"ICO source must cover {largest}x{largest} pixels.")
    # DIB frames keep the file readable by rc.exe and Inno Setup, which are
    # stricter than the shell about PNG-compressed entries.
    image.save(path, format="ICO", bitmap_format="bmp",
               sizes=[(size, size) for size in sizes])
    print(
        f"{path.relative_to(ROOT).as_posix()} "
        f"({', '.join(str(size) for size in sizes)})"
    )


def measure_plate(source: Image.Image) -> tuple[int, int, int]:
    """Median colour of the plate along its top edge, skipping the margin.

    The design master keeps a thin paper margin, so the plate already reaches
    into the top 5% of the canvas; a wider border would need cropping first.
    """
    pixels = source.load()
    width, height = source.size
    samples = []
    for y in range(0, height // 20, 4):
        for x in range(width // 3, 2 * width // 3, 8):
            colour = pixels[x, y][:3]
            if min(colour) < PAGE_MARGIN_MIN_CHANNEL:
                samples.append(colour)
    if not samples:
        raise SystemExit("Could not find the icon plate; check the source image.")
    samples.sort(key=sum)
    return samples[len(samples) // 2]


def strip_page_margin(source: Image.Image,
                      plate: tuple[int, int, int],
                      holes: Image.Image | None = None) -> Image.Image:
    """Repaint the white margin around the plate so the plate bleeds edge to edge.

    Only the margin connected to the image border is replaced: the same bright
    values also appear in the sparkles inside the artwork and must survive.
    The margin is four separate corner cut-outs (the plate reaches the other
    edges), so every corner seeds its own fill. ``holes`` marks pixels that were
    transparent in the master; they are repainted too, so an enclosed hole does
    not stay white once the picture sits on the plate colour. Semi-transparent
    pixels are flattened onto white as well, so the master should use hard
    edges rather than glows or soft shadows.
    """
    width, height = source.size
    red, green, blue = source.convert("RGB").split()
    lowest = ImageChops.darker(ImageChops.darker(red, green), blue)
    margin = lowest.point(
        lambda value: 255 if value >= PAGE_MARGIN_MIN_CHANNEL else 0)
    pixels = margin.load()
    corners = ((0, 0), (width - 1, 0), (0, height - 1),
               (width - 1, height - 1))
    # floodfill copies whatever the seed already is, so a corner without paper
    # would turn the plate and the artwork into "margin" without any error.
    for corner in corners:
        if pixels[corner] != 255:
            raise SystemExit(
                f"Page margin is missing at {corner}; keep a white border "
                "around the plate or update the margin rule."
            )
    for corner in corners:
        ImageDraw.floodfill(margin, corner, 128, thresh=0)
    # Paper left on the border means the fill stopped early (the threshold is
    # too high or the paper has a gradient), which would leave a white crescent.
    # A handful of anti-aliased specks is repainted instead of failing the run.
    filled = margin.load()
    border = [(x, y) for x in range(width) for y in (0, height - 1)]
    border += [(x, y) for y in range(height) for x in (0, width - 1)]
    leftover = [point for point in border if filled[point] == 255]
    if len(leftover) > round(2 * (width + height) * BORDER_PAPER_SHARE):
        raise SystemExit(
            "Page margin was not filled completely; check the margin rule."
        )
    for point in leftover:
        filled[point] = 128
    margin = margin.point(lambda value: 255 if value == 128 else 0)
    share = margin.histogram()[255] / (width * height)
    if share > PAGE_MARGIN_SHARE_LIMIT:
        raise SystemExit(
            f"Page margin covers {share:.0%} of the source; refusing to "
            "repaint that much of the artwork."
        )
    if holes is not None:
        margin = ImageChops.lighter(margin, holes)
    # Grow by two pixels so the anti-aliased rim between margin and plate is
    # repainted too; a leftover light rim would trace the old rounded corners.
    margin = margin.filter(ImageFilter.MaxFilter(5))
    tile = Image.new("RGBA", (width, height), (*plate, 255))
    tile.paste(source, (0, 0), ImageOps.invert(margin))
    return tile


def place_picture(tile: Image.Image, size: int, picture_size: int,
                  plate: tuple[int, int, int]) -> Image.Image:
    """Center the plate picture on an opaque layer of ``size`` pixels.

    The picture already carries the plate colour, so the layer needs no alpha:
    a fully opaque alpha plane would only bloat the PNG. ``tile`` must be
    opaque, otherwise its transparent parts would show the plate colour.
    """
    canvas = Image.new("RGB", (size, size), plate)
    picture = tile.resize((picture_size, picture_size), Image.Resampling.LANCZOS)
    offset = (size - picture_size) // 2
    canvas.paste(picture, (offset, offset))
    return canvas


def rounded_board(tile: Image.Image, size: int) -> Image.Image:
    """Resize the plate picture to a rounded square of ``size`` pixels."""
    board = tile.resize((size, size), Image.Resampling.LANCZOS)
    mask = Image.new("L", board.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size - 1, size - 1),
        radius=round(size * PLATE_CORNER_SHARE), fill=255)
    board.putalpha(mask)
    return board


def main() -> None:
    with Image.open(SOURCE) as original:
        source = ImageOps.exif_transpose(original).convert("RGBA")
    if source.width != source.height or source.width < 512:
        raise SystemExit("Use a square source image of at least 512x512 pixels.")
    # The margin model assumes an opaque sheet. A transparent export would
    # sample (0, 0, 0) as the plate and keep holes inside the plate colour.
    holes = None
    if source.getextrema()[3][0] < 255:
        holes = source.getchannel("A").point(
            lambda value: 255 if value < 255 else 0)
        flattened = Image.new("RGBA", source.size, (255, 255, 255, 255))
        flattened.alpha_composite(source)
        source = flattened

    plate = measure_plate(source)
    tile = strip_page_margin(source, plate, holes)

    # Legacy and adaptive launchers see the same 72dp board; the round and
    # adaptive variants only change the outer mask. 1152px is 6x the largest
    # legacy output (192px), so the corner mask is cut before downsampling.
    board = VISIBLE_SIZE * 16
    legacy = rounded_board(tile, board)
    round_legacy = legacy.copy()
    round_mask = Image.new("L", legacy.size, 0)
    ImageDraw.Draw(round_mask).ellipse(
        (0, 0, board - 1, board - 1), fill=255)
    round_legacy.putalpha(round_mask)

    for density, scale in DENSITIES.items():
        directory = RES / f"mipmap-{density}"
        size = round(48 * scale)
        save_png(legacy.resize((size, size), Image.Resampling.LANCZOS),
                 directory / "ic_launcher.png")
        save_png(round_legacy.resize((size, size), Image.Resampling.LANCZOS),
                 directory / "ic_launcher_round.png")
        foreground = place_picture(tile, round(ADAPTIVE_SIZE * scale),
                                   round(VISIBLE_SIZE * scale), plate)
        save_png(foreground, directory / "ic_launcher_foreground.png")

    adaptive = RES / "mipmap-anydpi-v26"
    adaptive.mkdir(parents=True, exist_ok=True)
    adaptive_xml = '''<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by scripts/generate_app_icons.py. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
'''
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        (adaptive / name).write_text(adaptive_xml, encoding="utf-8")

    (RES / "values").mkdir(parents=True, exist_ok=True)
    plate_hex = "#" + "".join(f"{value:02X}" for value in plate)
    (RES / "values/ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- Generated by scripts/generate_app_icons.py. -->\n'
        f'<resources>\n    <color name="ic_launcher_background">{plate_hex}</color>\n'
        '</resources>\n', encoding="utf-8")

    save_ico(rounded_board(tile, max(WINDOWS_ICON_SIZES)), WINDOWS_ICON,
             WINDOWS_ICON_SIZES)

    save_webp(tile.resize((LOGO_SIZE, LOGO_SIZE), Image.Resampling.LANCZOS),
              ROOT / "assets/images/app_logo.webp", quality=LOGO_QUALITY)


if __name__ == "__main__":
    main()
