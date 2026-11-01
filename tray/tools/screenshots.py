#!/usr/bin/env python3
"""Render the panel's screens offscreen with the fake CLI and made-up
readings, for the README and pull requests:

  QT_QPA_PLATFORM=offscreen python3 tools/screenshots.py OUTDIR
"""
import math
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
os.environ.setdefault("SO_TRAY_CLI", os.path.join(HERE, "..", "tests", "fixtures", "fake-system-optimize"))
os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp()
os.environ["XDG_STATE_HOME"] = tempfile.mkdtemp()

from so_tray.qt import QtCore, QtWidgets  # noqa: E402


class FakeMonitor:
    def __init__(self):
        self.i = 0

    def cpu(self):
        return {}

    def sample(self):
        self.i += 1
        i = self.i
        return {
            "time": 0,
            "cpu": {"percent": 18 + 14 * math.sin(i / 5) + 6 * math.sin(i * 1.3), "mhz": 3650, "load1": 2.41},
            "memory": {"percent": 31 + 3 * math.sin(i / 9), "total_mb": 65536, "used_mb": 20400,
                       "swap_total_mb": 16384, "swap_used_mb": 310, "zram": True},
            "temperature": {"cpu": 56 + 7 * math.sin(i / 6), "gpu": 49, "nvme": 41},
            "power": {"profile": "balanced", "owner": "tuned-ppd", "ac": True, "batteries": []},
            "disk": {"read_mbs": abs(40 * math.sin(i / 3)), "write_mbs": abs(12 * math.cos(i / 4))},
            "gpu": {"busy_percent": 7},
        }


class FakeAgentReply:
    text = ("Your last benchmark is 2 days old and scores 110 against a baseline of 100. Disk scores rose "
            "12% after the scheduler change. The dev profile is active; nothing else stands out, but the "
            "tuned step is off and would let tuned-ppd keep these settings across profile switches.")
    proposal = None


class FakeAgent:
    def ask(self, q):
        return FakeAgentReply()


def main(out):
    os.makedirs(out, exist_ok=True)
    from so_agent import store
    store.save_proposal({"action": "enable_step", "target": "tuned", "summary": "turn on tuned",
                         "reason": "tuned-ppd is active; a tuned profile keeps these settings across power "
                                   "profile switches (benchmark unchanged, so low risk)."})
    from so_tray import settings
    settings.save("EXPANDED", "memory,power,storage")
    app = QtWidgets.QApplication([])
    from so_tray.app import App
    for theme in ("dark", "light"):
        settings.save("THEME", theme)
        a = App(tray=False, monitor=FakeMonitor(), agent_factory=lambda cli=None: FakeAgent())
        a.panel.resize(440, 1180)
        for _ in range(60):
            a.ctl.tick()
        loop = QtCore.QEventLoop()
        QtCore.QTimer.singleShot(2500, loop.quit)
        loop.exec()
        a.panel.show()
        a.panel.grab().save(os.path.join(out, "dashboard-%s.png" % theme))
        a.panel.open_feature("sysctl")
        loop = QtCore.QEventLoop()
        QtCore.QTimer.singleShot(1500, loop.quit)
        loop.exec()
        a.panel.resize(440, 900)
        a.panel.grab().save(os.path.join(out, "feature-%s.png" % theme))
        a.panel.open_about()
        a.panel.resize(440, 760)
        a.panel.grab().save(os.path.join(out, "about-%s.png" % theme))
        a.panel.open_chat()
        a.panel._say("you", "Is anything worth changing on this machine?")
        a.panel._say("agent", FakeAgentReply.text)
        a.panel._refresh_agent()
        a.panel.grab().save(os.path.join(out, "agent-%s.png" % theme))
        a.panel.close()
    print("screenshots in", out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "screenshots")
