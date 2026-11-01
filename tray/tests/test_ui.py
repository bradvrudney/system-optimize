"""The Qt panel, rendered offscreen. Skipped where neither PySide6 nor
PyQt6 is installed."""
import os
import tempfile
import time
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from helpers import FAKE_CLI, stub  # noqa: E402

try:
    from so_tray.qt import QtCore, QtWidgets
except ImportError:  # no Qt binding here
    QtWidgets = None


class FakeMonitor:
    def cpu(self):
        return {}

    def sample(self):
        return {"time": 0, "cpu": {"percent": 20, "mhz": 3000, "load1": 1.0},
                "memory": {"percent": 30, "total_mb": 1000, "used_mb": 300, "swap_total_mb": 0, "swap_used_mb": 0},
                "temperature": {"cpu": 50}, "power": {"profile": "balanced", "ac": True, "batteries": []},
                "disk": {"read_mbs": 1, "write_mbs": 2}, "gpu": {}}


@unittest.skipIf(QtWidgets is None, "no Qt binding (PySide6 or PyQt6)")
class PanelTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def setUp(self):
        os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp()
        os.environ["XDG_STATE_HOME"] = tempfile.mkdtemp()
        os.environ["FAKE_SO_MODE"] = "new"
        from so_tray.cli import Cli
        from so_tray.panel import Controller, Panel
        d = tempfile.mkdtemp()
        self.cli = Cli(path=FAKE_CLI, pkexec=stub(d, "pkexec"), helper="/nonexistent/helper")
        self.ctl = Controller(self.cli, FakeMonitor())
        self.ctl.info = self.cli.describe()
        self.ctl.history = self.cli.history(limit=200)
        self.panel = Panel(self.ctl)

    def tearDown(self):
        self.panel.close()
        self.panel.deleteLater()

    def wait(self, cond, timeout=5):
        end = time.time() + timeout
        while time.time() < end:
            self.app.processEvents()
            if cond():
                return True
            time.sleep(0.02)
        return False

    def headers(self):
        return [w.accessibleName() for w in self.panel.dash.findChildren(QtWidgets.QWidget)
                if w.accessibleName().endswith(("expanded", "collapsed"))]

    def test_categories_start_collapsed(self):
        self.app.processEvents()
        heads = self.headers()
        self.assertTrue(heads)
        self.assertTrue(all(h.endswith("collapsed") for h in heads))

    def test_expanding_a_category_is_remembered(self):
        from so_tray import settings
        self.panel.toggle_category("memory")
        self.app.processEvents()
        self.assertEqual(settings.load()["EXPANDED"], "memory")
        self.assertTrue(any(h.endswith("expanded") and h.startswith("Memory") for h in self.headers()))
        again = type(self.panel)(self.ctl)
        self.assertEqual(again.settings["EXPANDED"], "memory")
        again.close()
        self.panel.toggle_category("memory")
        self.assertEqual(settings.load()["EXPANDED"], "")

    def test_feature_detail_shows_doc_and_change_log(self):
        self.panel.open_feature("sysctl")
        self.assertIs(self.panel.stack.currentWidget(), self.panel.detail)
        self.assertTrue(self.wait(lambda: "Loading" not in self.panel.detail_doc.toPlainText()))
        self.assertIn("sysctl", self.panel.detail_doc.toPlainText().lower())
        log = self.panel.detail_log
        self.assertGreater(log.rowCount(), 0)
        texts = [log.item(r, 1).text() for r in range(log.rowCount()) if log.item(r, 1)]
        self.assertTrue(any("→" in t for t in texts), texts)
        self.panel.show_dashboard()
        self.assertIs(self.panel.stack.currentWidget(), self.panel.dash)

    def test_theme_switches_live_and_is_saved(self):
        from so_tray import settings
        self.panel.apply_theme("light")
        light_bg = self.panel.c["bg"]
        self.assertFalse(self.panel.c["dark"])
        self.panel.apply_theme("dark")
        self.assertTrue(self.panel.c["dark"])
        self.assertNotEqual(light_bg, self.panel.c["bg"])
        self.assertIn(self.panel.c["bg"], self.panel.styleSheet())
        self.assertEqual(settings.load()["THEME"], "dark")
        checked = [a.data() for a in self.panel.theme_actions if a.isChecked()]
        self.assertEqual(checked, ["dark"])

    def test_about_thanks_the_projects(self):
        from so_tray.credits import load_credits
        self.panel.open_about()
        text = self.panel.about_text.toPlainText()
        for p in load_credits():
            self.assertIn(p["name"], text)
        self.assertIn("system-optimize-tray", text)

    def test_not_installed(self):
        self.ctl.info = {"found": False, "features": [], "capabilities": []}
        self.ctl.history = {"benchmarks": [], "changes": [], "available": False}
        self.panel._on_info()
        self.assertFalse(self.panel.btn_apply.isEnabled())
        self.assertIn("not found", self.panel.version_label.text())


if __name__ == "__main__":
    unittest.main()
