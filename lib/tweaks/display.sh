#!/usr/bin/env bash
# lib/tweaks/display.sh - opt-in steps: fonts, display.
# PLACEHOLDER: replaced by the real module.

step_def fonts opt-in fonts_step 'desktop' \
  "Font hinting and subpixel rendering" \
  "Sets FONT_HINTING (slight) and FONT_SUBPIXEL (rgb) for the system and the GNOME desktop." \
  display

fonts_step() {
  step_skip "not written yet"
}

step_def display opt-in display_step 'desktop' \
  "Fractional scaling, variable refresh, highest refresh rate" \
  "GNOME or KDE on Wayland only: fractional scaling, VRR and the highest refresh rate the screen offers." \
  display

display_step() {
  step_skip "not written yet"
}
