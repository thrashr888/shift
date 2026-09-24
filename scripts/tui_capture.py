#!/usr/bin/env python3
"""Capture the real terminal interface, one PNG per built-in theme.

    scripts/tui_capture.py OUT_DIR [--cols 140 --rows 44] [--scale 2] [themes...]

The interface runs in a pseudo-terminal with the demo model, so nothing
leaves the machine. After one demo exchange, each theme is selected with
/theme and the screen is drawn cell by cell from the terminal's own state
(pyte), including the palette the theme redefines through OSC 4. Needs pyte
and Pillow; a virtualenv with both does.

pyte lacks CSI S and CSI T, which curses uses to scroll. Without the two
handlers below a scrolled transcript renders with stale rows.
"""
import codecs
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

import pyte
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from tui import ansi_rgb  # noqa: E402

NAMED = dict(black="000000", red="cd0000", green="00cd00", brown="cdcd00", blue="0000ee", magenta="cd00cd",
             cyan="00cdcd", white="e5e5e5", brightblack="7f7f7f", brightred="ff0000", brightgreen="00ff00",
             brightbrown="ffff00", brightblue="5c5cff", brightmagenta="ff00ff", brightcyan="00ffff", brightwhite="ffffff")
BOX = {"─": "lr", "│": "ud", "┌": "rd", "┐": "ld", "└": "ru", "┘": "lu", "├": "urd", "┤": "uld", "┬": "lrd", "┴": "lru", "┼": "lrud",
       "═": "lr", "║": "ud", "╔": "rd", "╗": "ld", "╚": "ru", "╝": "lu", "╠": "urd", "╣": "uld", "╦": "lrd", "╩": "lru", "╬": "lrud"}


class Screen(pyte.Screen):
    def set_margins(self, *args, private=False):
        if not private:                     # pyte mistakes DEC private restores for margins
            return super().set_margins(*args)

    def scroll_up(self, count=1):           # CSI S
        for _ in range(count or 1):
            self.index()

    def scroll_down(self, count=1):         # CSI T
        for _ in range(count or 1):
            self.reverse_index()


class Capture:
    def __init__(self, cols, rows, scale):
        self.cols, self.rows, self.scale = cols, rows, scale
        self.cell = (10 * scale, 20 * scale)
        self.font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 15 * scale)
        self.bold = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 15 * scale, index=1)
        pyte.Stream.csi["S"] = "scroll_up"
        pyte.Stream.csi["T"] = "scroll_down"
        self.screen = Screen(cols, rows)
        self.stream = pyte.Stream(self.screen)
        self.stream.use_utf8 = False
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.raw = bytearray()

    def start(self, tmp):
        self.master, slave = pty.openpty()
        os.set_blocking(self.master, False)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", self.rows, self.cols, 0, 0))
        args = [str(ROOT / "bin/shift-agent"), "--session", "capture", "--no-watch", "--no-mcp",
                "--state-dir", tmp + "/state", "--set", 'agent-model="demo"']
        self.process = subprocess.Popen(
            args, cwd=ROOT, stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
            env={**os.environ, "TERM": "xterm-256color", "XDG_CONFIG_HOME": tmp + "/config",
                 "SHIFT_PLUGINS": "off", "USER": "you"})
        self.wait_for("READY")

    def drain(self, seconds=0.3):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if select.select([self.master], [], [], 0.03)[0]:
                try:
                    chunk = os.read(self.master, 65536)
                except (BlockingIOError, OSError):
                    continue
                self.raw.extend(chunk)
                self.stream.feed(self.decoder.decode(chunk))

    def send(self, text):
        data = text.encode()
        while data:
            try:
                n = os.write(self.master, data)
            except BlockingIOError:
                self.drain(0.05)
                continue
            data = data[n:]
        self.drain()

    def wait_for(self, needle, seconds=15):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            self.drain(0.1)
            if needle in "\n".join(self.screen.display):
                return
            if self.process.poll() is not None:
                break
        raise SystemExit("did not see %r:\n%s" % (needle, "\n".join(self.screen.display)))

    def palette(self):
        table = {}
        for index, *channels in re.findall(rb"\x1b\]4;(\d+);rgb:([0-9A-Fa-f]+)/([0-9A-Fa-f]+)/([0-9A-Fa-f]+)(?:\x1b\\|\x07)", bytes(self.raw)):
            index = int(index)
            if index >= 16:
                old = "".join("%02x" % c for c in ansi_rgb(index))
                table[old] = "".join("%02x" % round(int(c, 16) * 255 / (16 ** len(c) - 1)) for c in channels)
        return table

    def render(self, path):
        pal = self.palette()
        cw, ch = self.cell
        pad = 12 * self.scale

        def color(value, default):
            value = NAMED.get(value, default if value == "default" else value)
            return "#" + pal.get(value, value)

        screen = self.screen
        image = Image.new("RGB", (screen.columns * cw + 2 * pad, screen.lines * ch + 2 * pad), color(screen.buffer[0][0].bg, "000000"))
        draw = ImageDraw.Draw(image)
        for y in range(screen.lines):
            for x in range(screen.columns):
                c = screen.buffer[y][x]
                fg, bg = color(c.fg, "e5e5e5"), color(c.bg, "000000")
                if c.reverse:
                    fg, bg = bg, fg
                x0, y0 = pad + x * cw, pad + y * ch
                draw.rectangle((x0, y0, x0 + cw - 1, y0 + ch - 1), fill=bg)
                if c.data in BOX:
                    cx, cy = x0 + cw // 2, y0 + ch // 2
                    offsets = (-self.scale, self.scale) if c.data in "═║╔╗╚╝╠╣╦╩╬" else (0,)
                    for o in offsets:
                        for d in BOX[c.data]:
                            end = {"l": (x0, cy + o), "r": (x0 + cw, cy + o), "u": (cx + o, y0), "d": (cx + o, y0 + ch)}[d]
                            start = (cx, cy + o) if d in "lr" else (cx + o, cy)
                            draw.line((start, end), fill=fg, width=self.scale)
                elif c.data in ("█", "▀", "▄", "▉", "▌", "▐", "░", "▒", "▓"):
                    top = ch // 2 if c.data == "▄" else 0
                    bottom = ch // 2 - 1 if c.data == "▀" else ch - 1
                    left, right = 0, cw - 1
                    if c.data == "▌": right = cw // 2 - 1
                    if c.data == "▐": left = cw // 2
                    if c.data in "░▒▓":
                        fill = {"░": 0.25, "▒": 0.5, "▓": 0.75}[c.data]
                        f = tuple(int(int(fg[i:i + 2], 16) * fill + int(bg[i:i + 2], 16) * (1 - fill)) for i in (1, 3, 5))
                        draw.rectangle((x0, y0, x0 + cw - 1, y0 + ch - 1), fill=f)
                    else:
                        draw.rectangle((x0 + left, y0 + top, x0 + right, y0 + bottom), fill=fg)
                elif c.data.strip():
                    draw.text((x0, y0 - 2 * self.scale), c.data, fill=fg, font=self.bold if c.bold else self.font)
        image.save(path, optimize=True)
        return image.size

    def stop(self):
        try:
            self.process.send_signal(signal.SIGTERM)
            self.process.wait(5)
        except Exception:
            self.process.kill()


def main(argv):
    out = Path(argv[0]); out.mkdir(parents=True, exist_ok=True)
    opts = {"--cols": 140, "--rows": 44, "--scale": 2}
    themes = []
    i = 1
    while i < len(argv):
        if argv[i] in opts:
            opts[argv[i]] = int(argv[i + 1]); i += 2
        else:
            themes.append(argv[i]); i += 1
    themes = themes or ["acid", "paddock", "blueprint", "qdos"]
    cap = Capture(opts["--cols"], opts["--rows"], opts["--scale"])
    with tempfile.TemporaryDirectory(prefix="shift-capture-") as tmp:
        cap.start(tmp)
        cap.send("What should I work on next?\n")
        cap.wait_for("READY")
        cap.drain(0.5)
        for theme in themes:
            cap.send("/theme %s\n" % theme)
            cap.drain(0.8)
            size = cap.render(out / ("%s.png" % theme))
            print(theme, size, (out / ("%s.png" % theme)).stat().st_size // 1024, "KB")
        cap.stop()


if __name__ == "__main__":
    main(sys.argv[1:])
