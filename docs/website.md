# Shift website

The site lives in `site/`: plain HTML, CSS and two small local scripts. There is
no package install, no build step, no analytics, no request that leaves the page
(the fonts are self-hosted under `assets/fonts/`), and no model connection.
Every capture on the page is real: the interface, run through a pseudo-terminal
with the demo model by `scripts/tui_capture.py`, or a session against a local
model. `docs/brand.md` is the brand it follows; the copy follows the register
rules in the writing guide it names.

## The hero

The hero is three screens, one visible at a time, each honest to a generation of
the mark: four colors and the terminal face, sixteen colors and a pixel face,
then the full palette and the reading faces. Continue, the arrow keys, the digits
1 to 3 and a `#screen-N` link move between them (`hero.js`); without JavaScript
the three stack. The first screen's visual is the acid capture dithered into
points with depth from local contrast, drawn as WebGL point sprites that tilt
with the cursor and carry the glitch field (`dither.js`); reduced motion draws
it still, and a browser without WebGL gets the plain image. The header mark is a
canvas per generation drawn from `assets/lab/genN.idx.png` and its palette file
by `lab/cycle.js`, which rotates only the slashes' entries, briefly on arrival
and on hover, never under reduced motion. The second screen shows the sessions
capture; the third shows a capture of each built-in theme.

## Below the hero

A section nav, then one section per claim, each a heading column beside a proof
column: policy, workflows, the MCP endpoint for other agents, the measured table
(only benchmarks that have run, with their dates), make it yours (the Ghostty
themes, the pane pack, the interface commands) and start. The start block sits on
the sixteen-color ramp under a dot screen. The earlier site's simulated terminal
and its site-wide theme and display-name controls are gone: the brand rule is
that nothing on the page is illustrative.

## Ghostty themes

`site/ghostty/shift-NAME` is a Ghostty theme for each bundled Shift pack, listed
in the site's "Take the colors with you" section with download links and an
install snippet. `scripts/ghostty_themes.py` generates them from `themes/*.scm`:
background, foreground, cursor, selection and the pack's semantic colors are
pack values, and the remaining ANSI slots are complementary picks declared in
the generator. Run it after changing a pack; `--check` (also run by
`check_site.py` and `test/ghostty_theme_test.py`) fails when the published
files drift. Users copy a file into `~/.config/ghostty/themes/` and set
`theme = shift-NAME`. The site's card swatches repeat the file's colors.

## Pane pack reference

`site/panes.html` is the published reference for `.shift/panes.scm`: the
grammar, the field list, how commands run and how packs load. The index's
"Bring your own panes" section links to it. The field table must match
`pane-fields` in `src/live-agent/ui.scm`; `check_site.py` fails when they
drift, and it allows the literal `.shift/panes.scm` path while still rejecting
other state-directory references. Keep the example on both pages in step with
this repository's own `.shift/panes.scm`.

## Check and preview

```sh
python3 scripts/check_site.py
python3 -m http.server 8767 --bind 127.0.0.1 --directory site
```

Open `http://127.0.0.1:8767/`. This serves only the public site directory, not
the repository, credentials, or local session state. Stop it with Ctrl+C.

Before publishing, exercise the native controls at desktop and mobile widths.
Check whole-page theme changes, custom names, reset/undo, unchanged real commands
and links, hidden/right/bottom inspector layouts, keyboard focus, and the
simulated work toggle. Include 320px widths and long or HTML-like names.
A right inspector stacks below
the conversation on small screens; the control labels this adaptation.

The three slash cells stay fixed in width. CSS cycles their opacity while
simulated work is active; JavaScript only changes state. IntersectionObserver
pauses cycling offscreen, and background tabs pause it too. Reduced-motion
preferences disable animation even if the motion checkbox was previously on.
The WORKING label remains visible. There are no third-party scripts or fonts.

## Publish deliberately

The public site is hosted at <https://thrashr888.github.io/shift/> using GitHub
Pages with GitHub Actions as its source (`.github/workflows/test.yml` runs
`make test` on Ubuntu for every push; publishing is a separate manual workflow). Deployments are manual, not triggered
by pushes or pull requests.

The quickstart uses the launcher on `main`, which opens the curses interface by
default in an interactive terminal. Keep the site copy in step with the
published launcher; the command is `shift-agent`.

After explicit approval to publish:

1. Review and commit the site, checker, documentation, and workflow; merge them
   into `main` and push. The workflow needs to be on the default branch for
   GitHub to expose its manual run button.
2. Confirm repository **Settings → Pages → Build and deployment** uses
   **GitHub Actions** as the source. The `github-pages` environment should
   restrict deployments to `main`; retain any required reviewer protections.
3. In **Actions → Publish Shift website → Run workflow**, select `main`.
   No push or pull request automatically deploys this initial site.
4. After successful deployment, visit `https://thrashr888.github.io/shift/`
   and verify the site’s controls, asset loads, and documentation links.

The preparation job has only repository read permission and uploads **only
`site/`**. The deployment job has `pages: write` and `id-token: write` for the
official GitHub Pages deployment action. It does not enable Pages automatically.
Assets use relative URLs (`./styles.css`, etc.), so the project-site `/shift/`
prefix works without a bundler or base-URL rewrite. Documentation links point
to the real repository; this is a showcase, not a separately built docs portal.

`scripts/check_site.py` checks the exact public-file allowlist, rejects symlinks
and nonlocal assets, and checks internal targets. Add new public assets to its
allowlist deliberately; the three `site/assets/*.png` screenshots (subagent
fan-out and recall) are listed there and capped at 900 KB each. Never put
`.env`, `.shift/`, logs, credentials, or unreviewed generated output under `site/`.
