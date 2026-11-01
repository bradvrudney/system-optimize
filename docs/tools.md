# Helpers and related open-source projects

system-optimize changes a handful of settings itself. Much of what a
"performance tuning" script could do is done better, and kept up to date,
by daemons that distributions already ship. This page is the survey behind
what the program uses, recommends, warns about and leaves out. The rule it
follows: when a maintained tool owns a setting, use the tool instead of
writing the setting directly.

## Used by the `cpu` step

### power-profiles-daemon / tuned-ppd

The freedesktop.org daemon behind the power menu in GNOME and KDE
(performance, balanced, power-saver). On AMD `amd-pstate-epp` machines it
sets the CPU's energy-performance preference and the firmware platform
profile together; on Intel it does the same through `intel_pstate`. Fedora
41 and later ship **tuned-ppd** instead, which answers the same
`powerprofilesctl` interface and maps the three profiles to tuned profiles.

Why it matters here: while either runs, it owns the governor and the energy
preference. Writing `performance` to sysfs (what 1.x did) is silently
undone at the next profile change, or pins the energy preference without
the daemon knowing. So the `cpu` step uses `powerprofilesctl` whenever it
answers.

### tuned

Red Hat's profile-based tuning daemon (sysctl, sysfs, CPU, disk, network
settings bundled into named profiles such as `throughput-performance`,
`latency-performance`, `powersave`, `virtual-guest`). The default on Fedora
Server, RHEL and derivatives. The `cpu` step switches to
`throughput-performance` when tuned runs without the PPD front end.

Bigger idea, not done: tuned can carry the whole sysctl and I/O part of this
program as a custom profile (`/etc/tuned/system-optimize/tuned.conf`,
`include=throughput-performance`). On tuned machines that would hand the
settings to one owner. See "Ideas" below.

## Recommended by the `tools` step

### systemd-oomd, earlyoom, nohang

Userspace out-of-memory handlers: they end the biggest offender while the
desktop still responds, instead of waiting for the kernel's OOM killer,
which acts only after the machine has been thrashing for a while.

* **systemd-oomd** is part of systemd, uses pressure stall information
  (PSI) and cgroups, and is enabled by default on Fedora (34 and later) and
  Ubuntu (22.04 and later). Recommended first where it exists.
* **earlyoom** is a small daemon acting on free memory and swap
  percentages; packaged everywhere. Recommended where systemd-oomd is not
  available.
* **nohang** is a more configurable alternative. Recognised, not installed.

Run one of them, not two: they would race to kill. The `tools` step warns
when systemd-oomd runs next to earlyoom or nohang.

### zram-generator

The systemd project's generator for compressed swap in RAM. Fedora's
default swap since 33 (as `zram-generator-defaults`). Recommended only when
the machine has no swap at all; `--install-tools` writes a conservative
config (`zram-size = min(ram / 2, 8192)`, zstd). The `sysctl` step sets
swappiness for zram whenever zram is the swap, whoever set it up.

Related: **zswap** (a compressed cache in front of disk swap, built into
the kernel) is the alternative for machines that keep disk swap; it is a
kernel command-line setting and out of scope.

### irqbalance

Spreads hardware interrupts across CPUs. Most useful on servers and
machines with many network or storage queues; harmless on desktops, and
installed by default on Fedora and Ubuntu. Recommended on multi-CPU
machines when not running; not in VMs.

### fstrim.timer (util-linux)

Weekly `fstrim` of SSD filesystems. Shipped with util-linux, not enabled
everywhere. The `trim` step enables it. Continuous `discard` mount options
are the alternative; the timer is the usual recommendation.

## Recognised, with a warning when they conflict

### TLP

Comprehensive laptop power management (CPU, PCIe, USB, disks, radios).
TLP's own documentation says to remove or mask power-profiles-daemon,
because both write the same settings. The `tools` step warns when TLP runs
next to PPD or tuned. system-optimize leaves battery-powered machines'
CPUs alone, so it does not fight TLP itself.

### auto-cpufreq

Switches governors and turbo by load and power source. Conflicts with PPD,
tuned and TLP for the same reason; the `tools` step warns.

### thermald

Intel's thermal daemon (Intel CPUs only). Reported when present; nothing
to configure.

## Considered and left out

| Project | What it does | Why not here |
|---------|--------------|--------------|
| **cpupower** (kernel tools) | Set governors, frequency limits, idle states | Same as writing sysfs directly; the profile daemons are the owners now. |
| **ananicy-cpp** | Rule-based nice/ionice/cgroup tweaks per process | Useful, but opinionated per-application rules; better installed by choice. A candidate for `--install-tools` later. |
| **sched_ext schedulers (scx)** | Alternative CPU schedulers loaded as BPF (`scx_lavd`, `scx_bpfland`, `scx_rusty`), kernel 6.12+ | Promising for gaming and interactive loads, but choosing one is workload-specific and still moving fast. Listed under Ideas. |
| **preload** | Prefetches binaries of frequently used programs | Unmaintained since 2009; on SSDs the gain is negligible. |
| **BleachBit** | Deletes caches, logs and temporary files | Cleaning, not tuning, and destructive by design; out of scope for a reversible tool. |
| **profile-sync-daemon** | Keeps browser profiles in tmpfs | Per-user and browser-specific; not a system setting. |
| **GameMode** (Feral) | Raises performance while a game runs | Per-application, on demand; complements this program rather than overlapping it. |
| **Kernel command-line tuning** (`mitigations=off`, `amd_pstate=`, `preempt=`) | Boot parameters | Needs a bootloader change and can weaken security; too risky to automate. |

## Ideas

Larger changes that would add value, not part of 2.0.0:

1. **A tuned profile backend.** On machines with tuned, write
   `/etc/tuned/system-optimize/tuned.conf` (inheriting
   `throughput-performance`, with this program's sysctl and disk settings)
   and activate it, so one daemon owns everything and `tuned-adm` shows it.
2. **Profiles.** `--profile desktop|server|laptop|vm` choosing step sets and
   values, instead of deciding everything from the hardware.
3. **sched_ext.** Report whether the kernel supports it and which `scx`
   schedulers are installed; optionally enable one through `scx_loader`.
4. **ananicy-cpp in `--install-tools`**, with its community rules.
5. **A before/after check.** Run a short, safe benchmark (fio for a disk,
   a compile or stress-ng run for the CPU) before and after, so the change
   is measured, not assumed.
6. **AMD Ryzen AI / Strix specifics.** Report the integrated GPU's memory
   split (GTT and VRAM carve-out) and the platform profile, which matter
   for local AI workloads on these machines.
