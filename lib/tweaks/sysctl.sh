#!/usr/bin/env bash
# lib/tweaks/sysctl.sh - step "sysctl": kernel settings sized to the
# machine, in /etc/sysctl.d/99-system-optimize.conf.
#
# What changed from 1.x and why:
#   * Limits (file-max, inotify, socket backlogs) are only ever raised. 1.x
#     wrote fs.file-max = 2097152, which on current systemd machines is a
#     big step down from the default (2^63-1).
#   * vm.swappiness follows the kind of swap. With zram (Fedora's default
#     since 33) swapping is cheap, so the value is high (180, as the kernel
#     documentation, ArchWiki and Pop!_OS suggest for in-memory swap) with
#     page-cluster 0; 1.x set 10 there, which makes zram nearly useless.
#     With disk swap the RAM tiers of 1.x stay; without swap it is left
#     alone.
#   * Writeback on machines with 16 GiB or more uses fixed sizes
#     (dirty_background_bytes 256 MiB, dirty_bytes 1 GiB): a percentage of
#     64 or 128 GiB lets gigabytes of dirty pages pile up and then stall.
#   * RAM tiers use the size rounded up: a 32 GiB machine reports ~31.3
#     GiB, which 1.x put in the 8-31 GiB tier.
#   * BBR is used when the kernel has it; the kernel loads tcp_bbr itself
#     when sysctl asks for it.
#   * Only this file is loaded (sysctl -e -p FILE), not every file on the
#     system, and an unknown key does not abort the run.

SO_SYSCTL_CONF=/etc/sysctl.d/99-system-optimize.conf

# _sysctl_bbr_available: does this kernel offer BBR?
_sysctl_bbr_available() {
  local avail
  avail=$(sysctl_get net.ipv4.tcp_available_congestion_control 2>/dev/null) || avail=""
  [[ " $avail " == *" bbr "* ]] && return 0
  has_cmd modinfo && run modinfo -n tcp_bbr >/dev/null 2>&1
}

# sysctl_plan: the settings for this machine, one "KEY<TAB>VALUE<TAB>MODE<TAB>WHY"
# line each. MODE is "raise" (only when the current value is lower) or "set".
sysctl_plan() {
  local gb="$SO_MEM_GB"
  _p() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }
  _p fs.inotify.max_user_watches 524288 raise "file watchers (IDEs, sync tools)"
  _p fs.inotify.max_user_instances 1024 raise "file watchers (IDEs, sync tools)"
  _p fs.file-max 2097152 raise "system-wide open files"
  _p net.core.somaxconn 4096 raise "listen backlog"
  _p net.core.netdev_max_backlog 16384 raise "packets queued per CPU"
  _p net.ipv4.tcp_max_syn_backlog 8192 raise "half-open connections"
  _p net.ipv4.tcp_slow_start_after_idle 0 set "keep the congestion window on idle connections"
  _p net.ipv4.tcp_fin_timeout 15 set "release closed connections sooner"
  _p net.ipv4.tcp_tw_reuse 1 set "reuse TIME-WAIT sockets for new outgoing connections"
  if _sysctl_bbr_available; then
    _p net.core.default_qdisc fq set "fair queueing, paced for BBR"
    _p net.ipv4.tcp_congestion_control bbr set "BBR congestion control"
  fi
  case "$SO_SWAP_KIND" in
    zram)
      _p vm.swappiness 180 set "zram swap: swapping to compressed RAM is cheap"
      _p vm.page-cluster 0 set "zram swap: no read-ahead from swap" ;;
    disk)
      if [ "$gb" -ge 32 ]; then _p vm.swappiness 10 set "disk swap, ${gb} GiB RAM"
      elif [ "$gb" -ge 8 ]; then _p vm.swappiness 20 set "disk swap, ${gb} GiB RAM"
      else _p vm.swappiness 60 set "disk swap, ${gb} GiB RAM"
      fi ;;
  esac
  if [ "$gb" -ge 32 ]; then _p vm.vfs_cache_pressure 50 set "keep directory and inode caches (${gb} GiB RAM)"
  elif [ "$gb" -ge 8 ]; then _p vm.vfs_cache_pressure 75 set "keep directory and inode caches (${gb} GiB RAM)"
  fi
  if [ "$gb" -ge 16 ]; then
    _p vm.dirty_background_bytes 268435456 set "start writeback at 256 MiB of dirty pages"
    _p vm.dirty_bytes 1073741824 set "block writers at 1 GiB of dirty pages"
  elif [ "$gb" -ge 8 ]; then
    _p vm.dirty_background_ratio 5 set "writeback (${gb} GiB RAM)"
    _p vm.dirty_ratio 15 set "writeback (${gb} GiB RAM)"
  else
    _p vm.dirty_background_ratio 10 set "writeback (${gb} GiB RAM)"
    _p vm.dirty_ratio 20 set "writeback (${gb} GiB RAM)"
  fi
  unset -f _p
}

# sysctl_wanted: the plan filtered for this kernel: keys it does not have
# are dropped, and "raise" keys whose current value is already as high
# (unless 1.x's file is about to be removed, or our own file is what set
# it: either may be what raised them). Same format, with the current value
# added as a fifth field.
sysctl_wanted() {
  local key value mode why cur legacy=0 ours
  legacy_sysctl_present && legacy=1
  ours=$(sed -n 's/^\([a-z0-9_.-]*\) = .*/\1/p' "$(so_path "$SO_SYSCTL_CONF")" 2>/dev/null | tr '\n' ' ')
  while IFS=$'\t' read -r key value mode why; do
    cur=$(sysctl_get "$key") || { log_detail "sysctl $key: not in this kernel"; continue; }
    if [ "$mode" = raise ] && [ "$legacy" = 0 ] && [[ " $ours " != *" $key "* ]] &&
       [[ "$cur" =~ ^[0-9]+$ ]] && [ "${#cur}" -ge "${#value}" ] &&
       { [ "${#cur}" -gt "${#value}" ] || [ "$cur" -ge "$value" ]; }; then
      log_detail "sysctl $key: $cur is already at least $value"
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$value" "$mode" "$why" "$cur"
  done < <(sysctl_plan)
}

# sysctl_conf_content: the file, from sysctl_wanted's lines on stdin.
sysctl_conf_content() {
  local key value _mode why _cur
  printf '# Written by system-optimize (%s). Undo: system-optimize --undo\n' "$(version_string)"
  printf '# Sized for: %s\n' "$(sysinfo_describe_hw)"
  while IFS=$'\t' read -r key value _mode why _cur; do
    printf '\n# %s\n%s = %s\n' "$why" "$key" "$value"
  done
}

tweak_sysctl() {
  local tmp key value mode why cur changed=0 rc=0
  local -a lines=()
  if [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "in a container: kernel settings belong to the host"
    return 0
  fi
  mapfile -t lines < <(sysctl_wanted)
  if [ ${#lines[@]} -eq 0 ]; then
    step_skip "nothing to set on this kernel"
    return 0
  fi
  for key in "${lines[@]}"; do
    IFS=$'\t' read -r key value mode why cur <<< "$key"
    if [ "$cur" != "$value" ]; then
      changed=$((changed + 1))
      log_info "$key: $cur -> $value  ($why)"
    else
      log_detail "$key: already $value"
    fi
  done
  tmp=$(tmp_file) || return 1
  printf '%s\n' "${lines[@]}" | sysctl_conf_content > "$tmp"
  install_file "$SO_SYSCTL_CONF" 0644 < "$tmp" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || { step_fail "could not write $SO_SYSCTL_CONF"; return 1; }

  if [ "$changed" = 0 ]; then
    if [ "$rc" = 3 ]; then step_ok "${#lines[@]} settings already in place"
    elif [ "$SO_DRY_RUN" = 1 ]; then step_dry "values already in place; would write $SO_SYSCTL_CONF to keep them"
    else step_updated "values already in place; wrote $SO_SYSCTL_CONF to keep them"
    fi
    return 0
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would change $changed setting(s) and load $SO_SYSCTL_CONF"
    return 0
  fi
  # The values before, for --undo. The four writeback keys go together:
  # setting a *_bytes key zeroes its *_ratio partner and the other way round.
  for key in "${lines[@]}"; do
    IFS=$'\t' read -r key value mode why cur <<< "$key"
    snap_record sysctl "$key" "$cur" || return 1
  done
  for key in vm.dirty_background_ratio vm.dirty_ratio vm.dirty_background_bytes vm.dirty_bytes; do
    cur=$(sysctl_get "$key") && snap_record sysctl "$key" "$cur"
  done
  if ! run sysctl -e -p "$(so_path "$SO_SYSCTL_CONF")" >/dev/null; then
    step_warn "wrote $SO_SYSCTL_CONF but the kernel refused some values (see the log); they apply after a reboot if at all"
    return 0
  fi
  step_updated "changed $changed setting(s); saved in $SO_SYSCTL_CONF"
}
