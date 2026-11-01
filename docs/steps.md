# The steps of a run

A run is seven steps, always in this order. Each prints what it changes and
ends with one result: ok (nothing to do), updated, skipped (with the
reason), dry-run, warn or failed. A failed step does not stop the others;
the run then exits 1. `--only` and `--skip` choose steps by name.

Every change is recorded in the run's snapshot before it is made (see
[Undo and snapshots](../README.md#undo-and-snapshots)). "Records" below
says what.

## legacy

Looks for the three files system-optimize 1.x wrote, each recognised by a
line only 1.x wrote (a file with the same name but other content is left
alone):

* `/etc/sysctl.d/99-hardware-optimization.conf`
* `/etc/security/limits.d/99-performance.conf`
* `/etc/udev/rules.d/60-disk-scheduler.rules`

and backs up and removes them. The steps below write their replacements.
While 1.x's sysctl file is there, the `sysctl` step writes its "raise only"
keys even when the current value is already high enough, since 1.x's file
may be what raised them.

Records: a copy of each file. Undo puts them back.

## sysctl

Writes `/etc/sysctl.d/99-system-optimize.conf` and loads it with
`sysctl -e -p FILE` (only this file; `-e` so a key the kernel does not have
is not an error). The settings depend on the machine:

* Limits (`fs.inotify.*`, `fs.file-max`, `net.core.somaxconn`,
  `net.core.netdev_max_backlog`, `net.ipv4.tcp_max_syn_backlog`) are raise
  only: left out when the current value is already at least as high, unless
  this program's own file is what set them.
* TCP: `tcp_slow_start_after_idle=0`, `tcp_fin_timeout=15`,
  `tcp_tw_reuse=1`; `fq` and `bbr` when the kernel lists BBR or has the
  `tcp_bbr` module.
* Swap, by its kind (read from `/proc/swaps`): zram gets
  `vm.swappiness=180` and `vm.page-cluster=0`; disk swap gets 10 (32 GiB
  RAM and up), 20 (8 GiB and up) or 60; no swap leaves swappiness alone.
* `vm.vfs_cache_pressure`: 50 from 32 GiB, 75 from 8 GiB, default below.
* Writeback: from 16 GiB fixed sizes (`dirty_background_bytes` 256 MiB,
  `dirty_bytes` 1 GiB); below that ratios (5/15 from 8 GiB, else 10/20).

RAM is MemTotal rounded up to whole GiB, and above 4 GiB to an even
number, so a 32 GiB machine counts as 32, not 31.

Records: the value of every key it sets, and all four writeback keys (a
`*_bytes` key and its `*_ratio` partner zero each other). Undo writes them
back with `sysctl -w` and removes the file.

Skipped in a container: the kernel belongs to the host.

## io

For each whole local disk (not loop, zram, device-mapper, md, optical or
removable devices):

| Disk | Scheduler | Read-ahead |
|------|-----------|------------|
| NVMe | `none` | unchanged |
| SATA/SAS SSD, eMMC | `mq-deadline` | 256 KiB |
| Spinning disk | `bfq` (when the kernel has it) | 1024 KiB |

sets the values now through sysfs and writes
`/etc/udev/rules.d/60-system-optimize-io.rules` so they come back after a
reboot, then reloads the udev rules.

Records: each sysfs value before, and the rule file. Undo writes the values
back, removes the rule and reloads udev.

Skipped in a VM or container: virtual disks often claim to be rotational,
and the host schedules the real I/O.

## cpu

Sets the performance power profile, by the first of:

1. `powerprofilesctl` answers (power-profiles-daemon, or tuned-ppd on Fedora
   41 and later): `powerprofilesctl set performance`, if the machine offers
   that profile. The daemon keeps it across reboots and the desktop's power
   menu shows it.
2. tuned runs: `tuned-adm profile throughput-performance`.
3. Neither: the `performance` cpufreq governor on every CPU that offers it,
   until the next reboot.

Records: the profile, tuned profile or each governor before. Undo sets them
back.

Skipped on a battery-powered machine (a system battery or a laptop-type DMI
chassis; device batteries such as a wireless mouse's do not count), in a VM
and in a container. Skip it on a desktop too (`--skip cpu`) if you prefer
the balanced profile's lower power use and noise; the performance profile
mainly helps sustained loads.

## limits

Writes `/etc/security/limits.d/90-system-optimize.conf`: open files soft
65535 and hard 524288, for all users and root. Applies to new logins
through `pam_limits`; services started by systemd have their own limits
(`LimitNOFILE=` in the unit). A soft limit above 1024 can break the rare
old program that uses `select()` with more than 1024 descriptors.

Records: the file (or that there was none). Undo removes it.

Skipped when there is no `/etc/security`.

## trim

Enables `fstrim.timer` (weekly `fstrim` of mounted filesystems that support
it) when there is at least one SSD.

Records: the timer's state before. Undo disables it again.

Skipped without an SSD, in a VM or container, when the timer does not
exist, and when it is masked (someone decided against it).

## tools

Reports which helpers run, warns about pairs that fight (TLP or
auto-cpufreq with power-profiles-daemon or tuned; systemd-oomd with
earlyoom or nohang), and recommends what is missing:

* an OOM daemon when none runs: systemd-oomd when the system has it, else
  earlyoom;
* irqbalance on a machine with more than one CPU (not in a VM);
* zram-generator when there is no swap at all.

With `--install-tools` (or `INSTALL_TOOLS=1`) it sets them up: installs the
package with the system's package manager (dnf, apt, pacman or zypper),
enables the unit, and for zram writes `/etc/systemd/zram-generator.conf`
(`zram-size = min(ram / 2, 8192)`, zstd) and starts it.

Records: each package it installed, each unit's state before, the zram
config. Undo removes the packages it installed, sets the units back and
removes the config.

See [tools.md](tools.md) for what each helper does.
