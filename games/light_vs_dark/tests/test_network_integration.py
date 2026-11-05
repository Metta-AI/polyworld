"""Integration seams: the live renderer must use tested shared-network state."""
from pathlib import Path
import unittest

GAME = Path(__file__).resolve().parents[1]


class NetworkIntegration(unittest.TestCase):
    def test_live_frames_use_network_presentation_not_local_accumulator(self):
        source = (GAME / "graphics.nim").read_text()
        live = source.split("if network != nil:\n        connection.stats.tickRate", 1)[1].split("      else:", 1)[0]
        self.assertIn("networkPresentation.startFrame(dt)", live)
        self.assertIn("networkPresentation.appliedTick()", live)
        self.assertLess(live.index("advanceRenderedMatch(packet)"), live.index("networkPresentation.appliedTick()"))
        self.assertEqual(live.count("connection.pump()"), 2)
        alpha = source.split("      frameAlpha =", 1)[1].split("      if active:", 1)[0]
        self.assertIn("if network != nil:", alpha)
        self.assertIn("networkPresentation.frameAlpha(", alpha)
        self.assertIn("connection.playback, connection.stats, networkTime()", alpha)
        self.assertIn("transport.accumulator / Step", alpha)
        self.assertIn("networkPresentation: NetworkPresentation", source)

    def test_debug_menu_receives_the_connections_actual_mutable_stats(self):
        ui = (GAME / "ui.nim").read_text()
        graphics = (GAME / "graphics.nim").read_text()
        self.assertIn("networkStats: NetworkStats = nil", ui)
        self.assertIn("sk.drawDebugMenu(window, network = networkStats)", ui)
        call = graphics.split("          drawUi(", 1)[1].split("          )", 1)[0]
        self.assertIn("if connection != nil: connection.stats else: nil", call)


if __name__ == "__main__":
    unittest.main()
