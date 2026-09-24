# The hero

`assets/hero.webp` is rendered, not drawn: a WebGL2 shader (`hero.html`), run frame by frame in headless Chromium.

- **Space.** A domain-warped nebula lit by the two witnesses, cyan (the effector's receipt) and amber (the Flare Data Connector). They meet in a white star behind the name. There are three layers of stars, and four of them carry JWST-style six-point spikes. The labels are printed on the same plane, so glass that passes over them bends them.
- **Glass.** The wordmark (Geist Bold, `make_sdf.py`) and ten drops form one signed distance field. Drops are smooth-unioned with each other (k = 26) and with the letters (k = 16), so they neck and merge the way Liquid Glass shapes morph. Height comes from a squircle bevel (`(1 − (1 − x)⁴)^¼`, the profile Apple uses). Snell refraction is computed per colour channel (IOR 1.44 / 1.50 / 1.57) and dampened so the image bends without tearing, with a little frost from the mip chain. Fresnel is weak, the rim light travels as the key light turns, and a hairline sits at the silhouette. A soft shadow falls on the plane and is visible through the glass as well. Following Apple's rule for clear glass, a dimming layer sits under the name.
- **Loop.** Everything is periodic in `t ∈ [0, 1)`: 240 frames at 24 fps, 10 s, seamless.

```sh
npm pack geist && tar xzf geist-*.tgz            # Geist, SIL OFL 1.1
export GEIST=$PWD/package/dist/fonts CHROMIUM=/path/to/chromium NODE_PATH=/path/to/node_modules   # playwright
python3 make_sdf.py svg                            # → wordmark.svg; render it at 4× (5120×1760) to mask.png
python3 make_sdf.py mask.png                       # → wordmark_sdf.f16
node render.cjs frames 240                         # 1280×440 at 2×
python3 encode.py frames 24 80                     # → ../hero.webp
node render.cjs social 240 1280 640 100 0 2 100    # one frame at 1280×640 → ../social-preview.png
```
