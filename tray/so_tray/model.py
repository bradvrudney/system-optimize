"""What the tray menu shows, worked out without Qt so it can be tested."""


def _gb(mb):
    return "%.1f" % (mb / 1024.0)


def readout_lines(sample):
    """The live lines at the top of the menu."""
    if not sample:
        return ["Reading the system…"]
    cpu = sample.get("cpu") or {}
    mem = sample.get("memory") or {}
    temp = sample.get("temperature") or {}
    power = sample.get("power") or {}
    lines = []
    parts = ["CPU " + ("–" if cpu.get("percent") is None else "%d%%" % round(cpu["percent"]))]
    if cpu.get("mhz"):
        parts.append("%.1f GHz" % (cpu["mhz"] / 1000.0))
    if temp.get("cpu") is not None:
        parts.append("%d°C" % round(temp["cpu"]))
    if cpu.get("load1") is not None:
        parts.append("load %.2f" % cpu["load1"])
    lines.append(" · ".join(parts))
    if mem.get("total_mb"):
        m = "Memory %s / %s GB" % (_gb(mem.get("used_mb") or 0), _gb(mem["total_mb"]))
        if mem.get("percent") is not None:
            m += " (%d%%)" % round(mem["percent"])
        if mem.get("swap_total_mb"):
            m += " · %s %s GB used" % ("zram" if mem.get("zram") else "swap", _gb(mem.get("swap_used_mb") or 0))
        lines.append(m)
    other = []
    if temp.get("gpu") is not None:
        other.append("GPU %d°C" % round(temp["gpu"]))
    if temp.get("nvme") is not None:
        other.append("NVMe %d°C" % round(temp["nvme"]))
    if other:
        lines.append(" · ".join(other))
    p = "Power profile " + (power.get("profile") or "unknown")
    if power.get("owner"):
        p += " (%s)" % power["owner"]
    for bat in power.get("batteries") or []:
        if bat.get("percent") is not None:
            p += " · battery %d%%" % bat["percent"]
            if bat.get("status"):
                p += " %s" % bat["status"].lower()
            break
    else:
        if power.get("ac") is not None:
            p += " · on AC" if power["ac"] else " · on battery"
    lines.append(p)
    return lines


def feature_entries(info):
    """[(name, label, checked, enabled, tip)] for the toggles."""
    out = []
    caps = set(info.get("capabilities") or ())
    for f in info.get("features") or []:
        label = f["title"]
        if f.get("kind") == "opt-in":
            label += " (optional)"
        applied = f.get("applied")
        enabled = True
        tip = f.get("summary") or ""
        if applied is None:
            tip = (tip + "; " if tip else "") + "state unknown: this system-optimize does not report it"
        if f.get("kind") == "opt-in" and "enable" not in caps and not applied:
            enabled = False
            tip = (tip + "; " if tip else "") + "needs a newer system-optimize"
        if applied and "revert-step" not in caps:
            tip = (tip + "; " if tip else "") + "to turn it off, use Undo last run"
        out.append((f["name"], label, bool(applied), enabled, tip))
    return out


def categories(info, history=None):
    """Feature entries grouped for the collapsible sections:
    [{key, title, entries, on, total, trend_pct}] in a stable order."""
    entries = {e[0]: e for e in feature_entries(info)}
    groups = {}
    order = []
    for f in info.get("features") or []:
        key = f.get("category") or "other"
        if key not in groups:
            groups[key] = {"key": key, "title": f.get("category_title") or "Other", "entries": [],
                           "on": 0, "total": 0, "trend_pct": None, "unknown": False}
            order.append(key)
        g = groups[key]
        g["entries"].append(entries[f["name"]])
        g["total"] += 1
        if f.get("applied") is None:
            g["unknown"] = True
        g["on"] += 1 if f.get("applied") else 0
    if history:
        for g in groups.values():
            names = {e[0] for e in g["entries"]}
            g["trend_pct"] = measured_effect([c for c in change_log(history) if c.get("step") in names])[1]
    return [groups[k] for k in order]


def category_count(g):
    if g.get("unknown"):
        return "%d step%s" % (g["total"], "" if g["total"] == 1 else "s")
    return "%d/%d on" % (g["on"], g["total"])


def actions_available(info):
    caps = set(info.get("capabilities") or ())
    return {
        "apply_all": bool(info.get("found")),
        "preview": bool(info.get("found")),
        "undo": bool(info.get("found")) and "undo" in caps,
        "profiles": list(info.get("profiles") or []) if "profile" in caps else [],
        "benchmark": "benchmark" in caps,
        "status": bool(info.get("found")),
    }


def _overall(b):
    s = (b or {}).get("scores") or {}
    if "overall" in s:
        return s["overall"]
    vals = [v for v in s.values() if isinstance(v, (int, float))]
    return sum(vals) / len(vals) if vals else None


def baseline_compare(history):
    """(baseline score, latest score, change in %) or None without two benchmarks."""
    benches = [b for b in (history or {}).get("benchmarks") or [] if _overall(b) is not None]
    if len(benches) < 1:
        return None
    first, last = benches[0], benches[-1]
    a, b = _overall(first), _overall(last)
    pct = 100.0 * (b - a) / abs(a) if a else None
    return {"baseline": a, "latest": b, "pct": pct, "baseline_time": first["time"], "latest_time": last["time"],
            "count": len(benches)}


def change_log(history, step=None):
    """Each setting change with the overall benchmark before and after it."""
    benches = {b["id"]: b for b in (history or {}).get("benchmarks") or []}
    out = []
    for c in (history or {}).get("changes") or []:
        if step and c.get("step") != step:
            continue
        before = _overall(benches.get(c.get("benchmark_before")))
        after = _overall(benches.get(c.get("benchmark_after")))
        pct = 100.0 * (after - before) / abs(before) if before and after is not None else None
        out.append(dict(c, score_before=before, score_after=after, delta_pct=pct))
    return out


def measured_effect(log):
    """(number of measured runs, summed % change) over change_log() entries.
    Changes made in one run share their before/after benchmarks, so each
    run counts once; undone changes are left out."""
    seen = {}
    for c in log:
        if c.get("delta_pct") is None or c.get("undone"):
            continue
        seen[(c.get("benchmark_before"), c.get("benchmark_after"))] = c["delta_pct"]
    if not seen:
        return 0, None
    return len(seen), sum(seen.values())


def score_series(history):
    """[(iso time, overall score)] for the chart."""
    return [(b["time"], _overall(b)) for b in (history or {}).get("benchmarks") or [] if _overall(b) is not None]


def fmt_pct(p, plus=True):
    if p is None:
        return "–"
    return ("%+.1f%%" if plus else "%.1f%%") % p
