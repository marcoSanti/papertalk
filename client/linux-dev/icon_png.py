"""The Linux app icon as PNG, from shared/icon.icns.

    python3 icon_png.py <icon.icns> <out.png> [stable|dev] [size]

Like scripts/dev_icon.swift on macOS: only stable releases get the plain
official icon; dev builds get the yellow "DEV" corner ribbon, clipped to the
icon's own shape. (That script needs AppKit, so this is Pillow.)"""
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFont

src, out = sys.argv[1], sys.argv[2]
channel = sys.argv[3] if len(sys.argv) > 3 else "dev"
size = int(sys.argv[4]) if len(sys.argv) > 4 else 256

icon = Image.open(src)
icon.load()  # the largest size in the .icns
icon = icon.convert("RGBA").resize((size, size), Image.LANCZOS)

if channel != "stable":
    s = float(size)
    band = s * 0.16
    yellow, dark = (255, 199, 41, 255), (31, 31, 31, 255)
    # The ribbon, drawn level on a big canvas, rotated 45° and centred on the
    # lower-right corner area (same placement as the macOS dev icon).
    w = int(s * 2)
    ribbon = Image.new("RGBA", (w, int(band)), yellow)
    draw = ImageDraw.Draw(ribbon)
    edge = max(1, int(s * 0.008))
    draw.rectangle([0, 0, w, edge - 1], fill=dark)
    draw.rectangle([0, int(band) - edge, w, int(band)], fill=dark)
    if size >= 64:
        try:
            font = ImageFont.truetype("DejaVuSans-Bold.ttf", int(band * 0.6))
        except OSError:
            font = ImageFont.load_default()
        text = "DEV"
        left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
        draw.text(((w - (right - left)) / 2 - left, (band - (bottom - top)) / 2 - top), text, font=font, fill=dark)
    ribbon = ribbon.rotate(45, expand=True, resample=Image.BICUBIC)
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    cx, cy = s * 0.70, s * 0.70
    layer.paste(ribbon, (int(cx - ribbon.width / 2), int(cy - ribbon.height / 2)), ribbon)
    # Keep the ribbon only where the icon itself is opaque.
    layer.putalpha(ImageChops.multiply(layer.getchannel("A"), icon.getchannel("A")))
    icon = Image.alpha_composite(icon, layer)

icon.save(out)
print(f"{out}: {size}px {channel} icon")
