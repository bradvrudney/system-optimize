# system-optimize

**Tune a Linux machine for its hardware, and be able to take it back.**
Kernel settings sized to the machine's RAM and swap, disk I/O schedulers by
disk type, the CPU power profile, open-file limits and SSD trim, plus a
report of the well-known helpers (power-profiles-daemon, tuned, systemd-oomd,
earlyoom, zram, irqbalance) that can install the missing ones.

```
$ system-optimize --status        # what the machine is, what is set now, what a run would change
$ system-optimize --dry-run       # every change a run would make; nothing changes
$ sudo system-optimize            # apply, after a [y/N]; a snapshot is saved first
$ sudo system-optimize --undo     # put everything back the way it was
```

It is plain bash (4.4 or newer) with coreutils, `grep` and `sed`. It works on
Fedora, Debian and Ubuntu, Arch and openSUSE (CI runs it in each), and on any
other systemd distribution.

This is a modular rewrite of [Ed Reel's](https://github.com/uberhacker)
[system-optimize](https://github.com/uberhacker/system-optimize). The idea
and the steps are his: look at the hardware, then set the kernel, disks and
CPU to match. What changed, and why, is under
[Changes from the original](#changes-from-the-original).

### Highlights

* **Everything can be undone.** Every real run first saves a snapshot of
  the files it replaces and the values it changes (sysctl values, disk
  schedulers, the power profile, systemd units, packages it installed).
  `--undo` restores the newest one; `--list-snapshots` shows them all.
* **Works with the machine's own power management, not against it.** On a
  machine with power-profiles-daemon (or Fedora's tuned-ppd) or tuned, the
  CPU step asks the daemon for its performance profile instead of writing
  the governor behind its back. Battery-powered machines are left alone.
* **zram aware.** Fedora and many others swap to compressed RAM; the
  swappiness for that is high (180), not low.
* **Raises limits, never lowers them.** Settings like `fs.file-max` are
  only written when the current value is lower.
* **A read-only report** (`--status`) that needs no root, and **a real dry
  run** (`--dry-run`) that prints every change.
* **Safe in containers and VMs.** The kernel, disk and CPU steps skip
  themselves where the host owns those; a real run inside a container is
  refused without `--force`.
* **A log of every run**, with each command's output, exit status and
  timing, in a private directory.
* **Configuration** from a small `KEY=value` file, the environment or flags,
  parsed and never sourced.
* **`--self-update`**, verifying a published checksum before the single
  file is replaced.

## WARNING

These are system-wide changes made as root. Read what a run would do
(`--dry-run`) before you run it, and keep in mind that `--undo` restores what
this program recorded, nothing else. Nobody is responsible if you break your
system.

## Contents

* [Quick start](#quick-start)
* [What it does](#what-it-does)
* [Installation](#installation)
* [Usage](#usage)
* [Undo and snapshots](#undo-and-snapshots)
* [Helpers it knows about](#helpers-it-knows-about)
* [Configuration](#configuration)
* [Logs](#logs)
* [Self-update](#self-update)
* [Development](#development)
* [Changes from the original](#changes-from-the-original)
* [License](#license)

## Quick start

```bash
git clone https://github.com/uberhacker/system-optimize.git
cd system-optimize
./install.sh                       # /usr/local/bin/system-optimize (asks for sudo)
system-optimize --status           # no root needed
system-optimize --dry-run          # no root needed
sudo system-optimize               # apply
sudo system-optimize --undo        # if you want it back
```

## What it does

A run is seven steps, in this order. Each one prints what it changes;
`--only` and `--skip` choose among them. [`docs/steps.md`](docs/steps.md)
has the details of each.

| Step | What it changes | Skipped when |
|------|-----------------|--------------|
| `legacy` | Backs up and removes the three files system-optimize 1.x wrote, so the steps below replace them | none of them is there |
| `sysctl` | `/etc/sysctl.d/99-system-optimize.conf`, loaded at once: file watchers, network backlogs, BBR, swappiness for the kind of swap, writeback sizes | in a container |
| `io` | Scheduler and read-ahead for each disk now, and `/etc/udev/rules.d/60-system-optimize-io.rules` for later boots: NVMe `none`, SSD `mq-deadline`, HDD `bfq` | VM or container |
| `cpu` | The performance profile: `powerprofilesctl set performance`, else `tuned-adm profile throughput-performance`, else the `performance` governor until reboot | battery powered, VM or container |
| `limits` | `/etc/security/limits.d/90-system-optimize.conf`: open files 65535 soft, 524288 hard, for new logins | no `/etc/security` |
| `trim` | Enables the weekly `fstrim.timer` | no SSD, VM, container, or the timer is masked |
| `tools` | Reports helpers and conflicts between them; with `--install-tools` installs and enables the missing ones | never |

The kernel settings for a machine like the test machine (32 GiB RAM, zram
swap, BBR available):

| Setting | Value | Why |
|---------|-------|-----|
| `fs.inotify.max_user_watches` | 524288 (raise only) | IDEs and sync tools watch many files |
| `fs.inotify.max_user_instances` | 1024 (raise only) | |
| `fs.file-max` | 2097152 (raise only) | systemd already sets it far higher; left alone then |
| `net.core.somaxconn` | 4096 (raise only) | listen backlog |
| `net.core.netdev_max_backlog` | 16384 (raise only) | packets queued per CPU |
| `net.ipv4.tcp_max_syn_backlog` | 8192 (raise only) | half-open connections |
| `net.ipv4.tcp_slow_start_after_idle` | 0 | idle connections keep their speed |
| `net.ipv4.tcp_fin_timeout` | 15 | closed connections released sooner |
| `net.ipv4.tcp_tw_reuse` | 1 | TIME-WAIT reuse for outgoing connections |
| `net.core.default_qdisc`, `net.ipv4.tcp_congestion_control` | `fq`, `bbr` | only when the kernel has BBR |
| `vm.swappiness`, `vm.page-cluster` | 180, 0 with zram; 10, 20 or 60 with disk swap by RAM; untouched without swap | |
| `vm.vfs_cache_pressure` | 50 (32 GiB and up), 75 (8 GiB and up) | keep directory and inode caches |
| `vm.dirty_background_bytes`, `vm.dirty_bytes` | 256 MiB, 1 GiB (16 GiB and up) | a percentage of a large RAM lets gigabytes pile up, then stall |
| `vm.dirty_background_ratio`, `vm.dirty_ratio` | 5, 15 (8 GiB and up); 10, 20 below | |

`system-optimize --status` prints this table for your machine, with the
current value of each setting next to the one a run would set.

## Installation

### Single file (default)

```bash
./install.sh                # /usr/local/bin/system-optimize, uses sudo
./install.sh --user         # ~/.local/bin/system-optimize, no sudo
./install.sh --prefix DIR   # DIR/bin/system-optimize
./install.sh --uninstall    # remove it (add --user or --prefix as installed)
```

`install.sh` builds the single file from the checkout (`build.sh`: the
modules concatenated, nothing compiled) and installs it with its bash
completion. A copy of system-optimize 1.x at the same path is replaced.

Without cloning, take the file from the latest release and check it:

```bash
curl -fsSLO https://github.com/uberhacker/system-optimize/releases/latest/download/system-optimize
curl -fsSLO https://github.com/uberhacker/system-optimize/releases/latest/download/system-optimize.sha256
sha256sum -c system-optimize.sha256 && sudo install -m 0755 system-optimize /usr/local/bin/
```

### The tree layout

`./install.sh --tree` installs the whole checkout to
`PREFIX/share/system-optimize` (with `.git`) and links the command into
`PREFIX/bin`. `--self-update` then follows a branch instead of the releases.

### Tab completion

The installer puts the completion where bash-completion finds it. By hand:
`source <(system-optimize --completion bash)`.

## Usage

```
system-optimize [options]                 apply the optimizations
system-optimize --dry-run [options]       show what would change
system-optimize --status                  report: hardware, settings, tools, snapshots
system-optimize --undo [ID]               restore the newest (or the given) snapshot
system-optimize --list-snapshots          list the snapshots --undo can restore
system-optimize --self-update [--dry-run] [--source URL]
```

| Option | |
|--------|---|
| `-n`, `--dry-run` | print what would change; change nothing (1.x's `-d` still works) |
| `-y`, `--yes` | answer the confirmation; required without a terminal |
| `--only LIST`, `--skip LIST` | steps, comma separated: `legacy,sysctl,io,cpu,limits,trim,tools` |
| `--install-tools` | install and enable the recommended helpers that are missing |
| `--force` | run inside a container anyway (only the container's own files change) |
| `-v`, `--verbose` / `-q`, `--quiet` | every command / status lines only |
| `--color WHEN`, `--no-color` | `auto` (default), `always`, `never` |
| `--timeout SECONDS` | per-command timeout (default 300) |
| `--config FILE` | this config file instead of the user's |
| `--log FILE`, `--no-log` | where this run's log goes, or none |

Examples:

```bash
system-optimize --dry-run --skip cpu          # everything but the power profile
sudo system-optimize --only sysctl,trim -y    # unattended, two steps
sudo system-optimize --install-tools          # and set up earlyoom, irqbalance, zram
```

## Undo and snapshots

A real run saves a snapshot in `/var/lib/system-optimize/snapshots/<time>/`
before the first change: a copy of every file it replaces or removes (or a
note that the file did not exist), the value of every sysctl and sysfs
setting it changes, the power profile, the state of every systemd unit it
enables, and the packages it installs. A run that changes nothing saves
nothing.

```bash
system-optimize --list-snapshots
sudo system-optimize --undo                     # the newest snapshot not yet undone
sudo system-optimize --undo 20261101-153131     # a given one
sudo system-optimize --undo --dry-run           # what it would restore
```

Undo works newest change first. Files are restored or removed, values
written back, the profile and units set back, and installed packages
removed. Running `--undo` again goes to the snapshot before. Lines in a
snapshot that do not look like what this program writes are skipped and
reported, never acted on.

What undo cannot do: the performance governor written without a profile
daemon and sysfs values only last until reboot anyway; open-file limits apply
to new logins, so sessions started in between keep theirs until you log
out.

## Helpers it knows about

`--status` and the `tools` step report these, and warn when two of them
fight. [`docs/tools.md`](docs/tools.md) has the survey behind the list:
what each does, when it helps, and what was left out.

| Helper | What it is for | What system-optimize does |
|--------|----------------|---------------------------|
| power-profiles-daemon / tuned-ppd | power profiles the desktop shows | the `cpu` step uses it |
| tuned | profile-based system tuning (Fedora, RHEL) | the `cpu` step uses it when there is no PPD |
| systemd-oomd / earlyoom | end runaway memory use before the desktop freezes | recommends one; `--install-tools` enables oomd or installs earlyoom |
| zram-generator | compressed swap in RAM | recommends it when there is no swap; `--install-tools` sets it up |
| irqbalance | spreads hardware interrupts over the CPUs | recommends it; `--install-tools` installs it |
| fstrim.timer | weekly SSD trim | the `trim` step enables it |
| TLP, auto-cpufreq | laptop power managers | warns when one runs next to PPD or tuned |

## Configuration

Settings come from, lowest to highest: built-in defaults,
`/etc/system-optimize.conf`, `~/.config/system-optimize/config`, environment
variables of the same name, flags. Files are `KEY=value` lines, parsed and
never sourced; [`config.example`](config.example) lists every key.

```ini
SKIP=cpu
INSTALL_TOOLS=1
LOG_KEEP=10
```

`sudo` reads `/etc/system-optimize.conf` (root's own config, not yours);
pass `--config FILE` to use another.

## Logs

Every run except `--status`, `--list-snapshots`, `--help` and `--version`
writes a log: `/var/log/system-optimize/` when run as root,
`~/.local/state/system-optimize/` otherwise. The log has a header (version,
host, OS, hardware, the command line, non-default settings), every message
with a timestamp, and each command's output, exit status and duration.
`latest.log` points at the newest; the newest 20 are kept (`LOG_KEEP`).
Files are 0600 in a 0700 directory.

## Self-update

```bash
sudo system-optimize --self-update --dry-run
sudo system-optimize --self-update
```

* A single file downloads the latest release asset and its `.sha256`,
  refuses it if the checksum is missing or wrong or the file is not a
  single-file build, and replaces itself in one rename.
* A git checkout fast-forwards (refusing local changes); `--branch` switches.
* A tree installation downloads the branch tarball and swaps it in.
* `SELF_UPDATE_REPO` (or `--source`) follows a fork, `https://` only.

## Development

```bash
make check     # tests/lint.sh (bash -n, shellcheck) and tests/run.sh (bats)
make smoke     # tests/install-smoke.sh: install.sh into a temp prefix, then run
make build     # dist/system-optimize
```

The tests run against a fake machine in a temporary directory (`SO_ROOT`):
a fake `/proc`, `/sys` and `/etc`, and stubs for `sysctl`, `systemctl`,
`udevadm`, `powerprofilesctl`, `tuned-adm` and the package managers. Nothing
on the machine running them changes. The same suite runs against the modular
`bin/` and the single-file build. [`CONTRIBUTING.md`](CONTRIBUTING.md) has
the layout and the rules modules follow. Push a `v*` tag to publish a
release (the single file and its checksum).

## Changes from the original

Ed's 1.x was one script. 2.0.0 keeps its steps and its `-d` flag and
`system-optimize` path, and changes these, mostly because of what they would
do on a current Fedora desktop:

* **Undo.** 1.x wrote three files and changed sysfs values with no record of
  what was there before. Now every change is recorded and `--undo` restores
  it. Running 2.0 over 1.x backs up and replaces 1.x's files.
* **CPU governor.** 1.x wrote `performance` to every CPU's governor on any
  machine it did not think was a laptop. On Fedora 41 and later (tuned-ppd)
  and anywhere power-profiles-daemon runs, the daemon owns that setting:
  writing it directly is overridden again, and on `amd-pstate-epp` and
  `intel_pstate` it also pins the energy preference behind the daemon's
  back. 2.0 asks the daemon. It also lasted only until the next reboot.
* **Laptop detection.** 1.x set `schedutil` instead of `performance` when
  it saw any battery, including the battery of a wireless mouse or keyboard
  (`scope=Device`), so a desktop with one was treated as a laptop. 2.0
  ignores device batteries, also reads the DMI chassis type, and leaves a
  battery-powered machine's CPU to its power manager altogether.
* **Swappiness with zram.** 1.x set `vm.swappiness=10` on 32 GiB and up,
  which on Fedora (zram swap by default since 33) keeps the compressed swap
  nearly unused. 2.0 sets 180 and `page-cluster=0` for zram, as the kernel
  documentation suggests; disk swap keeps 1.x's tiers.
* **`fs.file-max`.** 1.x set 2097152. systemd sets it to the maximum
  (9223372036854775807) at boot, so 1.x lowered it. 2.0 only raises.
* **Process limits.** 1.x set a hard `nproc` limit of 65535 for every user,
  a cap where there was none. 2.0 leaves `nproc` alone and raises only open
  files (soft 65535, hard 524288), noting that systemd services have their
  own limits.
* **Writeback on large RAM.** 1.x used percentages (`dirty_ratio` 10 of 64
  or 128 GiB is 6 to 13 GiB of dirty pages before writers block, and a long
  stall when they are flushed). 2.0 uses fixed sizes from 16 GiB.
* **RAM tiers.** 1.x truncated the RAM size, so a 32 GiB machine (MemTotal
  about 31.3 GiB) fell in the lower tier. 2.0 rounds up.
* **udev rule.** 1.x's `sd[a-z]` missed `sdaa` and later; read-ahead was
  not persisted; `bfq` was set even where the kernel lacked it; virtio disks
  in VMs (which claim to be rotational) got `bfq`. 2.0 fixes each and skips
  VMs and removable media.
* **Runs.** 1.x used `set -e` and stopped half way on the first error after
  some files were written, reloaded every sysctl file on the system
  (`sysctl --system`), needed root even for a dry run, and accepted unknown
  options. 2.0 runs each step on its own, loads only its own file, dry-runs
  and reports without root, and rejects unknown options.
* **Install.** 1.x was installed with `curl | sudo tee` and no checksum. 2.0
  has `install.sh`, release assets with a `.sha256`, and `--self-update`.
* **Containers.** 1.x would write host-level settings from inside a
  container. 2.0 refuses without `--force`, and even then skips the kernel,
  disk and CPU steps.
* New: `--status`, `--only`/`--skip`, the helpers report and
  `--install-tools`, BBR, `fstrim.timer`, logs, configuration, tests and CI.

## License

GPL-3.0, as the original. See [LICENSE](LICENSE).
