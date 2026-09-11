#!/usr/bin/env python3
"""Validate the dependency-free public site before preparing a Pages artifact."""

from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
PUBLIC_FILES = {"index.html", "styles.css", "showcase.js", "favicon.svg"}


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
        if path.is_symlink() or not path.is_file():
            errors.append(f"Unreviewed directory or symlink: {path.relative_to(SITE)}")
    if errors:
        return errors

    texts = {name: (SITE / name).read_text(encoding="utf-8") for name in PUBLIC_FILES}
    for name, text in texts.items():
        if re.search(r"localhost|127\.0\.0\.1|/Users/|/home/|\.shift/|\.env\b", text):
            errors.append(f"Local/private reference in public file: {name}")
    page = Page()
    page.feed(texts["index.html"])
    errors.extend(page.errors)
    if page.headings != 1:
        errors.append("The page must have exactly one h1.")
    for ref in page.references:
        if ref not in page.ids:
            errors.append(f"Missing HTML control/label target: {ref}")

    for tag, link in page.links:
        url = urlsplit(link)
        if url.scheme or url.netloc:
            if tag != "a" or url.scheme != "https" or url.hostname != "github.com":
                errors.append(f"Nonlocal asset or unexpected external link: {link}")
                continue
            prefix = "/thrashr888/shift/blob/main/"
            if url.path.startswith(prefix):
                path = ROOT / unquote(url.path.removeprefix(prefix))
                if not path.is_file() or not path.resolve().is_relative_to(ROOT):
                    errors.append(f"Repository documentation target missing: {link}")
            continue
        if url.path.startswith("/") or ".." in Path(unquote(url.path)).parts:
            errors.append(f"URL does not preserve the project-site base path: {link}")
        elif url.path and url.path != "./" and url.path.removeprefix("./") not in PUBLIC_FILES:
            errors.append(f"Missing local asset: {link}")
        if url.fragment and url.fragment not in page.ids:
            errors.append(f"Missing in-page anchor: {link}")

    if re.search(r"@import\b|url\s*\(", texts["styles.css"], re.IGNORECASE):
        errors.append("CSS must not load unreviewed assets.")
    if re.search(r"\b(fetch|XMLHttpRequest|WebSocket|EventSource|sendBeacon)\b", texts["showcase.js"]):
        errors.append("The local-only simulation must not make network requests.")
    return errors


if __name__ == "__main__":
    failures = check()
    if failures:
        for failure in failures:
            print(f"site: {failure}", file=sys.stderr)
        sys.exit(1)
    print("Site checks passed: four public files, relative assets, valid anchors, local-only demo.")
