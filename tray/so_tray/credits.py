"""The credits list, from data/credits.json (the one place to add a project)."""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
CANDIDATES = (
    os.path.join(HERE, "credits.json"),                       # installed next to the package
    os.path.join(HERE, "..", "credits.json"),                 # installed: PKGDATADIR/credits.json
    os.path.join(HERE, "..", "data", "credits.json"),         # source tree
    "/usr/share/system-optimize-tray/credits.json",
)


def load_credits(paths=CANDIDATES):
    for p in paths:
        try:
            with open(p, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            continue
        return [x for x in data.get("projects") or []
                if isinstance(x, dict) and all(isinstance(x.get(k), str) for k in ("name", "license", "url", "role"))
                and x["url"].startswith("https://")]
    return []
