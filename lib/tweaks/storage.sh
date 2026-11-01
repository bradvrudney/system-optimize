#!/usr/bin/env bash
# lib/tweaks/storage.sh - opt-in steps: noatime, btrfs, plocate, indexer, psd.
# PLACEHOLDER: replaced by the real module.

step_def noatime opt-in noatime_step 'bench' \
  "Fewer disk writes on reads (noatime)" \
  "Adds noatime (or lazytime) to the root and home mounts in fstab and remounts them." \
  storage

noatime_step() {
  step_skip "not written yet"
}

step_def btrfs opt-in btrfs_step 'bench' \
  "Btrfs: zstd compression and monthly scrub" \
  "compress=zstd:1 for new writes on Btrfs mounts, and a monthly scrub through btrfsd or a timer. Never defragments or recompresses." \
  storage

btrfs_step() {
  step_skip "not written yet"
}

step_def plocate opt-in plocate_step '' \
  "Fast file search (plocate)" \
  "Replaces mlocate with plocate and its daily index timer." \
  storage

plocate_step() {
  step_skip "not written yet"
}

step_def indexer opt-in indexer_step 'desktop' \
  "Leave build and cache folders out of desktop search" \
  "Keeps GNOME LocalSearch/Tracker and KDE Baloo out of node_modules, build output, caches and VM images." \
  storage

indexer_step() {
  step_skip "not written yet"
}

step_def psd opt-in psd_step 'desktop' \
  "Browser profiles in RAM (profile-sync-daemon)" \
  "Installs profile-sync-daemon and turns it on for every user." \
  storage

psd_step() {
  step_skip "not written yet"
}
