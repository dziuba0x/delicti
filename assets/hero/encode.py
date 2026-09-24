#!/usr/bin/env python3
"""Frames (2× supersampled PNGs from render.cjs) → assets/hero.webp, an animated WebP that loops.

    python3 encode.py <framesDir> [fps] [quality]
"""
import glob
import os
import sys

from PIL import Image

src = sys.argv[1]
fps = float(sys.argv[2]) if len(sys.argv) > 2 else 24
quality = int(sys.argv[3]) if len(sys.argv) > 3 else 82
out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hero.webp")

files = sorted(glob.glob(os.path.join(src, "f*.png")))
frames = []
for f in files:
    im = Image.open(f).convert("RGBA")
    frames.append(im.resize((im.width // 2, im.height // 2), Image.LANCZOS))
frames[0].save(out, save_all=True, append_images=frames[1:], duration=round(1000 / fps), loop=0,
               quality=quality, method=6, lossless=False, alpha_quality=90)
print(out, len(frames), "frames", round(os.path.getsize(out) / 1e6, 2), "MB")
