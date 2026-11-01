#!/usr/bin/env bash
# lib/tweaks/memory.sh - opt-in steps: mglru, thp.
# PLACEHOLDER: replaced by the real module.

step_def mglru opt-in mglru_step 'bench' \
  "Memory reclaim protects the working set" \
  "Sets MGLRU min_ttl_ms (default 1000 ms) so the desktop keeps its working set instead of thrashing." \
  memory

mglru_step() {
  step_skip "not written yet"
}

step_def thp opt-in thp_step 'bench' \
  "Transparent huge pages: madvise, deferred defrag" \
  "THP for programs that ask for it (llama.cpp, databases) with defer+madvise defrag, which avoids compaction stalls." \
  memory

thp_step() {
  step_skip "not written yet"
}
