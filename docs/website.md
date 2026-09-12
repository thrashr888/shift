# Shift website

The branding/showcase site lives in `site/`: plain HTML, CSS, and local JavaScript.
There is no package install or build step, no analytics, and no model connection.
The terminal is explicitly simulated. Site appearance controls above the hero
apply theme and display identity to the whole page, including the terminal.
Acid Garage keeps the original neutral shell and purple terminal; Paddock and
Blueprint apply their existing palettes throughout. Controls, focus rings, text,
cards, and the browser theme color use the same theme selection.

QDOS follows the [QDOS specification](https://github.com/thrashr888/QDOS/blob/master/spec/SPEC.md):
black canvas, white text/frames, cyan panel labels (`#66b7b3`), green contextual
help (`#67cc4d`), and yellow-on-red selections (`#e8da59` / `#9d1f14`).
Compact monospace menus, double frames, and denser sections suggest its DOS
layout without a fixed 80-column screen or fake DOS commands. Links and form
controls remain native and keyboard-accessible; the menu wraps on narrow screens.

Applying a display name updates the header, hero identity, footer, browser title,
and simulated terminal branding. Actual Shift product references, source credits,
repository/docs links, executable names, and copyable commands never change.
Names render as text, not HTML, and are limited to 24 printable characters.
Long wordmarks truncate visually without pushing navigation offscreen.

One in-memory configuration and undo stack cover appearance and demo placement.
**Reset appearance** restores the original Shift name and Acid Garage palette;
it leaves demo layout and work state alone and is itself undoable. Inspector
placement and simulated work/motion remain clearly labeled demo-only controls.
Reloading clears customization; there is no storage, tracking, or backend.
Colors come from the existing live interface study;
the source prototype and terminal implementation are not part of the website.

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
Pages with GitHub Actions as its source. Deployments are manual, not triggered
by pushes or pull requests.

The quickstart uses the launcher on `main`, which opens the curses interface by
default in an interactive terminal; `--tui` remains a compatibility alias. Keep
the site copy in step with the published launcher.

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
allowlist deliberately. Never put `.env`, `.shift/`, logs, credentials, or
unreviewed generated output under `site/`.
