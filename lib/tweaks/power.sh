#!/usr/bin/env bash
# lib/tweaks/power.sh - opt-in steps: charge, powerswitch.
# PLACEHOLDER: replaced by the real module.

step_def charge opt-in charge_step '' \
  "Battery charge limit" \
  "Stops charging at CHARGE_LIMIT % (default 80) where the battery driver supports it." \
  power

charge_step() {
  step_skip "not written yet"
}

step_def powerswitch opt-in powerswitch_step '' \
  "Power profile follows the power source" \
  "performance on mains, balanced or power-saver on battery, through power-profiles-daemon or tuned-ppd." \
  power

powerswitch_step() {
  step_skip "not written yet"
}
