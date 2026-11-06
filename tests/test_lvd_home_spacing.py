"""Protect LvD compact home routing while preserving other games' layout."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class HomeSpacing(unittest.TestCase):
    def test_compact_home_omits_shared_caption_and_moves_logo(self):
        source = (ROOT / 'src/polyworld/homes.nim').read_text()
        self.assertIn('compact = false', source)
        self.assertRegex(source, r'logoY = if compact: 105\S* else: 30')
        self.assertRegex(source, r'if not compact:\s+sk.drawLabel\("Polyworld"')
        self.assertIn('vec2(536, logoY)', source)

    def test_lvd_selects_compact_shared_layout(self):
        source = (ROOT / 'games/light_vs_dark/homes.nim').read_text()
        self.assertIn('proc drawLvdHome*', source)
        self.assertIn('sharedHomes.drawHome(sk, window, focus, compact = true)', source)

if __name__ == '__main__':
    unittest.main()
