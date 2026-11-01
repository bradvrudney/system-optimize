import unittest

from helpers import fake_machine, write
from so_tray.monitor import _read, Monitor, cpu_percent, parse_cpu_times, parse_diskstats, parse_meminfo, summary


class MonitorTest(unittest.TestCase):
    def setUp(self):
        self.root = fake_machine()
        self.m = Monitor(root=self.root, which=lambda _: None)

    def test_cpu_percent_needs_two_samples(self):
        self.assertIsNone(self.m.cpu()["percent"])
        write(self.root, "/proc/stat", "cpu  150 0 150 900 0 0 0 0 0 0\n")
        # +100 busy, +100 idle -> 50%
        self.assertEqual(self.m.cpu()["percent"], 50.0)

    def test_cpu_details(self):
        c = self.m.cpu()
        self.assertEqual(c["mhz"], 3500)
        self.assertEqual(c["mhz_max"], 4000)
        self.assertEqual(c["load1"], 1.5)
        self.assertEqual(c["governor"], "powersave")
        self.assertEqual(c["epp"], "balance_performance")

    def test_parsers_tolerate_junk(self):
        self.assertIsNone(parse_cpu_times("garbage"))
        self.assertIsNone(parse_cpu_times("cpu  a b c d"))
        self.assertEqual(parse_meminfo("MemTotal: x kB\nFoo: 3 kB"), {"Foo": 3})
        self.assertIsNone(cpu_percent((1, 2), (1, 2)))

    def test_memory(self):
        mem = self.m.memory()
        self.assertEqual(mem["total_mb"], 64000)
        self.assertEqual(mem["used_mb"], 16000)
        self.assertEqual(mem["percent"], 25.0)
        self.assertEqual(mem["swap_used_mb"], 256)
        self.assertTrue(mem["zram"])

    def test_temperatures_prefer_tctl_and_skip_dead_sensors(self):
        t = self.m.temperatures()
        self.assertEqual(t["cpu"], 61.5)
        self.assertEqual(t["gpu"], 48.0)
        self.assertEqual(t["nvme"], 41.9)
        self.assertNotIn(-273.1, [s["c"] for s in t["sensors"]])

    def test_temperature_falls_back_to_thermal_zone(self):
        root = fake_machine()
        import shutil
        shutil.rmtree(root + "/sys/class/hwmon")
        write(root, "/sys/class/thermal/thermal_zone0/type", "acpitz\n")
        write(root, "/sys/class/thermal/thermal_zone0/temp", "40000\n")
        write(root, "/sys/class/thermal/thermal_zone1/type", "x86_pkg_temp\n")
        write(root, "/sys/class/thermal/thermal_zone1/temp", "70000\n")
        self.assertEqual(Monitor(root=root).temperatures()["cpu"], 70.0)

    def test_power_ignores_device_batteries(self):
        p = self.m.power()
        self.assertEqual([b["name"] for b in p["batteries"]], ["BAT0"])
        self.assertEqual(p["batteries"][0]["limit"], 80)
        self.assertTrue(p["ac"])
        self.assertEqual((p["profile"], p["owner"]), ("balanced", "firmware"))

    def test_power_asks_the_daemon_first(self):
        m = Monitor(root=self.root, which=lambda n: "/usr/bin/" + n,
                    run=lambda argv: "performance\n" if argv[0] == "powerprofilesctl" else None)
        self.assertEqual(m.power()["owner"], "power-profiles-daemon")
        m = Monitor(root=self.root, which=lambda n: "/usr/bin/" + n if n == "tuned-adm" else None,
                    run=lambda argv: "Current active profile: throughput-performance\n")
        self.assertEqual(m.power()["profile"], "throughput-performance")

    def test_disk_counts_whole_disks_only(self):
        self.assertEqual(parse_diskstats(_read(self.root + "/proc/diskstats"), {"nvme0n1"}), (2000, 1000))
        self.assertEqual(self.m.whole_disks(), {"nvme0n1"})
        self.assertEqual(self.m.disk(), {"read_mbs": None, "write_mbs": None})
        write(self.root, "/proc/diskstats", " 259 0 nvme0n1 100 0 4000 0 50 0 1000 0 0 0 0\n")
        d = self.m.disk()
        self.assertGreater(d["read_mbs"], 0)
        self.assertEqual(d["write_mbs"], 0.0)

    def test_gpu_busy(self):
        self.assertEqual(self.m.gpu(), {"busy_percent": 12})

    def test_empty_machine_does_not_raise(self):
        import tempfile
        s = Monitor(root=tempfile.mkdtemp(), which=lambda _: None).sample()
        self.assertIsNone(s["cpu"]["percent"])
        self.assertIsNone(s["memory"]["total_mb"])
        self.assertEqual(summary(s), "CPU – · RAM –")

    def test_summary(self):
        self.m.cpu()
        write(self.root, "/proc/stat", "cpu  150 0 150 900 0 0 0 0 0 0\n")
        self.assertEqual(summary(self.m.sample()), "CPU 50% 62°C · RAM 25%")


if __name__ == "__main__":
    unittest.main()
