#!/usr/bin/env python3
"""Generate the AirliftSilence app icon set.

The icon is drawn from scratch rather than shipped as a binary blob, so the
repository carries no borrowed artwork and the design can be tweaked by editing
numbers here.

    python3 tools/make-icon.py

Writes the five PNGs the asset catalog expects, next to this script's target:
    ios-app/Assets.xcassets/AppIcon.appiconset/
"""

from __future__ import annotations

import os
from pathlib import Path

from PIL import Image, ImageDraw

MASTER = 1024
OUT = Path(__file__).resolve().parent.parent / "ios-app/Assets.xcassets/AppIcon.appiconset"

# Muted-speaker mark: a "sound off" glyph, which is what the app does.
TOP_LEFT = (27, 58, 107)      # deep navy
BOTTOM_RIGHT = (46, 111, 184)  # lighter blue
GLYPH = (255, 255, 255)


def background(size: int) -> Image.Image:
    """Diagonal gradient, full-bleed — iOS applies the rounded mask itself."""
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            # 0 at the top-left corner, 1 at the bottom-right corner
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(
                round(a + (b - a) * t) for a, b in zip(TOP_LEFT, BOTTOM_RIGHT)
            )
    return img


def glyph_mask(size: int) -> Image.Image:
    """White speaker with an open slash cut through it."""
    s = size / 1024  # everything below is authored against a 1024 canvas
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)

    def box(*coords: float) -> list[float]:
        return [c * s for c in coords]

    # Speaker body
    d.rounded_rectangle(box(246, 392, 384, 632), radius=20 * s, fill=255)
    # Cone
    d.polygon(
        [
            (384 * s, 392 * s),
            (592 * s, 268 * s),
            (592 * s, 756 * s),
            (384 * s, 632 * s),
        ],
        fill=255,
    )
    # Two sound waves, kept close to the cone and drawn thick — thin arcs read
    # as scattered dots once the slash cuts through them.
    for radius, width in ((90, 38), (162, 38)):
        d.arc(
            box(596 - radius, 512 - radius, 596 + radius, 512 + radius),
            start=-46,
            end=46,
            fill=255,
            width=round(width * s),
        )

    # Slash: drawn into the mask as a gap, not painted on top, so the gradient
    # shows through instead of a white line on a white speaker.
    width = round(58 * s)
    start, end = (216 * s, 268 * s), (812 * s, 756 * s)
    d.line([start, end], fill=0, width=width)
    for cx, cy in (start, end):  # round off the caps
        r = width / 2
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=0)

    return mask


def render(size: int) -> Image.Image:
    img = background(size)
    img.paste(GLYPH, (0, 0), glyph_mask(size))
    return img


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    master = render(MASTER)

    # filename: (pixel size, is the master written as-is)
    targets = {
        "AppIcon.png": MASTER,
        "AppIcon-60@2x.png": 120,
        "AppIcon-60@3x.png": 180,
        "AppIcon-76@2x.png": 152,
        "AppIcon-83.5@2x.png": 167,
    }
    for name, size in targets.items():
        img = master if size == MASTER else master.resize((size, size), Image.LANCZOS)
        path = OUT / name
        img.save(path, "PNG", optimize=True)
        print(f"  {name:<22} {size}x{size}  {os.path.getsize(path)} bytes")


if __name__ == "__main__":
    main()
