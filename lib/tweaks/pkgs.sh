#!/usr/bin/env bash
# lib/tweaks/pkgs.sh - opt-in steps: pkgmgr, ccache.
# PLACEHOLDER: replaced by the real module.

step_def pkgmgr opt-in pkgmgr_step '' \
  "Faster package downloads" \
  "Parallel downloads (PARALLEL_DOWNLOADS, default 10) for dnf, pacman and zypper." \
  helpers

pkgmgr_step() {
  step_skip "not written yet"
}

step_def ccache opt-in ccache_step '' \
  "Compiler cache (ccache)" \
  "Installs ccache and puts its compiler wrappers first in PATH for login shells." \
  helpers

ccache_step() {
  step_skip "not written yet"
}
