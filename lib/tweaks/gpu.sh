#!/usr/bin/env bash
# lib/tweaks/gpu.sh - opt-in steps: gpu-memory, rocm.
# PLACEHOLDER: replaced by the real module.

step_def gpu-memory opt-in gpu_memory_step 'reboot,bench' \
  "More GPU memory for AMD APUs (TTM limit)" \
  "Raises the TTM pages limit so an AMD APU can map more RAM as GPU memory (amd-ttm or modprobe.d). Needs a reboot." \
  gpu

gpu_memory_step() {
  step_skip "not written yet"
}

step_def rocm opt-in rocm_step 'reboot' \
  "ROCm for AMD GPUs" \
  "Installs ROCm where the distribution packages it and adds the desktop user to render and video." \
  gpu

rocm_step() {
  step_skip "not written yet"
}
