"""Generated Ghostty themes stay valid, complete, and in step with the packs and site."""
import importlib.util
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ghostty_themes", ROOT / "scripts/ghostty_themes.py")
ghostty = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ghostty)
HEX = re.compile(r"^#[0-9a-f]{6}$")


class GhosttyThemes(unittest.TestCase):
    def theme(self, name):
        text = (ROOT / "site/ghostty" / ("shift-" + name)).read_text(encoding="utf-8")
        entries = {}
        palette = {}
        for line in text.splitlines():
            if not line or line.startswith("#"):
                continue
            key, _, value = (part.strip() for part in line.partition("="))
            if key == "palette":
                slot, _, color = value.partition("=")
                self.assertNotIn(int(slot), palette, line)
                palette[int(slot)] = color
            else:
                self.assertNotIn(key, entries, line)
                entries[key] = value
        return entries, palette

    def test_generated_files_match_packs_and_are_complete(self):
        check = subprocess.run([sys.executable, str(ROOT / "scripts/ghostty_themes.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(check.returncode, 0, check.stderr)
        for name in ghostty.NAMES:
            entries, palette = self.theme(name)
            self.assertEqual(sorted(palette), list(range(16)), name)
            self.assertEqual(set(entries), {"background", "foreground", "cursor-color", "cursor-text",
                                            "selection-background", "selection-foreground"}, name)
            for color in list(palette.values()) + list(entries.values()):
                self.assertRegex(color, HEX)
            pack = ghostty.pack_colors(name)
            self.assertEqual(entries["background"], pack["background"], name)
            self.assertEqual(entries["foreground"], pack["foreground"], name)
            self.assertEqual(entries["cursor-text"], pack["background"], name)
            self.assertNotEqual(entries["selection-background"], entries["selection-foreground"], name)
            self.assertEqual(len(set(palette[slot] for slot in range(8))), 8, name + " normal colors must differ")

    def test_site_links_and_swatches_use_the_published_files(self):
        html = (ROOT / "site/index.html").read_text(encoding="utf-8")
        css = (ROOT / "site/styles.css").read_text(encoding="utf-8")
        for name in ghostty.NAMES:
            self.assertIn(f'href="./ghostty/shift-{name}" download', html)
            entries, palette = self.theme(name)
            colors = set(palette.values()) | set(entries.values())
            swatches = re.findall(rf'\.theme-card\[data-swatch="{name}"\] \.s\d \{{ background: (#[0-9a-f]{{6}}); \}}', css)
            self.assertEqual(len(swatches), 5, name)
            for color in swatches:
                self.assertIn(color, colors, f"{name} swatch {color} is not in the theme file")

    def test_check_site_accepts_the_theme_files(self):
        result = subprocess.run([sys.executable, str(ROOT / "scripts/check_site.py")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
