#!/usr/bin/env python3
"""Validate the dependency-free public site before preparing a Pages artifact."""

from html.parser import HTMLParser
from pathlib import Path
import posixpath
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
GHOSTTY_THEMES = {"ghostty/shift-" + name for name in ("acid", "paddock", "blueprint", "qdos")}
SCREENSHOTS = {"assets/" + name for name in ("fanout-log.png", "fanout-sessions.png", "recall.png")} | {
    "assets/themes/%s.png" % name for name in ("acid", "paddock", "blueprint", "qdos")}   # scripts/tui_capture.py
FONTS = {"assets/fonts/" + name for name in ("ibm-cga.woff", "ibm-ega.woff", "ibm-vga.woff", "plex-sans.woff2", "plex-mono-400.woff2", "plex-mono-600.woff2")}
DOCS = {"docs/" + name for name in ("index.html", "install.html", "workflows.html")}
# The font pack's home, credited in the footer.
EXTERNAL_LINKS = {"https://int10h.org/oldschool-pc-fonts/"}
# The lab: brand prototypes (docs/brand.md), plain files like the rest of the site, linked from nowhere yet.
LAB_PAGES = {"lab/" + name for name in ("dither-depth.html", "palette.html", "generations.html", "tokens.css", "cycle.js")} | {
    "assets/lab/gen%d.json" % n for n in (1, 2, 3)}
LAB_IMAGES = {"assets/lab/" + name for name in ("tui-acid.png", "wordmark-dither.png", "wordmark-iridescent.png", "wordmark-pixel.png")} | {
    "assets/lab/" + pattern % n for n in (1, 2, 3)
    for pattern in ("gen%d.idx.png", "wordmark-gen%d.gif", "wordmark-gen%d.png", "mark-gen%d.gif", "word-gen%d.png")}
BINARY = SCREENSHOTS | LAB_IMAGES | FONTS
PUBLIC_FILES = {"index.html", "panes.html", "styles.css", "hero.js", "dither.js", "favicon.svg"} | DOCS | GHOSTTY_THEMES | SCREENSHOTS | FONTS | LAB_PAGES | LAB_IMAGES
PAGES = ("index.html", "panes.html") + tuple(sorted(DOCS))
PUBLIC_DIRS = {str(Path(name).parent) for name in PUBLIC_FILES} - {"."}


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.links = []
        self.references = []
        self.errors = []
        self.headings = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            if attrs["id"] in self.ids:
                self.errors.append(f"Duplicate HTML id: {attrs['id']}")
            self.ids.add(attrs["id"])
        if tag == "h1":
            self.headings += 1
        for key in ("aria-controls", "aria-describedby", "aria-labelledby", "for"):
            self.references.extend(attrs.get(key, "").split())
        for key in ("href", "src"):
            if key in attrs:
                self.links.append((tag, attrs[key]))
        if tag == "script" and "src" not in attrs:
            self.errors.append("Keep JavaScript in the reviewed local asset.")
        if any(key.startswith("on") for key in attrs):
            self.errors.append(f"Inline event handler on {tag}")


def check():
    errors = []
    if SITE.is_symlink() or not SITE.is_dir():
        return ["site/ must be a real directory, not a symlink."]
    entries = list(SITE.rglob("*"))
    files = {str(path.relative_to(SITE)) for path in entries if path.is_file()}
    if files != PUBLIC_FILES:
        errors.append(
            f"Public file allowlist mismatch: missing={PUBLIC_FILES - files}, "
            f"unexpected={files - PUBLIC_FILES}"
        )
    for path in entries:
        if path.is_symlink() or not (path.is_file() or str(path.relative_to(SITE)) in PUBLIC_DIRS):
            errors.append(f"Unreviewed directory or symlink: {path.relative_to(SITE)}")
    if errors:
        return errors

    texts = {name: (SITE / name).read_text(encoding="utf-8") for name in PUBLIC_FILES - BINARY}
    for name in SCREENSHOTS:
        if (SITE / name).stat().st_size > 900_000:
            errors.append(f"Screenshot over 900 KB: {name}")
    for name, text in texts.items():
        # The documented MCP endpoint and the workflow folder are public names, not leaks.
        if re.search(r"localhost|127\.0\.0\.1(?!:7331/mcp)|/Users/|/home/|\.env\b", text):
            errors.append(f"Local/private reference in public file: {name}")
    pages = {}
    for name in PAGES:
        page = Page()
        page.feed(texts[name])
        pages[name] = page
        errors.extend(f"{name}: {error}" for error in page.errors)
        if page.headings != 1:
            errors.append(f"{name} must have exactly one h1.")
        for ref in page.references:
            if ref not in page.ids:
                errors.append(f"{name}: missing HTML control/label target: {ref}")

    for name, page in pages.items():
        for tag, link in page.links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                if tag == "a" and link in EXTERNAL_LINKS:
                    continue
                if tag != "a" or url.scheme != "https" or url.hostname != "github.com":
                    errors.append(f"{name}: nonlocal asset or unexpected external link: {link}")
                    continue
                prefix = "/thrashr888/shift/blob/main/"
                if url.path.startswith(prefix):
                    path = ROOT / unquote(url.path.removeprefix(prefix))
                    if not path.is_file() or not path.resolve().is_relative_to(ROOT):
                        errors.append(f"{name}: repository documentation target missing: {link}")
                continue
            # A relative link resolves against its page; it may climb out of docs/ but never out of site/.
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), unquote(url.path))) if url.path else ""
            if url.path.endswith("/") or target == ".":
                target = posixpath.normpath(posixpath.join(target, "index.html"))
            if url.path.startswith("/") or target.startswith(".."):
                errors.append(f"{name}: URL does not preserve the project-site base path: {link}")
            elif target and target not in PUBLIC_FILES:
                errors.append(f"{name}: missing local asset: {link}")
            if url.fragment:
                # Links across pages ("./#panes") resolve against the target page.
                ids = pages[target or name].ids if (target or name) in pages else set()
                if url.fragment not in ids:
                    errors.append(f"{name}: missing anchor: {link}")

    # The published field list is the one ui.scm validates.
    ui = (ROOT / "src/live-agent/ui.scm").read_text(encoding="utf-8")
    block = re.search(r"\(define pane-fields '\((.*?)\)\)", ui, re.DOTALL)
    declared = re.findall(r'"([a-z_.]+)"', block.group(1)) if block else []
    published = re.findall(r"<tr><td>([a-z_.]+)</td>", texts["panes.html"])
    sources_block = re.search(r"\(define pane-sources '\((.*?)\)\)", ui, re.DOTALL)
    declared_sources = re.findall(r'"([a-z]+)"', sources_block.group(1)) if sources_block else []
    if declared + declared_sources != published:
        errors.append(f"panes.html fields or sources drift from ui.scm: declared={declared + declared_sources}, published={published}")

    # The only url() the stylesheet may carry is a self-hosted font from the allowlist.
    css = re.sub(r"url\(\./(assets/fonts/[a-z0-9-]+\.woff2?)\)", lambda m: "" if m.group(1) in FONTS else m.group(0), texts["styles.css"])
    if re.search(r"@import\b|url\s*\(", css, re.IGNORECASE):
        errors.append("CSS must not load unreviewed assets.")
    for name in ("hero.js", "dither.js"):
        if re.search(r"\b(fetch|XMLHttpRequest|WebSocket|EventSource|sendBeacon)\b", texts[name]):
            errors.append(f"{name} must not make network requests.")
    generated = subprocess.run(
        [sys.executable, str(ROOT / "scripts/ghostty_themes.py"), "--check"], capture_output=True, text=True
    )
    if generated.returncode != 0:
        errors.append(generated.stderr.strip() or "Ghostty themes are out of date.")
    return errors


if __name__ == "__main__":
    failures = check()
    if failures:
        for failure in failures:
            print(f"site: {failure}", file=sys.stderr)
        sys.exit(1)
    print("Site checks passed: allowlisted public files, relative assets, valid anchors, local-only demo, current Ghostty themes, current pane fields.")
