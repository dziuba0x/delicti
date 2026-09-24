#!/usr/bin/env python3
"""Builds the README's chart: structuring-{light,dark}.svg. (The hero is rendered by hero/.)

Every glyph is set as a path, so the SVGs look the same on every machine and need no fonts.
Typeface: Geist and Geist Mono (SIL OFL 1.1, https://vercel.com/font). Fetch them with
`npm pack geist`, then run:  GEIST=path/to/package/dist/fonts python3 assets/build.py

Colours are the house pair: cyan for the effector's receipt (witness 1), amber for the Flare
Data Connector (witness 2).
"""
import os
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

FONTS = os.environ.get("GEIST", "node_modules/geist/dist/fonts")
OUT = os.path.dirname(os.path.abspath(__file__))
_cache = {}


def font(name):
    if name not in _cache:
        sub = "geist-mono" if name.startswith("GeistMono") else "geist-sans"
        _cache[name] = TTFont(os.path.join(FONTS, sub, name + ".ttf"))
    return _cache[name]


def text(s, face, size, x, y, fill, anchor="start", track=0.0, opacity=None):
    """One <path> holding `s` set in `face` at `size` px; `track` is extra spacing in em."""
    f = font(face)
    gs, cmap, hmtx = f.getGlyphSet(), f.getBestCmap(), f["hmtx"]
    k = size / f["head"].unitsPerEm
    gap = track * size
    names = [cmap.get(ord(c), cmap[ord("?")]) for c in s]
    width = sum(hmtx[n][0] * k for n in names) + gap * (len(names) - 1)
    x0 = {"start": x, "middle": x - width / 2, "end": x - width}[anchor]
    pen = SVGPathPen(gs)
    cx = x0
    for n in names:
        gs[n].draw(TransformPen(pen, (k, 0, 0, -k, cx, y)))
        cx += hmtx[n][0] * k + gap
    op = f' fill-opacity="{opacity}"' if opacity is not None else ""
    return f'<path d="{pen.getCommands()}" fill="{fill}"{op}/>', width


def t(*a, **kw):
    return text(*a, **kw)[0]


THEMES = {
    "light": dict(
        bg="#F5F5F7", ink="#1D1D1F", ink2="#6E6E73", ink3="#A1A1A6",
        dot="#000", dot_op=0.075, tile_stroke="#000", tile_op=0.045, tile_fill="#FFFFFF", tile_fill_op=0.35,
        glass="#FFFFFF", glass_op=0.58, rim="#FFFFFF", rim_op=1.0, shadow_op=0.10,
        cyan="#27C2F2", amber="#FF9F2E", core="#FFFFFF", light_op=0.95, core_op=1.0,
    ),
    "dark": dict(
        bg="#0B0B0D", ink="#F5F5F7", ink2="#C7C7CC", ink3="#7C7C82",
        dot="#FFF", dot_op=0.07, tile_stroke="#FFF", tile_op=0.06, tile_fill="#FFFFFF", tile_fill_op=0.015,
        glass="#0B0B0D", glass_op=0.5, rim="#FFFFFF", rim_op=0.2, shadow_op=0.55,
        cyan="#35CFFF", amber="#FFAE45", core="#FFFFFF", light_op=0.9, core_op=0.5,
    ),
}

REDUCED = "@media (prefers-reduced-motion: reduce){*{animation:none!important}}"


def dots(c, w, h, rx=0):
    return (f'<pattern id="dots" width="18" height="18" patternUnits="userSpaceOnUse">'
            f'<circle cx="9" cy="9" r="0.9" fill="{c["dot"]}" fill-opacity="{c["dot_op"]}"/></pattern>'
            f'<rect width="{w}" height="{h}" rx="{rx}" fill="url(#dots)"/>')


def structuring(theme):
    c = THEMES[theme]
    W, H = 1200, 600
    X0, base, unit = 150, 480, 58                  # plot origin, px per unit
    xs = [230 + i * 170 for i in range(5)]
    y = lambda v: base - v * unit
    mono, sans = "GeistMono-Medium", "Geist-Regular"
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
           f'aria-label="Five calls of 1 against a budget of 4. Each call passes its own check; the running total reaches 5 and breaks the budget at call 5.">',
           "<style>.glow{animation:gl 3.2s ease-in-out infinite}@keyframes gl{0%,100%{opacity:.45}50%{opacity:1}}",
           REDUCED, "</style><defs>",
           '<filter id="blur" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="16"/></filter>',
           f'<linearGradient id="bar" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c["cyan"]}" stop-opacity="{.55 if theme == "light" else .5}"/>'
           f'<stop offset="1" stop-color="{c["cyan"]}" stop-opacity="{.18 if theme == "light" else .12}"/></linearGradient>',
           f'<linearGradient id="zone" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c["amber"]}" stop-opacity=".22"/>'
           f'<stop offset="1" stop-color="{c["amber"]}" stop-opacity=".04"/></linearGradient>',
           "</defs>",
           f'<rect width="{W}" height="{H}" rx="28" fill="{c["bg"]}"/>', dots(c, W, H, 28),
           t("THE SUM, NOT THE SLICE", mono, 12, 64, 66, c["ink3"], track=0.14),
           t("Five calls of 1. Every one allowed. Budget: 4.", "Geist-Medium", 28, 64, 106, c["ink"])]
    # grid and axis labels
    for v in range(0, 6):
        dash = "" if v == 0 else ' stroke-dasharray="2 6"'
        out.append(f'<path d="M {X0} {y(v)} H 1000" stroke="{c["ink"]}" stroke-opacity="{.16 if v == 0 else .09}"{dash}/>')
        out.append(t(str(v), mono, 12, X0 - 22, y(v) + 4, c["ink3"], anchor="end"))
    # the zone past the budget
    out.append(f'<rect x="{X0}" y="{y(5.6)}" width="{1000 - X0}" height="{y(4) - y(5.6)}" fill="url(#zone)"/>')
    out.append(f'<path d="M {X0} {y(4)} H 1000" stroke="{c["amber"]}" stroke-width="1.5"/>')
    out.append(t("BUDGET 4", mono, 12, 1010, y(4) + 4, c["amber"], track=0.1))
    # each call: a capsule of 1, a tick for "allowed"
    for i, x in enumerate(xs):
        out.append(f'<rect x="{x - 24}" y="{y(1)}" width="48" height="{unit}" rx="14" fill="url(#bar)" '
                   f'stroke="{c["cyan"]}" stroke-opacity=".55"/>')
        out.append(f'<path d="M {x - 7} {y(0.5)} l 5 5 l 9 -10" stroke="{c["ink"]}" stroke-opacity=".75" stroke-width="2" fill="none" '
                   f'stroke-linecap="round" stroke-linejoin="round"/>')
        out.append(t(f"CALL {i + 1}", mono, 12, x, base + 30, c["ink2"], anchor="middle", track=0.1))
        out.append(t("allowed", sans, 13, x, base + 50, c["ink3"], anchor="middle"))
    # the running total
    pts = [(x, y(i + 1)) for i, x in enumerate(xs)]
    d = "M " + " L ".join(f"{px} {py}" for px, py in pts[:4])
    out.append(f'<path d="{d}" stroke="{c["ink"]}" stroke-width="2" fill="none" stroke-linejoin="round"/>')
    out.append(f'<path d="M {pts[3][0]} {pts[3][1]} L {pts[4][0]} {pts[4][1]}" stroke="{c["amber"]}" stroke-width="2.5" fill="none"/>')
    for i, (px, py) in enumerate(pts[:4]):
        out.append(f'<circle cx="{px}" cy="{py}" r="5" fill="{c["bg"]}" stroke="{c["ink"]}" stroke-width="2"/>')
        out.append(t(f"∑ {i + 1}", mono, 12, px - 14, py - 14, c["ink2"], anchor="end"))
    bx, by = pts[4]
    out += [f'<circle class="glow" cx="{bx}" cy="{by}" r="26" fill="{c["amber"]}" filter="url(#blur)"/>',
            f'<circle cx="{bx}" cy="{by}" r="7" fill="{c["amber"]}"/>',
            f'<circle cx="{bx}" cy="{by}" r="11" fill="none" stroke="{c["amber"]}" stroke-opacity=".5"/>',
            f'<path d="M {bx + 16} {by} H 1010" stroke="{c["amber"]}" stroke-width="1"/>',
            t("∑ 5 > 4", mono, 13, 1010, by - 8, c["ink"], track=0.06),
            t("25 % of the bond", sans, 14, 1010, by + 14, c["ink2"]),
            # legend
            f'<rect x="64" y="{H - 44}" width="22" height="12" rx="4" fill="url(#bar)" stroke="{c["cyan"]}" stroke-opacity=".55"/>',
            t("each call, as a per-call policy sees it", sans, 14, 96, H - 34, c["ink2"]),
            f'<path d="M 420 {H - 38} H 450" stroke="{c["ink"]}" stroke-width="2"/>',
            t("the running total, which DELICTI judges", sans, 14, 460, H - 34, c["ink2"]),
            f'<path d="M 800 {H - 38} H 830" stroke="{c["amber"]}" stroke-width="1.5"/>',
            t("the mandate's budget", sans, 14, 840, H - 34, c["ink2"]),
            "</svg>"]
    return "\n".join(out)


if __name__ == "__main__":
    for th in THEMES:
        for name, fn in (("structuring", structuring),):
            p = os.path.join(OUT, f"{name}-{th}.svg")
            open(p, "w").write(fn(th))
            print(p, os.path.getsize(p))
