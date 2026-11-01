#!/usr/bin/env bash
# lib/tweaks/trim.sh - step "trim": weekly TRIM for SSDs (new in 2.0).
#
# util-linux ships fstrim.timer, which trims every mounted filesystem that
# supports it once a week. Fedora, Ubuntu and openSUSE enable it; Arch,
# Debian and others leave it off. Continuous trimming (the "discard" mount
# option) is not touched.

tweak_trim() {
  local state
  if [ "$SO_IS_VM" = 1 ] || [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "virtual machine or container"
    return 0
  fi
  if ! any_ssd; then
    step_skip "no solid-state disks"
    return 0
  fi
  if ! unit_exists fstrim.timer; then
    step_skip "no fstrim.timer (util-linux without systemd units)"
    return 0
  fi
  state=$(unit_enabled_state fstrim.timer)
  if [ "$state" = enabled ]; then
    step_ok "fstrim.timer already enabled"
    return 0
  fi
  if [ "$state" = masked ]; then
    step_skip "fstrim.timer is masked; left alone"
    return 0
  fi
  unit_set fstrim.timer enable || { step_fail "could not enable fstrim.timer"; return 1; }
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would enable the weekly fstrim.timer"
  else
    step_updated "enabled the weekly fstrim.timer"
  fi
}
