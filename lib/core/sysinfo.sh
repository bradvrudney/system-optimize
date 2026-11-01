#!/usr/bin/env bash
# lib/core/sysinfo.sh - read-only probes: distribution, memory, swap, CPU,
# virtualisation, power source, disks, services and the package manager.
#
# Everything here only reads. Paths go through so_path, so that the tests
# can point SO_ROOT at a sandbox holding a fake /proc, /sys and /etc.
# Overrides (tests and odd machines): SO_VIRT (none or a hypervisor name),
# SO_CONTAINER (none or a container name), SO_PORTABLE (1/0), SO_PKG (dnf,
# apt, pacman, zypper or none), SO_KERNEL (a release string).

SO_OS_ID=""
SO_OS_NAME=""
SO_MEM_KB=0
SO_MEM_GB=0
SO_SWAP_KB=0
SO_SWAP_KIND="none"      # none | zram | disk
SO_CPUS=1
SO_CPU_VENDOR=""
SO_CPU_MODEL=""
SO_CPU_DRIVER=""
SO_KERNEL_RELEASE=""
SO_IS_VM=0
SO_VIRT_NAME="none"
SO_IN_CONTAINER=0
SO_CONTAINER_NAME="none"
SO_IS_PORTABLE=0
SO_HAS_SYSTEMD=0
SO_PKG_MANAGER="none"

# so_path PATH: PATH under SO_ROOT.
so_path() { printf '%s%s\n' "${SO_ROOT:-}" "$1"; }

# read_line FILE: the first line of FILE without control characters, or
# failure when FILE cannot be read.
read_line() {
  local line=""
  [ -r "$1" ] || return 1
  IFS= read -r line < "$1" || [ -n "$line" ] || return 1
  printf '%s\n' "${line//[^[:print:]]/}"
}

# os_value KEY [FILE]: the value of KEY in os-release, read line by line
# (never sourced). /etc/os-release first, /usr/lib/os-release otherwise.
os_value() {
  local key="$1" file="${2:-}" line k v
  if [ -z "$file" ]; then
    file=$(so_path /etc/os-release)
    [ -r "$file" ] || file=$(so_path /usr/lib/os-release)
  fi
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*([A-Z0-9_]+)=(.*)$ ]] || continue
    k="${BASH_REMATCH[1]}"
    v="${BASH_REMATCH[2]}"
    [ "$k" = "$key" ] || continue
    if [[ "$v" =~ ^\"(.*)\"$ ]] || [[ "$v" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi
    printf '%s\n' "${v//[^[:print:]]/}"
    return 0
  done < "$file"
  return 1
}

# meminfo_kb FIELD: a /proc/meminfo field in kB.
meminfo_kb() {
  local k v _unit
  while read -r k v _unit; do
    if [ "$k" = "$1:" ]; then printf '%s\n' "$v"; return 0; fi
  done < "$(so_path /proc/meminfo)"
  return 1
}

# swap_scan: total swap and its kind (zram when any zram device swaps).
swap_scan() {
  local dev _type size _rest total=0 kind=none
  local f
  f=$(so_path /proc/swaps)
  if [ -r "$f" ]; then
    while read -r dev _type size _rest; do
      [ "$dev" = Filename ] && continue
      [[ "$size" =~ ^[0-9]+$ ]] || continue
      total=$((total + size))
      if [[ "$dev" == /dev/zram* ]]; then
        kind=zram
      elif [ "$kind" = none ]; then
        kind=disk
      fi
    done < "$f"
  fi
  SO_SWAP_KB=$total
  SO_SWAP_KIND=$kind
}

# cpu_scan: vendor, model, number of online CPUs, frequency driver.
cpu_scan() {
  local f line n=0 d
  f=$(so_path /proc/cpuinfo)
  SO_CPU_VENDOR=""; SO_CPU_MODEL=""
  if [ -r "$f" ]; then
    while IFS= read -r line; do
      case "$line" in
        vendor_id*) [ -n "$SO_CPU_VENDOR" ] || SO_CPU_VENDOR="${line#*: }" ;;
        "model name"*) [ -n "$SO_CPU_MODEL" ] || SO_CPU_MODEL="${line#*: }" ;;
        processor*) n=$((n + 1)) ;;
      esac
    done < "$f"
  fi
  SO_CPU_VENDOR="${SO_CPU_VENDOR//[^[:print:]]/}"
  SO_CPU_MODEL="${SO_CPU_MODEL//[^[:print:]]/}"
  if [ "$n" -eq 0 ]; then
    for d in "$(so_path /sys/devices/system/cpu)"/cpu[0-9]*; do
      [ -d "$d" ] && n=$((n + 1))
    done
  fi
  [ "$n" -gt 0 ] || n=$(nproc 2>/dev/null || echo 1)
  SO_CPUS=$n
  SO_CPU_DRIVER=$(read_line "$(so_path /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)") || SO_CPU_DRIVER=""
}

# virt_scan: a virtual machine or a container? systemd-detect-virt when it
# is there, a few well-known files otherwise.
virt_scan() {
  local v
  if [ -n "${SO_VIRT:-}" ]; then
    v="$SO_VIRT"
  elif [ -z "${SO_ROOT:-}" ] && has_cmd systemd-detect-virt; then
    v=$(systemd-detect-virt --vm 2>/dev/null </dev/null) || v=none
  else
    v=none
    grep -qw hypervisor "$(so_path /proc/cpuinfo)" 2>/dev/null && v=vm
  fi
  SO_VIRT_NAME="${v:-none}"
  if [ "$SO_VIRT_NAME" = none ]; then SO_IS_VM=0; else SO_IS_VM=1; fi

  if [ -n "${SO_CONTAINER:-}" ]; then
    v="$SO_CONTAINER"
  elif [ -z "${SO_ROOT:-}" ] && has_cmd systemd-detect-virt; then
    v=$(systemd-detect-virt --container 2>/dev/null </dev/null) || v=none
  else
    v=none
    if [ -e "$(so_path /.dockerenv)" ]; then v=docker
    elif [ -e "$(so_path /run/.containerenv)" ]; then v=podman
    fi
  fi
  SO_CONTAINER_NAME="${v:-none}"
  if [ "$SO_CONTAINER_NAME" = none ]; then SO_IN_CONTAINER=0; else SO_IN_CONTAINER=1; fi
}

# portable_scan: does this machine run on a battery? A power supply of type
# Battery counts only when it powers the system: wireless mice, keyboards
# and game pads register batteries too, with scope "Device". A laptop-type
# DMI chassis counts as well.
portable_scan() {
  local ps type scope chassis
  if [ -n "${SO_PORTABLE:-}" ]; then
    SO_IS_PORTABLE=$(bool "$SO_PORTABLE" && echo 1 || echo 0)
    return 0
  fi
  SO_IS_PORTABLE=0
  for ps in "$(so_path /sys/class/power_supply)"/*; do
    [ -e "$ps/type" ] || continue
    type=$(read_line "$ps/type") || continue
    [ "$type" = Battery ] || continue
    scope=$(read_line "$ps/scope" 2>/dev/null) || scope=""
    [ "$scope" = Device ] && continue
    SO_IS_PORTABLE=1
    return 0
  done
  # SMBIOS chassis types: 8 portable, 9 laptop, 10 notebook, 14 sub
  # notebook, 30 tablet, 31 convertible, 32 detachable.
  chassis=$(read_line "$(so_path /sys/class/dmi/id/chassis_type)" 2>/dev/null) || chassis=""
  case "$chassis" in
    8|9|10|14|30|31|32) SO_IS_PORTABLE=1 ;;
  esac
}

# pkg_scan: the package manager used by --install-tools.
pkg_scan() {
  if [ -n "${SO_PKG:-}" ]; then SO_PKG_MANAGER="$SO_PKG"; return 0; fi
  if has_cmd dnf; then SO_PKG_MANAGER=dnf
  elif has_cmd apt-get; then SO_PKG_MANAGER=apt
  elif has_cmd pacman; then SO_PKG_MANAGER=pacman
  elif has_cmd zypper; then SO_PKG_MANAGER=zypper
  else SO_PKG_MANAGER=none
  fi
}

# sysinfo_detect: run every probe once.
sysinfo_detect() {
  SO_OS_ID=$(os_value ID) || SO_OS_ID=""
  SO_OS_NAME=$(os_value PRETTY_NAME) || SO_OS_NAME=""
  SO_MEM_KB=$(meminfo_kb MemTotal) || SO_MEM_KB=0
  [[ "$SO_MEM_KB" =~ ^[0-9]+$ ]] || SO_MEM_KB=0
  # Rounded up to whole GiB, and above 4 GiB to an even number: MemTotal
  # of a 32 GiB machine is about 31.3 GiB and of a 64 GiB one about 62.6
  # (firmware, the kernel and an integrated GPU keep some), and they are
  # still 32 and 64 GiB machines.
  SO_MEM_GB=$(((SO_MEM_KB + 1048575) / 1048576))
  [ "$SO_MEM_GB" -gt 4 ] && [ $((SO_MEM_GB % 2)) = 1 ] && SO_MEM_GB=$((SO_MEM_GB + 1))
  swap_scan
  cpu_scan
  SO_KERNEL_RELEASE="${SO_KERNEL:-$(uname -r 2>/dev/null || echo unknown)}"
  virt_scan
  portable_scan
  if [ -d "$(so_path /run/systemd/system)" ]; then SO_HAS_SYSTEMD=1; else SO_HAS_SYSTEMD=0; fi
  pkg_scan
}

# sysinfo_describe_os: one line for headers and the log.
sysinfo_describe_os() {
  printf '%s (kernel %s)\n' "${SO_OS_NAME:-${SO_OS_ID:-unknown Linux}}" "$SO_KERNEL_RELEASE"
}

# sysinfo_describe_hw: one line for headers and the log.
sysinfo_describe_hw() {
  local s
  s="${SO_CPUS} CPU(s)"
  [ -n "$SO_CPU_MODEL" ] && s+=" ($SO_CPU_MODEL)"
  s+=", ${SO_MEM_GB} GiB RAM"
  case "$SO_SWAP_KIND" in
    zram) s+=", zram swap" ;;
    disk) s+=", disk swap" ;;
    none) s+=", no swap" ;;
  esac
  [ "$SO_IS_VM" = 1 ] && s+=", VM ($SO_VIRT_NAME)"
  [ "$SO_IN_CONTAINER" = 1 ] && s+=", container ($SO_CONTAINER_NAME)"
  [ "$SO_IS_PORTABLE" = 1 ] && s+=", battery powered"
  printf '%s\n' "$s"
}

# ---------------------------------------------------------------------------
# Kernel settings and sysfs
# ---------------------------------------------------------------------------
# sysctl_file KEY: the /proc/sys file of a sysctl key.
sysctl_file() { so_path "/proc/sys/${1//.//}"; }

# sysctl_get KEY: the current value (tabs and runs of spaces become one
# space), or failure when this kernel does not have KEY.
sysctl_get() {
  local v
  v=$(read_line "$(sysctl_file "$1")") || return 1
  v="${v//$'\t'/ }"
  while [[ "$v" == *"  "* ]]; do v="${v//  / }"; done
  printf '%s\n' "$v"
}

# scheduler_active FILE: the bracketed entry of a queue/scheduler file.
scheduler_active() {
  local line
  line=$(read_line "$1") || return 1
  if [[ "$line" =~ \[([a-z0-9_-]+)\] ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "${line%% *}"
  fi
}

# scheduler_available FILE NAME: is NAME offered by a queue/scheduler file?
scheduler_available() {
  local line
  line=$(read_line "$1") || return 1
  line="${line//[\[\]]/}"
  [[ " $line " == *" $2 "* ]]
}

# disk_list: the whole disks worth tuning, one name per line. Loop, RAM,
# zram, device-mapper, md, optical, network block devices and removable
# media are left alone.
disk_list() {
  local d name
  for d in "$(so_path /sys/block)"/*; do
    name="${d##*/}"
    case "$name" in
      loop*|ram*|zram*|dm-*|md*|sr*|nbd*|fd*|'*') continue ;;
    esac
    [ -r "$d/queue/scheduler" ] || continue
    [ "$(read_line "$d/removable" 2>/dev/null)" = 1 ] && continue
    printf '%s\n' "$name"
  done
}

# disk_rotational NAME: 1 for a spinning disk, 0 for solid state.
disk_rotational() {
  read_line "$(so_path "/sys/block/$1/queue/rotational")" 2>/dev/null || echo 1
}

# any_ssd: is there at least one solid-state disk?
any_ssd() {
  local d
  while IFS= read -r d; do
    [ "$(disk_rotational "$d")" = 0 ] && return 0
  done < <(disk_list)
  return 1
}

# ---------------------------------------------------------------------------
# Services (systemd)
# ---------------------------------------------------------------------------
# unit_exists UNIT: systemd knows UNIT (a unit file is installed).
unit_exists() {
  [ "$SO_HAS_SYSTEMD" = 1 ] || return 1
  has_cmd systemctl || return 1
  local out
  out=$(SO_RUN_TIMEOUT=30 run systemctl list-unit-files --no-legend "$1" 2>/dev/null) || return 1
  [[ "$out" == "$1"* ]]
}

# unit_active UNIT: UNIT is running.
unit_active() {
  [ "$SO_HAS_SYSTEMD" = 1 ] && has_cmd systemctl || return 1
  run systemctl is-active --quiet "$1" >/dev/null 2>&1
}

# unit_enabled_state UNIT: enabled, disabled, static, masked, ... or absent.
unit_enabled_state() {
  local s
  if [ "$SO_HAS_SYSTEMD" != 1 ] || ! has_cmd systemctl; then echo absent; return 0; fi
  s=$(run systemctl is-enabled "$1" 2>/dev/null) || true
  s="${s%%$'\n'*}"
  printf '%s\n' "${s:-absent}"
}

# ---------------------------------------------------------------------------
# Packages (for --install-tools and --undo)
# ---------------------------------------------------------------------------
# pkg_installed NAME
pkg_installed() {
  case "$SO_PKG_MANAGER" in
    dnf|zypper) run rpm -q --quiet "$1" >/dev/null 2>&1 ;;
    apt) [ "$(run dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = "install ok installed" ] ;;
    pacman) run pacman -Q "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# pkg_install NAME / pkg_remove NAME: through the package manager, with the
# package timeout. They change the system: callers check SO_DRY_RUN first.
pkg_install() {
  local -a cmd
  case "$SO_PKG_MANAGER" in
    dnf) cmd=(dnf install -y "$1") ;;
    apt) cmd=(env DEBIAN_FRONTEND=noninteractive apt-get install -y "$1") ;;
    pacman) cmd=(pacman -S --noconfirm --needed "$1") ;;
    zypper) cmd=(zypper --non-interactive install "$1") ;;
    *) log_error "no supported package manager (dnf, apt, pacman, zypper)"; return 1 ;;
  esac
  SO_RUN_TIMEOUT="$SO_PKG_TIMEOUT" run "${cmd[@]}"
}

pkg_remove() {
  local -a cmd
  case "$SO_PKG_MANAGER" in
    dnf) cmd=(dnf remove -y "$1") ;;
    apt) cmd=(env DEBIAN_FRONTEND=noninteractive apt-get remove -y "$1") ;;
    pacman) cmd=(pacman -R --noconfirm "$1") ;;
    zypper) cmd=(zypper --non-interactive remove "$1") ;;
    *) log_error "no supported package manager (dnf, apt, pacman, zypper)"; return 1 ;;
  esac
  SO_RUN_TIMEOUT="$SO_PKG_TIMEOUT" run "${cmd[@]}"
}

# pkg_name TOOL: the package that provides TOOL on this distribution.
pkg_name() {
  case "$1:$SO_PKG_MANAGER" in
    zram-generator:apt) echo systemd-zram-generator ;;
    *) echo "$1" ;;
  esac
}
