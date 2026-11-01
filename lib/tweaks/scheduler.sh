#!/usr/bin/env bash
# lib/tweaks/scheduler.sh - opt-in steps: scheduler, responsive.
# PLACEHOLDER: replaced by the real module.

step_def scheduler opt-in scheduler_step 'bench' \
  "sched_ext CPU scheduler (scx_loader)" \
  "Runs a sched_ext scheduler through scx_loader: bpfland on desktops, lavd on laptops. Falls back to the kernel scheduler if it stops." \
  power

scheduler_step() {
  step_skip "not written yet"
}

step_def responsive opt-in responsive_step '' \
  "Responsiveness helpers: uresourced, GameMode, ananicy-cpp" \
  "Turns on uresourced and GameMode where packaged; ananicy-cpp only when no sched_ext scheduler runs." \
  power

responsive_step() {
  step_skip "not written yet"
}
