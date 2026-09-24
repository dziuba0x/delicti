#!/usr/bin/env python3
"""Signed distance field of the DELICTI wordmark, for the glass shader.

Writes hero/wordmark.svg (the outline, set in Geist Bold), then — given a 4× raster of it
(rendered by render.mjs) — hero/wordmark_sdf.f16: 1280×440 half floats, distance in design
pixels, negative inside the letters.
"""
import os
import sys

import numpy as np
from PIL import Image
from scipy.ndimage import distance_transform_edt, gaussian_filter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import build  # noqa: E402

W, H, SS = 1280, 440, 4
SIZE, BASELINE, TRACK = 200, 262, 0.05
BLUR = 4.0   # design px


def svg():
    path, width = build.text("DELICTI", "Geist-Bold", SIZE, W / 2, BASELINE, "#fff", anchor="middle", track=TRACK)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W * SS}" height="{H * SS}">'
            f'<rect width="{W}" height="{H}" fill="#000"/>{path}</svg>')


def sdf(mask_png):
    m = np.asarray(Image.open(mask_png).convert("L"), dtype=np.float32) / 255.0
    inside = m > 0.5
    d_out = distance_transform_edt(~inside)
    d_in = distance_transform_edt(inside)
    d = (d_out - d_in) / SS                       # design px, negative inside
    # soften the field: miters at the corners and the ridge along the medial axis round off, so the
    # letters read as poured glass, not as chiselled bevels (a linear field is unchanged by the blur)
    d = gaussian_filter(d, sigma=BLUR * SS)
    # sample at design-pixel centres
    d = d[SS // 2::SS, SS // 2::SS][:H, :W]
    return d.astype(np.float16)


if __name__ == "__main__":
    if sys.argv[1:2] == ["svg"]:
        open(os.path.join(HERE, "wordmark.svg"), "w").write(svg())
    else:
        d = sdf(sys.argv[1])
        d.tofile(os.path.join(HERE, "wordmark_sdf.f16"))
        print("sdf", d.shape, float(d.min()), float(d.max()))
