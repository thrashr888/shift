#!/usr/bin/env python3
"""Show a generation mark in the terminal, palette-cycled, two ways.

    scripts/tui_bitmap.py [gen1|gen2|gen3] [--kitty] [--seconds N]

Halfblocks (the default) paint two rows of the index map per text row with
the upper-half-block glyph, foreground for the top cell and background for the
bottom, in truecolor. It works in any terminal that speaks 24-bit color, and
it is what the curses TUI can do as it is. --kitty sends the frames as RGBA
through the Kitty graphics protocol instead (Ghostty, Kitty, WezTerm), which
draws the real pixels. Both cycle the palette by repainting; the index map is
read once. Ctrl-C ends it.
"""
import base64
import json
import sys
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    meta = json.loads((ROOT / "docs/assets/brand" / f"{name}.json").read_text())
    raw = (ROOT / "docs/assets/brand" / meta["index"]).read_bytes()
    return meta, png_gray(raw)


def png_gray(data):
    """The index map is a grayscale PNG; decode it without Pillow so this runs from a bare checkout."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, chunks, width, height = 8, [], 0, 0
    while pos < len(data):
        length = int.from_bytes(data[pos:pos + 4], "big"); kind = data[pos + 4:pos + 8]; body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height = int.from_bytes(body[:4], "big"), int.from_bytes(body[4:8], "big")
            assert body[8] == 8 and body[9] == 0, "expected an 8-bit grayscale index map"
        elif kind == b"IDAT":
            chunks.append(body)
        pos += 12 + length
    stream = zlib.decompress(b"".join(chunks)); rows, prev, i = [], bytes(width), 0
    for _ in range(height):
        filt, line = stream[i], bytearray(stream[i + 1:i + 1 + width]); i += 1 + width
        for x in range(width):
            a = line[x - 1] if x else 0; b = prev[x]; c = prev[x - 1] if x else 0
            if filt == 1: line[x] = (line[x] + a) & 255
            elif filt == 2: line[x] = (line[x] + b) & 255
            elif filt == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif filt == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line)); prev = rows[-1]
    return width, height, rows


def halfblocks(meta, index, frame):
    width, height, rows = index; pal = meta["frames"][frame]; out = []
    for y in range(0, height, 2):
        top, bottom, line = rows[y], rows[y + 1] if y + 1 < height else bytes(width), []
        for x in range(width):
            f, b = pal[top[x]] if top[x] < len(pal) else pal[0], pal[bottom[x]] if bottom[x] < len(pal) else pal[0]
            line.append(f"\x1b[38;2;{f[0]};{f[1]};{f[2]}m\x1b[48;2;{b[0]};{b[1]};{b[2]}m▀")
        out.append("".join(line) + "\x1b[0m")
    return "\n".join(out)


def kitty_frame(meta, index, frame, image_id=77):
    width, height, rows = index; pal = meta["frames"][frame]
    rgba = bytearray()
    for row in rows:
        for v in row:
            c = pal[v] if v < len(pal) else pal[0]; rgba += bytes((c[0], c[1], c[2], 255))
    payload = base64.b64encode(zlib.compress(bytes(rgba))).decode()
    chunks = [payload[i:i + 4096] for i in range(0, len(payload), 4096)]
    out = []
    for n, chunk in enumerate(chunks):
        head = f"a=T,f=32,o=z,s={width},v={height},i={image_id},q=2" if n == 0 else "q=2"
        out.append(f"\x1b_G{head},m={0 if n == len(chunks) - 1 else 1};{chunk}\x1b\\")
    return "".join(out)


def main(argv):
    name = next((a for a in argv if a.startswith("gen")), "gen1")
    kitty = "--kitty" in argv
    seconds = float(argv[argv.index("--seconds") + 1]) if "--seconds" in argv else 8.0
    meta, index = load(name)
    frames, period = len(meta["frames"]), 0.24 if name == "gen1" else 0.11 if name == "gen2" else 0.07
    rows = (index[1] + 1) // 2
    sys.stdout.write("\x1b[?25l")
    try:
        end = time.time() + seconds; frame = 0
        while time.time() < end:
            if kitty:
                sys.stdout.write(kitty_frame(meta, index, frame))
            else:
                sys.stdout.write(halfblocks(meta, index, frame) + f"\x1b[{rows - 1}A\r")
            sys.stdout.flush(); time.sleep(period); frame = (frame + 1) % frames
    except KeyboardInterrupt:
        pass
    finally:
        if not kitty: sys.stdout.write("\n" * rows)
        sys.stdout.write("\x1b[?25h\x1b[0m\n"); sys.stdout.flush()


if __name__ == "__main__":
    main(sys.argv[1:])
