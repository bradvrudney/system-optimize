#!/usr/bin/env bash
# lib/core/args.sh - the command line.
#
# args_parse fills SO_ARG_* from the command line; args_apply then layers
# the flags on top of the config/environment values, so that flags always
# win.

SO_ARG_DRY_RUN=""
SO_ARG_YES=""
SO_ARG_VERBOSE=""
SO_ARG_QUIET=""
SO_ARG_COLOR=""
SO_ARG_TIMEOUT=""
SO_ARG_LOGGING=""
SO_ARG_ONLY=""
SO_ARG_SKIP=""
SO_ARG_ENABLE=""
SO_ARG_PROFILE=""
SO_ARG_BACKEND=""
SO_ARG_SCHEDULER=""     # --scheduler NAME
SO_ARG_GPU_MEM=""       # --gpu-memory GIB
SO_ARG_INSTALL_TOOLS=""
SO_ARG_FORCE=""
SO_ARG_BENCHMARK=""
SO_ARG_SAFE_APPLY=""
SO_ARG_JSON=0
SO_ARG_STEP=""          # --history --step STEP
SO_ARG_LIMIT=""         # --history --limit N
SO_ARG_DAYS=""          # --history-prune DAYS
SO_ARG_FILE=""          # --export/--import/--diff-config FILE
SO_ARG_DESCRIBE=""      # --describe STEP
SO_ARG_SELF_UPDATE=0
SO_ARG_SOURCE=""
SO_ARG_BRANCH=""
SO_ARG_VERSION=0
SO_ARG_HELP=0
SO_ARG_COMPLETION=""
# apply | undo | status | list-snapshots | list-steps | describe | history |
# history-prune | history-clear | benchmark-only | check-drift | tune |
# confirm | export | import | diff-config
SO_ARG_MODE="apply"
SO_ARG_SNAPSHOT=""      # --undo ID, --confirm ID
SO_CONFIG_FILE="${SO_CONFIG_FILE:-}"
SO_LOG_PATH="${SO_LOG_PATH:-}"   # --log FILE
SO_JSON=0

usage() {
  cat <<EOF
Usage: system-optimize [options]                 apply the optimizations
       system-optimize --dry-run [options]       show what would change
       system-optimize --status [--json]         report: hardware, settings, steps, snapshots
       system-optimize --undo [ID] [--only LIST] restore a snapshot, or only these steps' changes
       system-optimize --list-steps | --list-snapshots
       system-optimize --describe STEP [--json]  what a step does and would change here
       system-optimize --benchmark-only [--json] measure CPU, memory and disk
       system-optimize --history [--json] [--step STEP] [--limit N]
       system-optimize --tune                    try steps one at a time; keep what is faster
       system-optimize --check-drift             which applied steps no longer hold
       system-optimize --export FILE | --import FILE | --diff-config FILE
       system-optimize --self-update [--dry-run] [--source URL]
       system-optimize --completion bash | --version | --help

Tunes a Linux machine for its hardware: kernel sysctl settings sized to its
RAM and swap (zram aware), disk I/O schedulers, the CPU power profile (through
power-profiles-daemon or tuned when present), open-file limits and SSD trim.
It reports which well-known helpers (tuned, earlyoom, systemd-oomd, zram,
irqbalance, ...) are present and can install the missing ones. More steps
are opt-in: choose them with --enable or a --profile (see --list-steps).

Every real run saves a snapshot first (the files it replaces and the values
it changes); --undo puts them back. Changing the system needs root: run it
with sudo. --dry-run, --status, --describe, --history, --benchmark-only and
--list-steps work as a normal user.

Options:
  -n, --dry-run           print what would change; change nothing
  -y, --yes               answer the [y/N] confirmation (required without a terminal)
      --status            read-only report, then exit
      --undo [ID]         restore a snapshot (default: the newest one not yet undone);
                          with --only LIST, undo only those steps' changes, in every snapshot
      --list-snapshots    list the snapshots
      --list-steps        list the steps and the profiles
      --describe STEP     what STEP does, and what it would change on this machine
      --only LIST         run only these steps (comma separated; opt-in ones too)
      --skip LIST         skip these steps (comma separated)
      --enable LIST       also run these opt-in steps
      --profile NAME      also run a profile's opt-in steps ($(join_by ', ' "${SO_PROFILES[@]}"))
      --backend NAME      where kernel settings go: auto (default), files or tuned
      --scheduler NAME    also run the "scheduler" step with this sched_ext scheduler
                          (auto, bpfland, lavd, flash, cosmos, rusty)
      --gpu-memory GIB    also run the "gpu-memory" step: let an AMD APU's GPU use
                          GIB of RAM (0 = AMD's guidance for this machine; reboot)
      --install-tools     install the recommended helpers that are missing
                          (earlyoom, irqbalance, zram-generator)
      --force             run even where a pre-flight check says no (a container)
      --benchmark         measure CPU, memory and disk before and after the run
      --benchmark-only    measure, change nothing
      --safe-apply        undo the run by itself unless --confirm comes in time
                          (SAFE_APPLY_TIMEOUT seconds, default 300), and at once
                          when --benchmark shows it slower
      --confirm [ID]      keep a --safe-apply run (cancels its rollback)
      --rollback ID       undo ID if its --safe-apply rollback is still pending
                          (what the rollback timer runs)
      --tune              try each of TUNE_STEPS alone; keep it only if faster
      --check-drift       report which applied steps would change things again
      --history           benchmarks and changes over time
      --step STEP         with --history: only this step's changes
      --limit N           with --history: only the newest N of each
      --history-prune DAYS  delete the history older than DAYS
      --history-clear     delete the whole history
      --export FILE       write the settings to FILE (no machine identifiers)
      --import FILE       make FILE's settings the system's (/etc/system-optimize.conf)
      --diff-config FILE  compare FILE's settings with the ones in effect
      --json              machine-readable output (see docs/json.md)
  -v, --verbose           show every command that is run
  -q, --quiet             hide third-party output; show only status lines
      --no-color          disable colours (NO_COLOR and non-TTY output do too)
      --color WHEN        auto (default), always or never
      --timeout SECONDS   per-command timeout (default 300)
      --config FILE       read this config file instead of the user config
      --log FILE          write this run's log to FILE
      --no-log            do not write a log file for this run
      --self-update       update system-optimize itself and exit
      --source URL        source for --self-update (https only; a fork)
      --branch NAME       branch for --self-update (git checkout or tree install)
      --version           print the version and exit
  -h, --help              show this help and exit

Default steps: $(join_by ', ' $(steps_of_kind default))
Opt-in steps:  $(join_by ', ' $(steps_of_kind opt-in))

Config: \${XDG_CONFIG_HOME:-~/.config}/system-optimize/config and
/etc/system-optimize.conf (KEY=value). Environment variables override the
files, flags override everything. See config.example.
EOF
}

# args_need OPT VALUE: fail when an option that needs a value has none.
args_need() {
  if [ -z "${2:-}" ]; then
    log_error "option $1 requires a value"
    return 1
  fi
}

# args_is_snapshot_id WORD: a snapshot name (see lib/core/snapshot.sh).
args_is_snapshot_id() {
  [[ "$1" =~ ^[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]] || [ "$1" = latest ]
}

# args_parse "$@": fill SO_ARG_*. Returns 2 on a usage error.
args_parse() {
  local opt val
  while [ $# -gt 0 ]; do
    opt="$1"; val=""
    # Split --opt=value.
    case "$opt" in
      --*=*) val="${opt#*=}"; opt="${opt%%=*}"; set -- "$opt" "$val" "${@:2}" ;;
    esac
    case "$opt" in
      -n|--dry-run) SO_ARG_DRY_RUN=1 ;;
      -d) SO_ARG_DRY_RUN=1 ;;   # Ed's 1.x short form of --dry-run
      -y|--yes) SO_ARG_YES=1 ;;
      -v|--verbose) SO_ARG_VERBOSE=1 ;;
      -q|--quiet) SO_ARG_QUIET=1 ;;
      --status) SO_ARG_MODE=status ;;
      --list-snapshots) SO_ARG_MODE="list-snapshots" ;;
      --list-steps) SO_ARG_MODE="list-steps" ;;
      --describe) args_need "$opt" "${2:-}" || return 2; SO_ARG_MODE=describe; SO_ARG_DESCRIBE="$2"; shift ;;
      --history) SO_ARG_MODE=history ;;
      --step) args_need "$opt" "${2:-}" || return 2; SO_ARG_STEP="$2"; shift ;;
      --limit) args_need "$opt" "${2:-}" || return 2; SO_ARG_LIMIT="$2"; shift ;;
      --history-prune) args_need "$opt" "${2:-}" || return 2; SO_ARG_MODE=history-prune; SO_ARG_DAYS="$2"; shift ;;
      --history-clear) SO_ARG_MODE=history-clear ;;
      --benchmark) SO_ARG_BENCHMARK=1 ;;
      --benchmark-only) SO_ARG_MODE=benchmark-only ;;
      --safe-apply) SO_ARG_SAFE_APPLY=1 ;;
      --confirm)
        SO_ARG_MODE=confirm
        if [ $# -gt 1 ] && args_is_snapshot_id "$2"; then SO_ARG_SNAPSHOT="$2"; shift; fi ;;
      --tune) SO_ARG_MODE=tune ;;
      --rollback)
        args_need "$opt" "${2:-}" || return 2
        args_is_snapshot_id "$2" || { log_error "--rollback takes a snapshot ID"; return 2; }
        SO_ARG_MODE=rollback; SO_ARG_SNAPSHOT="$2"; shift ;;
      --check-drift) SO_ARG_MODE=check-drift ;;
      --export|--import|--diff-config)
        args_need "$opt" "${2:-}" || return 2
        SO_ARG_MODE="${opt#--}"; SO_ARG_FILE="$2"; shift ;;
      --json) SO_ARG_JSON=1 ;;
      --undo|--restore)
        SO_ARG_MODE=undo
        if [ $# -gt 1 ] && args_is_snapshot_id "$2"; then SO_ARG_SNAPSHOT="$2"; shift; fi ;;
      --only) args_need "$opt" "${2:-}" || return 2; SO_ARG_ONLY="$2"; shift ;;
      --skip) args_need "$opt" "${2:-}" || return 2; SO_ARG_SKIP="$2"; shift ;;
      --enable) args_need "$opt" "${2:-}" || return 2; SO_ARG_ENABLE="$2"; shift ;;
      --profile) args_need "$opt" "${2:-}" || return 2; SO_ARG_PROFILE="$2"; shift ;;
      --backend) args_need "$opt" "${2:-}" || return 2; SO_ARG_BACKEND="$2"; shift ;;
      --scheduler) args_need "$opt" "${2:-}" || return 2; SO_ARG_SCHEDULER="$2"; shift ;;
      --gpu-memory) args_need "$opt" "${2:-}" || return 2; SO_ARG_GPU_MEM="$2"; shift ;;
      --install-tools) SO_ARG_INSTALL_TOOLS=1 ;;
      --force) SO_ARG_FORCE=1 ;;
      --no-color|--no-colour) SO_ARG_COLOR=never ;;
      --color|--colour) args_need "$opt" "${2:-}" || return 2; SO_ARG_COLOR="$2"; shift ;;
      --timeout) args_need "$opt" "${2:-}" || return 2; SO_ARG_TIMEOUT="$2"; shift ;;
      --config) args_need "$opt" "${2:-}" || return 2; SO_CONFIG_FILE="$2"; shift ;;
      --log) args_need "$opt" "${2:-}" || return 2; SO_LOG_PATH="$2"; SO_ARG_LOGGING=1; shift ;;
      --no-log) SO_ARG_LOGGING=0; SO_LOG_PATH="" ;;
      --self-update) SO_ARG_SELF_UPDATE=1 ;;
      --source) args_need "$opt" "${2:-}" || return 2; SO_ARG_SOURCE="$2"; shift ;;
      --branch) args_need "$opt" "${2:-}" || return 2; SO_ARG_BRANCH="$2"; shift ;;
      --version|-V) SO_ARG_VERSION=1 ;;
      --completion) args_need "$opt" "${2:-}" || return 2; SO_ARG_COMPLETION="$2"; shift ;;
      -h|--help) SO_ARG_HELP=1 ;;
      -[a-zA-Z][a-zA-Z]*)
        # Combined short flags like -ny: split and parse again.
        local i chars="${opt#-}" rest=()
        for ((i = 0; i < ${#chars}; i++)); do rest+=("-${chars:i:1}"); done
        shift
        set -- "${rest[@]}" "$@"
        continue ;;
      -*)
        log_error "unknown option: $opt"
        return 2 ;;
      *)
        log_error "unexpected argument: $opt"
        return 2 ;;
    esac
    shift
  done
  return 0
}

# args_apply: layer flags over the loaded configuration and export the
# runtime globals used by the rest of the program.
args_apply() {
  local s
  [ -n "$SO_ARG_TIMEOUT" ] && { config_set TIMEOUT "$SO_ARG_TIMEOUT" flag || return 2; }
  [ -n "$SO_ARG_COLOR" ] && { config_set COLOR "$SO_ARG_COLOR" flag || return 2; }
  [ -n "$SO_ARG_LOGGING" ] && config_set LOGGING "$SO_ARG_LOGGING" flag
  [ -n "$SO_ARG_SOURCE" ] && { config_set SELF_UPDATE_REPO "$SO_ARG_SOURCE" flag || return 2; }
  [ -n "$SO_ARG_BRANCH" ] && { config_set SELF_UPDATE_BRANCH "$SO_ARG_BRANCH" flag || return 2; }
  [ -n "$SO_ARG_ONLY" ] && { config_set ONLY "$SO_ARG_ONLY" flag || return 2; }
  [ -n "$SO_ARG_SKIP" ] && { config_set SKIP "$SO_ARG_SKIP" flag || return 2; }
  [ -n "$SO_ARG_INSTALL_TOOLS" ] && config_set INSTALL_TOOLS 1 flag
  [ -n "$SO_ARG_FORCE" ] && config_set FORCE 1 flag
  [ -n "$SO_ARG_BENCHMARK" ] && config_set BENCHMARK 1 flag
  [ -n "$SO_ARG_SAFE_APPLY" ] && config_set SAFE_APPLY 1 flag
  if [ -n "$SO_ARG_PROFILE" ]; then
    if ! profile_exists "$SO_ARG_PROFILE"; then
      log_error "unknown profile: $SO_ARG_PROFILE (profiles: $(join_by ', ' "${SO_PROFILES[@]}"))"
      return 2
    fi
    config_set PROFILE "$SO_ARG_PROFILE" flag
  fi
  if [ -n "$SO_ARG_BACKEND" ] && ! config_set BACKEND "$SO_ARG_BACKEND" flag; then
    log_error "--backend takes auto, files or tuned"
    return 2
  fi
  if [ -n "$SO_ARG_SCHEDULER" ]; then
    config_set SCHEDULER "$SO_ARG_SCHEDULER" flag || { log_error "--scheduler takes auto, bpfland, lavd, flash, cosmos or rusty"; return 2; }
    SO_ARG_ENABLE+="${SO_ARG_ENABLE:+,}scheduler"
  fi
  if [ -n "$SO_ARG_GPU_MEM" ]; then
    config_set GPU_MEM_GIB "$SO_ARG_GPU_MEM" flag || { log_error "--gpu-memory takes a number of GiB"; return 2; }
    SO_ARG_ENABLE+="${SO_ARG_ENABLE:+,}gpu-memory"
  fi
  if [ -n "$SO_ARG_LIMIT" ] && ! [[ "$SO_ARG_LIMIT" =~ ^[0-9]{1,6}$ ]]; then
    log_error "--limit takes a number"
    return 2
  fi
  if [ -n "$SO_ARG_DAYS" ] && ! [[ "$SO_ARG_DAYS" =~ ^[0-9]{1,6}$ ]]; then
    log_error "--history-prune takes a number of days"
    return 2
  fi
  for s in "$SO_ARG_STEP" "$SO_ARG_DESCRIBE"; do
    [ -n "$s" ] || continue
    if [[ "$s" == *[,\ ]* ]]; then log_error "one step only: $s"; return 2; fi
    steps_check_list "$s" || return 2
  done

  SO_DRY_RUN="${SO_ARG_DRY_RUN:-${SO_DRY_RUN:-0}}"
  SO_YES="${SO_ARG_YES:-${SO_YES:-0}}"
  SO_VERBOSE="${SO_ARG_VERBOSE:-${SO_VERBOSE:-0}}"
  SO_QUIET="${SO_ARG_QUIET:-${SO_QUIET:-0}}"
  if [ "$SO_VERBOSE" = 1 ] && [ "$SO_QUIET" = 1 ]; then
    SO_QUIET=0
  fi
  SO_COLOR=$(cfg COLOR)
  SO_TIMEOUT=$(cfg TIMEOUT)
  SO_PKG_TIMEOUT=$(cfg PKG_TIMEOUT)
  SO_DOWNLOAD_TIMEOUT=$(cfg DOWNLOAD_TIMEOUT)
  SO_ONLY=$(cfg ONLY)
  SO_SKIP=$(cfg SKIP)
  steps_check_list "$SO_ONLY" || return 2
  steps_check_list "$SO_SKIP" || return 2
  steps_check_list "$(cfg ENABLE) $SO_ARG_ENABLE" || return 2
  steps_check_list "$(cfg TUNE_STEPS)" || return 2
  steps_resolve_enable
  SO_JSON="$SO_ARG_JSON"
  # With --json, stdout carries the JSON alone; the messages still go to
  # the run log, and to stderr with --verbose.
  if [ "$SO_JSON" = 1 ]; then
    if [ "$SO_VERBOSE" = 1 ]; then exec {SO_OUT}>&2; else exec {SO_OUT}>/dev/null; fi
    SO_COLOR=never
  fi
  export SO_DRY_RUN SO_VERBOSE SO_QUIET SO_COLOR SO_TIMEOUT SO_PKG_TIMEOUT SO_DOWNLOAD_TIMEOUT
  log_init
  return 0
}
