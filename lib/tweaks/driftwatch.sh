#!/usr/bin/env bash
# lib/tweaks/driftwatch.sh - opt-in steps: driftwatch.
# PLACEHOLDER: replaced by the real module.

step_def driftwatch opt-in driftwatch_step 'report' \
  "Weekly drift check (report only)" \
  "A weekly timer runs system-optimize --check-drift and logs which applied steps changed back." \
  helpers

driftwatch_step() {
  step_skip "not written yet"
}
