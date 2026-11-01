#!/usr/bin/env bash
# lib/tweaks/boot.sh - opt-in steps: journal, flatpak, waitonline, firmware.
# PLACEHOLDER: replaced by the real module.

step_def journal opt-in journal_step '' \
  "Cap the systemd journal" \
  "Limits the journal to JOURNAL_MAX (default 500M)." \
  boot

journal_step() {
  step_skip "not written yet"
}

step_def flatpak opt-in flatpak_step '' \
  "Remove unused Flatpak runtimes" \
  "flatpak uninstall --unused; the removed runtimes can be reinstalled by --undo." \
  boot

flatpak_step() {
  step_skip "not written yet"
}

step_def waitonline opt-in waitonline_step '' \
  "Faster boot: skip NetworkManager-wait-online" \
  "Disables NetworkManager-wait-online.service, unless fstab has network mounts." \
  boot

waitonline_step() {
  step_skip "not written yet"
}

step_def firmware opt-in firmware_step 'report' \
  "Firmware updates (report only)" \
  "Lists the firmware updates fwupd offers. Never installs firmware." \
  boot

firmware_step() {
  step_skip "not written yet"
}
