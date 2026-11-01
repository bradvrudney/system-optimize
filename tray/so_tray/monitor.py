"""Live readings from /proc and /sys. Read-only; needs no root.

Every path goes through Monitor.path(), which puts the root prefix in front
(SO_ROOT in the tests, "/" on a real machine), so the whole module runs
against a fake tree. Nothing here raises on a missing or odd file: a value
that cannot be read is None and the UI shows a dash.
"""

import glob
import os
import shutil
import subprocess
import time

# hwmon chips, in the order we prefer them for "the CPU temperature".
CPU_CHIPS = ("k10temp", "zenpower", "coretemp", "cpu_thermal", "acpitz")
# Labels that name the package / die temperature on those chips.
CPU_LABELS = ("Tctl", "Tdie", "Package id 0", "CPU")
GPU_CHIPS = ("amdgpu", "nouveau", "radeon", "i915", "xe")


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return None


def _read_int(path):
    text = _read(path)
    if text is None:
        return None
    try:
        return int(text.split()[0])
    except (ValueError, IndexError):
        return None


def parse_meminfo(text):
    """{'MemTotal': kB, ...} from /proc/meminfo."""
    out = {}
    for line in (text or "").splitlines():
        key, _, rest = line.partition(":")
        parts = rest.split()
        if parts:
            try:
                out[key.strip()] = int(parts[0])
            except ValueError:
                pass
    return out


def parse_cpu_times(text):
    """(busy, total) jiffies of the aggregate 'cpu' line of /proc/stat."""
    for line in (text or "").splitlines():
        if line.startswith("cpu "):
            try:
                fields = [int(x) for x in line.split()[1:]]
            except ValueError:
                return None
            if len(fields) < 4:
                return None
            # user nice system idle iowait irq softirq steal (guest* are
            # already counted in user/nice).
            idle = fields[3] + (fields[4] if len(fields) > 4 else 0)
            total = sum(fields[:8])
            return total - idle, total
    return None


def cpu_percent(prev, cur):
    """CPU use in percent between two parse_cpu_times() samples."""
    if not prev or not cur:
        return None
    busy = cur[0] - prev[0]
    total = cur[1] - prev[1]
    if total <= 0:
        return None
    return max(0.0, min(100.0, 100.0 * busy / total))


def parse_diskstats(text, disks):
    """(sectors read, sectors written) summed over the whole disks named."""
    rd = wr = 0
    for line in (text or "").splitlines():
        f = line.split()
        if len(f) >= 10 and f[2] in disks:
            try:
                rd += int(f[5])
                wr += int(f[9])
            except ValueError:
                pass
    return rd, wr


class Monitor:
    """Samples the machine. Keep one instance: CPU use needs two samples."""

    def __init__(self, root="/", run=None, which=None):
        self.root = root or "/"
        self._run = run or _run_quiet
        self._which = which or shutil.which
        self._prev_cpu = None
        self._prev_disk = None    # (time, sectors read, sectors written)

    def path(self, p):
        return os.path.join(self.root, p.lstrip("/"))

    # -- CPU -----------------------------------------------------------
    def cpu(self):
        cur = parse_cpu_times(_read(self.path("/proc/stat")))
        pct = cpu_percent(self._prev_cpu, cur)
        self._prev_cpu = cur
        freqs = []
        for f in glob.glob(self.path("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq")):
            v = _read_int(f)
            if v:
                freqs.append(v)
        load = _read(self.path("/proc/loadavg"))
        try:
            load1 = float(load.split()[0]) if load else None
        except ValueError:
            load1 = None
        gov = _read(self.path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"))
        epp = _read(self.path("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"))
        return {
            "percent": None if pct is None else round(pct, 1),
            "mhz": round(sum(freqs) / len(freqs) / 1000) if freqs else None,
            "mhz_max": round(max(freqs) / 1000) if freqs else None,
            "load1": load1,
            "cores": len(glob.glob(self.path("/sys/devices/system/cpu/cpu[0-9]*"))) or os.cpu_count(),
            "governor": gov,
            "epp": epp,
        }

    # -- memory --------------------------------------------------------
    def memory(self):
        mi = parse_meminfo(_read(self.path("/proc/meminfo")))
        total = mi.get("MemTotal")
        avail = mi.get("MemAvailable")
        swap_total = mi.get("SwapTotal", 0)
        swap_free = mi.get("SwapFree", 0)
        used = (total - avail) if total and avail is not None else None
        return {
            "total_mb": total // 1024 if total else None,
            "used_mb": used // 1024 if used is not None else None,
            "percent": round(100.0 * used / total, 1) if total and used is not None else None,
            "swap_total_mb": swap_total // 1024,
            "swap_used_mb": max(0, swap_total - swap_free) // 1024,
            "zram": bool(glob.glob(self.path("/sys/block/zram[0-9]*"))),
        }

    # -- temperatures --------------------------------------------------
    def temperatures(self):
        """{'cpu': C, 'gpu': C, 'nvme': C, 'sensors': [{chip,label,c}]}."""
        sensors = []
        for hw in sorted(glob.glob(self.path("/sys/class/hwmon/hwmon*"))):
            chip = _read(os.path.join(hw, "name")) or os.path.basename(hw)
            for inp in sorted(glob.glob(os.path.join(hw, "temp*_input"))):
                milli = _read_int(inp)
                if milli is None or milli <= -40000 or milli >= 150000:
                    continue
                label = _read(inp[: -len("_input")] + "_label") or os.path.basename(inp)[: -len("_input")]
                sensors.append({"chip": chip, "label": label, "c": round(milli / 1000.0, 1)})
        out = {"cpu": None, "gpu": None, "nvme": None, "sensors": sensors}
        for chip in CPU_CHIPS:
            mine = [s for s in sensors if s["chip"] == chip]
            if not mine:
                continue
            labelled = [s for lab in CPU_LABELS for s in mine if s["label"] == lab]
            out["cpu"] = (labelled or mine)[0]["c"]
            break
        if out["cpu"] is None:
            # No hwmon chip we know: the thermal zone of type x86_pkg_temp
            # or the first zone.
            zones = sorted(glob.glob(self.path("/sys/class/thermal/thermal_zone*")))
            pick = None
            for z in zones:
                if (_read(os.path.join(z, "type")) or "") in ("x86_pkg_temp", "cpu-thermal", "cpu_thermal"):
                    pick = z
                    break
            if pick is None and zones:
                pick = zones[0]
            if pick:
                milli = _read_int(os.path.join(pick, "temp"))
                if milli is not None and -40000 < milli < 150000:
                    out["cpu"] = round(milli / 1000.0, 1)
        for chip in GPU_CHIPS:
            mine = [s for s in sensors if s["chip"] == chip]
            if mine:
                edge = [s for s in mine if s["label"] in ("edge", "junction")]
                out["gpu"] = (edge or mine)[0]["c"]
                break
        nvme = [s for s in sensors if s["chip"] == "nvme"]
        if nvme:
            out["nvme"] = max(s["c"] for s in nvme)
        return out

    # -- power ---------------------------------------------------------
    def power(self):
        """Active power profile, who owns it, AC and battery."""
        profile = None
        owner = None
        if self._which("powerprofilesctl"):
            text = self._run(["powerprofilesctl", "get"])
            if text:
                profile, owner = text.strip().splitlines()[0], "power-profiles-daemon"
        if profile is None and self._which("tuned-adm"):
            text = self._run(["tuned-adm", "active"])
            if text and ":" in text:
                profile, owner = text.split(":", 1)[1].strip().splitlines()[0], "tuned"
        if profile is None:
            pp = _read(self.path("/sys/firmware/acpi/platform_profile"))
            if pp:
                profile, owner = pp, "firmware"
        ac = None
        batteries = []
        for sup in sorted(glob.glob(self.path("/sys/class/power_supply/*"))):
            kind = _read(os.path.join(sup, "type"))
            if kind == "Mains":
                online = _read_int(os.path.join(sup, "online"))
                if online is not None:
                    ac = bool(online) or bool(ac)
            elif kind == "Battery":
                # A wireless mouse or keyboard reports scope=Device: not ours.
                if (_read(os.path.join(sup, "scope")) or "System") != "System":
                    continue
                batteries.append({
                    "name": os.path.basename(sup),
                    "percent": _read_int(os.path.join(sup, "capacity")),
                    "status": _read(os.path.join(sup, "status")),
                    "limit": _read_int(os.path.join(sup, "charge_control_end_threshold")),
                })
        return {"profile": profile, "owner": owner, "ac": ac, "batteries": batteries}

    # -- disks and GPU ----------------------------------------------
    def whole_disks(self):
        out = set()
        for d in glob.glob(self.path("/sys/block/*")):
            name = os.path.basename(d)
            if name.startswith(("loop", "ram", "zram", "fd", "sr", "md", "dm-")):
                continue
            out.add(name)
        return out

    def disk(self):
        now = time.monotonic()
        cur = parse_diskstats(_read(self.path("/proc/diskstats")), self.whole_disks())
        out = {"read_mbs": None, "write_mbs": None}
        if self._prev_disk:
            dt = now - self._prev_disk[0]
            if dt > 0:
                out["read_mbs"] = round(max(0, cur[0] - self._prev_disk[1]) * 512 / dt / 1e6, 2)
                out["write_mbs"] = round(max(0, cur[1] - self._prev_disk[2]) * 512 / dt / 1e6, 2)
        self._prev_disk = (now, cur[0], cur[1])
        return out

    def gpu(self):
        busy = None
        for f in sorted(glob.glob(self.path("/sys/class/drm/card[0-9]*/device/gpu_busy_percent"))):
            v = _read_int(f)
            if v is not None:
                busy = v if busy is None else max(busy, v)
        return {"busy_percent": busy}

    def sample(self):
        return {
            "time": int(time.time()),
            "cpu": self.cpu(),
            "memory": self.memory(),
            "temperature": self.temperatures(),
            "power": self.power(),
            "disk": self.disk(),
            "gpu": self.gpu(),
        }


def _run_quiet(argv, timeout=3):
    try:
        res = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return res.stdout if res.returncode == 0 else None


def summary(sample):
    """One short line for a panel label or a tooltip: 'CPU 12% 54°C · RAM 41%'."""
    cpu = sample.get("cpu", {})
    mem = sample.get("memory", {})
    temp = sample.get("temperature", {})
    parts = []
    c = "CPU " + ("–" if cpu.get("percent") is None else "%d%%" % round(cpu["percent"]))
    if temp.get("cpu") is not None:
        c += " %d°C" % round(temp["cpu"])
    parts.append(c)
    parts.append("RAM " + ("–" if mem.get("percent") is None else "%d%%" % round(mem["percent"])))
    return " · ".join(parts)
