#!/usr/bin/env bash
# lib/tweaks/network.sh - opt-in steps: dns, wifi.
# PLACEHOLDER: replaced by the real module.

step_def dns opt-in dns_step '' \
  "DNS caching (systemd-resolved)" \
  "Turns on caching, and serving stale answers while refreshing, when systemd-resolved runs." \
  network

dns_step() {
  step_skip "not written yet"
}

step_def wifi opt-in wifi_step '' \
  "No Wi-Fi power saving on mains power" \
  "Turns Wi-Fi power saving off on mains power and back on on battery." \
  network

wifi_step() {
  step_skip "not written yet"
}
