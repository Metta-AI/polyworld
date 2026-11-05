"""Regression guard for the shared WASM build recipe's game policies/socket exports."""
from pathlib import Path
import unittest

class WebGamePackaging(unittest.TestCase):
    def test_lvd_uses_same_socket_exports_as_gota(self):
        recipe = (Path(__file__).parents[1] / 'src/polyworld/emscripten.nims').read_text()
        start = recipe.index('    if game in ["gota", "lvd"]:') if '    if game in ["gota", "lvd"]:' in recipe else -1
        self.assertNotEqual(start, -1, 'Both multiplayer games must preload policies and export WebSocket callbacks')
        section = recipe[start:recipe.index('    let shell =', start)]
        self.assertIn('_windy_websocket_message_callback', section)
        self.assertIn('"@/policies/" & game', section)
        self.assertIn('@["base"]', section)

if __name__ == '__main__':
    unittest.main()
