#!/usr/bin/env python3
"""The wordmark in three generations, as data the site and the terminal both render.

    scripts/brand_marks.py            writes docs/assets/brand/ and site/assets/lab/

Each generation is the same letterforms sampled onto its era's grid under its
era's palette limit: GEN 1 four CGA colors on 160x50 cells, GEN 2 sixteen on
320x100, GEN 3 two hundred fifty-six on 640x200. The word stays still; the
three slashes cycle their palette, the demoscene way: the index map never
changes, only the color table rotates.

Per generation this writes
    genN.idx.png       the index map, one byte per cell (a grayscale PNG)
    genN.json          the palette for every frame, plus which entries cycle
    wordmark-genN.gif  the whole mark, slashes cycling, at native resolution
    mark-genN.gif      the slashes alone, cycling
    word-genN.png      the word alone, still
    wordmark-genN.png  frame one, still, for reduced motion and documents

Needs Pillow and numpy (the capture venv has both).
"""
import json
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/assets/brand"
SITE = ROOT / "site/assets/lab"
PLUM = (0x18, 0x07, 0x1e)
LIME, CYAN, MAGENTA, PAPER = (0xb8, 0xff, 0x3c), (0x37, 0xe6, 0xff), (0xff, 0x3f, 0xa4), (0xe8, 0xe0, 0xd3)
CGA_CYAN, CGA_MAGENTA, CGA_WHITE = (0x55, 0xff, 0xff), (0xff, 0x55, 0xff), (0xff, 0xff, 0xff)
LAVENDER = (0xc9, 0x9c, 0xff)   # the original mark's cast: every still color leans toward it
BAYER = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]], dtype=np.float32) / 16.0
# The letterforms: a heavy geometric sans with flat terminals, drawn once large.
FONT = ("/System/Library/Fonts/Supplemental/Avenir Next.ttc", 8)   # Avenir Next Heavy
DRAW_W, DRAW_H = 3600, 1120


def lerp(a, b, t):
    return tuple(int(round(x + (y - x) * t)) for x, y in zip(a, b))


def ramp(n, stops=(LIME, CYAN, MAGENTA, LIME)):
    """N colors through the theme's stops, closed so a rotation is seamless."""
    out = []
    for i in range(n):
        t = i / n * (len(stops) - 1)
        k = int(t)
        out.append(lerp(stops[k], stops[k + 1], t - k))
    return out


def shaded(rgb, keep):
    return lerp(PLUM, rgb, keep)


def tinted(colors, amount=0.3):
    return [lerp(c, LAVENDER, amount) for c in colors]


def letterforms():
    """Two masks at drawing size: the word and the slashes."""
    word = Image.new("L", (DRAW_W, DRAW_H), 0)
    mark = Image.new("L", (DRAW_W, DRAW_H), 0)
    try:
        font = ImageFont.truetype(FONT[0], 900, index=FONT[1])
    except OSError:
        font = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 900, index=1)
    d = ImageDraw.Draw(word)
    d.text((60, -60), "shift", fill=255, font=font)
    start = 60 + d.textlength("shift", font=font) + 180
    d = ImageDraw.Draw(mark)
    for i in range(3):
        x = start + i * 330
        d.polygon([(x + 290, 130), (x + 470, 130), (x + 180, 1010), (x, 1010)], fill=255)
    return word, mark


def coverage(mask, w, h):
    return np.asarray(mask.resize((w, h), Image.BOX), dtype=np.float32) / 255.0


def dither_pick(t, n, y, x):
    """Position T in [0,1) along an N-entry ramp -> the entry, ordered-dithered between neighbours."""
    pos = t * n
    i = int(pos)
    return (i + 1) % n if pos - i > BAYER[y % 4, x % 4] else i % n


def gradient_t(x, y, w, h):
    return ((x / w) * 1.2 + (y / h) * 0.4) % 1.0


class Generation:
    """An index map plus a palette per frame. Entries in `cycling` rotate; the rest hold."""

    def __init__(self, name, w, h):
        self.name, self.w, self.h = name, w, h
        self.index = np.zeros((h, w), dtype=np.uint8)
        self.frames = []

    def palette_frames(self, still, cycle_base, cycle_ramp, shadow_keep=None, step=1, bevel=None):
        """STILL: fixed entries from index 1. CYCLE_RAMP rotates at CYCLE_BASE; a shadow copy follows it when SHADOW_KEEP is set."""
        n = len(cycle_ramp)
        for k in range(0, n, step):
            rotated = [cycle_ramp[(i + k) % n] for i in range(n)]
            pal = [PLUM] + still
            pal += [PLUM] * max(0, cycle_base - len(pal))
            pal += rotated
            if shadow_keep is not None:
                pal += [shaded(c, shadow_keep) for c in rotated]
            if bevel:
                pal += list(bevel)
            self.frames.append(pal)
        self.cycle = (cycle_base, cycle_base + n * (2 if shadow_keep is not None else 1))

    def write(self):
        w, h = self.w, self.h
        # the index map and the palettes, for the canvas and the terminal
        Image.fromarray(self.index, mode="L").save(OUT / f"{self.name}.idx.png")
        (OUT / f"{self.name}.json").write_text(json.dumps({
            "width": w, "height": h, "index": f"{self.name}.idx.png",
            "cycle": {"from": self.cycle[0], "to": self.cycle[1]},
            "frames": self.frames}, separators=(",", ":")))
        # the GIFs: identical pixels every frame, a local color table per frame
        def gif(path, index):
            frames = []
            for pal in self.frames:
                frame = Image.fromarray(index, mode="P")
                flat = [c for rgb in pal for c in rgb]
                frame.putpalette(flat + [0] * (768 - len(flat)))
                frames.append(frame)
            frames[0].save(path, save_all=True, append_images=frames[1:], duration=self.duration, loop=0, disposal=1, optimize=False)
        gif(OUT / f"wordmark-{self.name}.gif", self.index)
        cols = np.where(self.index.max(axis=0) > 0)[0]
        split = self.split
        gif(OUT / f"mark-{self.name}.gif", np.ascontiguousarray(self.index[:, split:cols[-1] + 2]))
        still = Image.fromarray(self.index, mode="P")
        flat = [c for rgb in self.frames[0] for c in rgb]
        still.putpalette(flat + [0] * (768 - len(flat)))
        still.convert("RGB").save(OUT / f"wordmark-{self.name}.png")
        still.convert("RGB").crop((0, 0, split, h)).save(OUT / f"word-{self.name}.png")
        for name in (f"{self.name}.idx.png", f"{self.name}.json", f"wordmark-{self.name}.gif", f"mark-{self.name}.gif",
                     f"word-{self.name}.png", f"wordmark-{self.name}.png"):
            shutil.copy(OUT / name, SITE / name)


def gen1():
    """CGA: four colors on screen. The word is white dithered with magenta, the purple cast; the slashes swap
    cyan and magenta bands. Four colors means the word's magenta cells swap with the slashes: GEN 1 shimmers."""
    g = Generation("gen1", 160, 50)
    word, mark = letterforms()
    cw, cm = coverage(word, g.w, g.h), coverage(mark, g.w, g.h)
    for y in range(g.h):
        for x in range(g.w):
            if cw[y, x] >= 0.5:
                g.index[y, x] = 3 if BAYER[y % 4, x % 4] < 0.18 + 0.5 * (y / g.h) ** 2 else 1
            elif cm[y, x] >= 0.5:
                g.index[y, x] = 2 + dither_pick(gradient_t(x, y, g.w, g.h) * 2 % 1.0, 2, y, x)
    g.split = int(np.where(cw.max(axis=0) >= 0.5)[0][-1]) + 3
    g.duration = 240
    g.palette_frames(still=[CGA_WHITE], cycle_base=2, cycle_ramp=[CGA_CYAN, CGA_MAGENTA])
    return g


def gen2():
    """EGA: sixteen colors. The word holds a six-entry dithered ramp; the slashes cycle an eight-entry one; one shadow tone."""
    g = Generation("gen2", 320, 100)
    word, mark = letterforms()
    cw, cm = coverage(word, g.w, g.h), coverage(mark, g.w, g.h)
    word_ramp, slash_ramp = ramp(6), ramp(8)
    for y in range(g.h):
        for x in range(g.w):
            t = gradient_t(x, y, g.w, g.h)
            low = (y / g.h) > 0.74 and ((y / g.h) - 0.74) / 0.26 > BAYER[(y + 2) % 4, (x + 1) % 4]
            if cw[y, x] >= 0.5:
                g.index[y, x] = 15 if low else 1 + dither_pick(t, 6, y, x)
            elif cm[y, x] >= 0.5:
                g.index[y, x] = 7 + dither_pick(t, 8, y, x)
    g.split = int(np.where(cw.max(axis=0) >= 0.5)[0][-1]) + 3
    g.duration = 110
    still = tinted(word_ramp)
    g.palette_frames(still=still, cycle_base=7, cycle_ramp=slash_ramp)
    for pal in g.frames:                       # entry 15: the word's shadow tone, fixed
        pal.append(shaded(word_ramp[2], 0.55))
    return g


def gen3():
    """VGA: 256 colors. The word holds a 64-entry ramp with a shadow copy; the slashes cycle a 48-entry ramp with theirs; a bevel."""
    g = Generation("gen3", 640, 200)
    word, mark = letterforms()
    cw, cm = coverage(word, g.w, g.h), coverage(mark, g.w, g.h)
    inside = (cw >= 0.5) | (cm >= 0.5)
    up = np.zeros_like(inside); up[1:, :] = inside[:-1, :]
    left = np.zeros_like(inside); left[:, 1:] = inside[:, :-1]
    down = np.zeros_like(inside); down[:-1, :] = inside[1:, :]
    right = np.zeros_like(inside); right[:, :-1] = inside[:, 1:]
    light = inside & ~(up & left)
    dark = inside & ~(down & right) & ~light
    LIGHT, DARK = 253, 254
    for y in range(g.h):
        for x in range(g.w):
            if not inside[y, x]:
                continue
            if light[y, x]:
                g.index[y, x] = LIGHT
                continue
            if dark[y, x]:
                g.index[y, x] = DARK
                continue
            t = gradient_t(x, y, g.w, g.h)
            low = (y / g.h) > 0.58
            if cw[y, x] >= 0.5:
                g.index[y, x] = 1 + int(t * 64) % 64 + (64 if low else 0)
            else:
                g.index[y, x] = 129 + int(t * 48) % 48 + (48 if low else 0)
    g.split = int(np.where(cw.max(axis=0) >= 0.5)[0][-1]) + 3
    g.duration = 70
    word_ramp = tinted(ramp(64))
    still = word_ramp + [shaded(c, 0.72) for c in word_ramp]
    g.palette_frames(still=still, cycle_base=129, cycle_ramp=ramp(48), shadow_keep=0.72, step=2,
                     bevel=[PLUM] * (253 - 129 - 96) + [PAPER, shaded(CYAN, 0.35)])
    return g


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    SITE.mkdir(parents=True, exist_ok=True)
    for build in (gen1, gen2, gen3):
        g = build()
        g.write()
        print(f"{g.name}: {g.w}x{g.h}, {len(g.frames)} frames, cycling entries {g.cycle[0]}..{g.cycle[1] - 1}")


if __name__ == "__main__":
    main()
