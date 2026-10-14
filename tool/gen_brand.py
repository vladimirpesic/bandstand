#!/usr/bin/env python3
"""Regenerate Bandstand's launcher icons and splash glyphs from the brand SVG.

Source of truth: ``tool/favicon.svg`` — the dark rounded tile with the amber
bandstand arch, carried over from the retired website when it was removed.
Every brand asset shipped under ``app/`` derives from two 1024px masters
rendered with ``rsvg-convert``:

  tile master    favicon.svg as-is (tile + glyph)
  glyph master   favicon.svg with the background ``<rect>`` removed

Recipes (verified pixel-exact against the shipped v1.0.0 assets, except where
noted):

  Android legacy launcher   tile master, LANCZOS resize
  Android adaptive fg       glyph master, LANCZOS resize to 58% of the 108dp
                            canvas, alpha-pasted centred (also serves as the
                            monochrome/themed icon via ic_launcher.xml)
  Splash glyph              glyph rendered at 440px on the 432px canvas; the
                            shipped file's antialiasing came out slightly
                            softer than a fresh render, so --check compares
                            this pair with a small tolerance instead of
                            demanding pixel equality

Usage:
  tool/gen_brand.py            regenerate all assets in place
  tool/gen_brand.py --check    verify the committed assets still match

Requires ``rsvg-convert`` (librsvg) and Pillow >= 9.1 (``pip install pillow``);
both are host-side dev tools only — the app itself has no such dependency.
"""

from __future__ import annotations

import argparse
import io
import re
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageStat

REPO = Path(__file__).resolve().parents[1]
SRC_SVG = REPO / "tool" / "favicon.svg"
ANDROID_RES = REPO / "app" / "android" / "app" / "src" / "main" / "res"

BG = (0x0B, 0x0D, 0x10)  # brand tile colour, matches favicon.svg
MASTER = 1024

# (dpi folder, legacy launcher px, adaptive foreground canvas px)
DENSITIES = [
    ("mdpi", 48, 108),
    ("hdpi", 72, 162),
    ("xhdpi", 96, 216),
    ("xxhdpi", 144, 324),
    ("xxxhdpi", 192, 432),
]
FOREGROUND_RATIO = 0.58  # glyph box as a fraction of the 108dp adaptive canvas
SPLASH_CANVAS = 432  # xxxhdpi foreground size, reused for the splash glyph
SPLASH_GLYPH = 440  # ~2% oversize, centred (negative paste offset)

# Mean per-channel difference (of 255) below which the splash counts as equal.
SPLASH_TOLERANCE = 6.0


def render(svg: Path, size: int) -> Image.Image:
    """Render an SVG to an RGBA image of the given square size."""
    out = subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), str(svg)],
        capture_output=True,
        check=True,
    ).stdout
    return Image.open(io.BytesIO(out)).convert("RGBA")


def glyph_svg_path() -> Path:
    """Write the favicon minus its background tile to a scratch file."""
    favicon = SRC_SVG.read_text()
    stripped = re.sub(r"<rect[^>]*/>", "", favicon, count=1)
    if stripped == favicon:
        sys.exit("favicon.svg no longer contains a background <rect> to strip")
    path = REPO / ".git" / "gen_brand.glyph.svg"
    path.write_text(stripped)
    return path


def outputs(tile: Image.Image, glyph: Image.Image, glyph_path: Path) -> dict[Path, Image.Image | bytes]:
    """Map every target file to its regenerated content."""
    out: dict[Path, Image.Image | bytes] = {}

    for dpi, legacy, canvas in DENSITIES:
        # Android legacy launcher icon.
        out[ANDROID_RES / f"mipmap-{dpi}/ic_launcher.png"] = tile.resize(
            (legacy, legacy), Image.Resampling.LANCZOS
        )
        # Android adaptive foreground: glyph at 58% of the 108dp canvas.
        box = round(canvas * FOREGROUND_RATIO)
        small = glyph.resize((box, box), Image.Resampling.LANCZOS)
        layer = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        layer.paste(small, ((canvas - box) // 2, (canvas - box) // 2), small)
        out[ANDROID_RES / f"mipmap-{dpi}/ic_launcher_foreground.png"] = layer

    # Splash glyph: 440px glyph on the 432px canvas.
    big = render(glyph_path, SPLASH_GLYPH)
    splash = Image.new("RGBA", (SPLASH_CANVAS, SPLASH_CANVAS), (0, 0, 0, 0))
    offset = (SPLASH_CANVAS - SPLASH_GLYPH) // 2  # negative: 2% oversize glyph
    splash.paste(big, (offset, offset), big)
    out[ANDROID_RES / "drawable-nodpi/launch_logo.png"] = splash

    return out


def write(assets: dict[Path, Image.Image | bytes]) -> None:
    for path, content in assets.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            content.save(path)
        print(f"wrote {path.relative_to(REPO)}")


def check(assets: dict[Path, Image.Image | bytes]) -> bool:
    ok = True
    for path, content in sorted(assets.items()):
        rel = str(path.relative_to(REPO))
        if not path.exists():
            print(f"MISSING {rel}")
            ok = False
            continue
        if isinstance(content, bytes):
            good = path.read_bytes() == content
            print(("ok      " if good else "DIFFERS ") + rel)
            ok &= good
            continue
        ref = Image.open(path).convert("RGBA")
        if ref.size != content.size:
            print(f"DIFFERS {rel} (size)")
            ok = False
            continue
        mean = sum(ImageStat.Stat(ImageChops.difference(content.convert("RGBA"), ref)).mean) / 4
        if mean == 0:
            print(f"ok      {rel}")
        elif "launch_logo" in path.name and mean < SPLASH_TOLERANCE:
            print(f"ok*     {rel} (mean delta {mean:.2f}/255, within tolerance)")
        else:
            print(f"DIFFERS {rel} (mean delta {mean:.2f}/255)")
            ok = False
    return ok


def main() -> None:
    parser = argparse.ArgumentParser(description="Regenerate the Bandstand brand assets.")
    parser.add_argument(
        "--check", action="store_true", help="verify the committed assets instead of rewriting"
    )
    args = parser.parse_args()

    glyph_path = glyph_svg_path()
    try:
        tile = render(SRC_SVG, MASTER)
        glyph = render(glyph_path, MASTER)
        assets = outputs(tile, glyph, glyph_path)
    finally:
        glyph_path.unlink(missing_ok=True)
    if args.check:
        sys.exit(0 if check(assets) else 1)
    write(assets)


if __name__ == "__main__":
    main()
