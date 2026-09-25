#!/usr/bin/env python3
"""Build the documentation pages of the site from fragments in docs/site/.

    scripts/site_docs.py            writes site/docs/*.html
    scripts/site_docs.py --check    fails when a page differs from its fragment

Each fragment is the body of one page: an HTML comment of metadata, then the
content from <h1> on. The rail, the header, the footer and the previous and
next links come from the page order below, so every page agrees about what
exists. There is still no build step for the site: the pages are committed,
and the checker confirms they match.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs/site"
OUT = ROOT / "site/docs"
GH = "https://github.com/thrashr888/shift/blob/main/docs/daily-driver.md"
# The rail: group, then (title, local file or None, external href when not local).
RAIL = [
    ("Start", [("Install and first session", "install.html"), ("Providers and keys", "providers.html"), ("The terminal", "terminal.html")]),
    ("Use", [("Modes and policy", "policy.html"), ("Receipts and sessions", "sessions.html"), ("Workflows", "workflows.html"),
             ("Skills and notes", "skills.html"), ("Subagents", "subagents.html")]),
    ("Change", [("The agent file", "agent-file.html"), ("Pane packs", "panes.html"), ("Attach a desktop agent", "mcp.html")]),
    ("Benchmarks", [("Benchmarks", "benchmarks.html"), ("The judge", "judge.html")]),
]
ORDER = [(title, href) for _, pages in RAIL for title, href in pages]
PAGES = ["index.html"] + [href for _, href in ORDER]


def meta(text):
    m = re.match(r"\s*<!--(.*?)-->", text, re.DOTALL)
    fields = dict(re.findall(r"(\w+):\s*(.*)", m.group(1))) if m else {}
    body = text[m.end():].strip() if m else text.strip()
    return fields, body


def rail(current):
    # A details element: open, and inert, on wide screens; a toggle on narrow ones (docs.js closes it on a narrow screen).
    out = ['    <details class="rail" open aria-label="Documentation pages">', "      <summary>All pages</summary>", '      <nav class="rail-pages">']
    for group, pages in RAIL:
        out.append(f"        <div><h2>{group}</h2>")
        for title, href in pages:
            cur = ' aria-current="page"' if href == current else ""
            out.append(f'          <a href="{href}"{cur}>{title}</a>')
        out.append("        </div>")
    out.append("      </nav>")
    out.append("    </details>")
    return "\n".join(out)


def neighbours(name):
    names = [href for _, href in ORDER]
    if name not in names:
        return None, None
    i = names.index(name)
    prev = ORDER[i - 1] if i > 0 else None
    nxt = ORDER[i + 1] if i + 1 < len(ORDER) else None
    return prev, nxt


def page(name, fields, body):
    title = fields.get("title", "Documentation")
    crumbs = "Docs" if name == "index.html" else f'<a href="./index.html">Docs</a> &gt; {fields.get("group", "")}'
    prev, nxt = neighbours(name)
    nav = ""
    if prev or nxt:
        left = f'<a href="{prev[1]}"><span aria-hidden="true">◀</span> {prev[0]}</a>' if prev else "<span></span>"
        right = f'<a href="{nxt[1]}">{nxt[0]} <span aria-hidden="true">▶</span></a>' if nxt else "<span></span>"
        nav = f'\n      <nav class="doc-nav" aria-label="Neighbouring pages">{left}{right}</nav>'
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="theme-color" content="#18071e">
  <meta name="description" content="{fields.get('description', '')}">
  <title>{title} · Shift docs</title>
  <link rel="icon" href="../favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="../styles.css">
  <script src="../lab/cycle.js" defer></script>
  <script src="../docs.js" defer></script>
</head>
<body>
  <a class="skip-link" href="#main">Skip to content</a>
  <header class="site-header wrap">
    <a class="wordmark" href="../index.html" aria-label="Shift home">
      <canvas data-mark="../assets/lab/gen3.json" data-period="70" width="640" height="200" aria-hidden="true"></canvas>
      <span class="visually-hidden">shift ///</span>
    </a>
    <nav aria-label="Main navigation">
      <a href="../index.html#policy">Policy</a>
      <a href="../index.html#workflows">Workflows</a>
      <a href="../index.html#benchmarks">Benchmarks</a>
      <a href="./index.html">Docs</a>
      <a href="https://github.com/thrashr888/shift">GitHub <span aria-hidden="true">↗</span></a>
    </nav>
  </header>
  <main id="main" class="docs wrap">
{rail(name)}
    <article class="doc">
      <p class="crumbs">{crumbs}</p>
{body}{nav}
    </article>
  </main>
  <footer class="site-footer wrap">
    <p>shift /// · Guile and your terminal</p>
    <nav aria-label="Footer navigation"><a href="https://github.com/thrashr888/shift">Source</a><a href="./index.html">Documentation</a><a href="https://github.com/thrashr888/shift/blob/main/LICENSE">License</a></nav>
  </footer>
</body>
</html>
"""


def build():
    pages = {}
    for name in PAGES:
        source = SOURCE / name
        if not source.is_file():
            raise SystemExit(f"missing fragment: {source}")
        fields, body = meta(source.read_text(encoding="utf-8"))
        pages[name] = page(name, fields, body)
    return pages


def main(argv):
    pages = build()
    if "--check" in argv:
        stale = [name for name, text in pages.items() if not (OUT / name).is_file() or (OUT / name).read_text(encoding="utf-8") != text]
        extra = sorted(p.name for p in OUT.glob("*.html") if p.name not in pages)
        if stale or extra:
            print(f"site/docs is out of date: stale={stale} extra={extra}; run scripts/site_docs.py", file=sys.stderr)
            return 1
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for name, text in pages.items():
        (OUT / name).write_text(text, encoding="utf-8")
    print(f"wrote {len(pages)} pages to {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
