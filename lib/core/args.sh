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
SO_ARG_INSTALL_TOOLS=""
SO_ARG_FORCE=""
SO_ARG_SELF_UPDATE=0
SO_ARG_SOURCE=""
SO_ARG_BRANCH=""
SO_ARG_VERSION=0
SO_ARG_HELP=0
SO_ARG_COMPLETION=""
SO_ARG_MODE="apply"     # apply | undo | status | list-snapshots
SO_ARG_SNAPSHOT=""      # --undo ID
SO_CONFIG_FILE="${SO_CONFIG_FILE:-}"
SO_LOG_PATH="${SO_LOG_PATH:-}"   # --log FILE

# The steps, in the order they run (also the names for --only/--skip).
SO_STEPS=(legacy sysctl io cpu limits trim tools)

usage() {
  cat <<EOF
Usage: system-optimize [options]                 apply the optimizations
       system-optimize --dry-run [options]       show what would change
       system-optimize --status                  report: hardware, settings, tools, snapshots
       system-optimize --undo [ID]               restore the newest (or the given) snapshot
       system-optimize --list-snapshots          list the snapshots --undo can restore
       system-optimize --self-update [--dry-run] [--source URL]
       system-optimize --completion bash | --version | --help

Tunes a Linux machine for its hardware: kernel sysctl settings sized to its
RAM and swap (zram aware), disk I/O schedulers, the CPU power profile (through
power-profiles-daemon or tuned when present), open-file limits and SSD trim.
It reports which well-known helpers (tuned, earlyoom, systemd-oomd, zram,
irqbalance, ...) are present and can install the missing ones.

Every real run saves a snapshot first (the files it replaces and the values
it changes); --undo puts them back. Changing the system needs root: run it
with sudo. --dry-run and --status work as a normal user.

Options:
  -n, --dry-run           print what would change; change nothing
  -y, --yes               answer the [y/N] confirmation (required without a terminal)
      --status            read-only report, then exit
      --undo [ID]         restore a snapshot (default: the newest one not yet undone)
      --list-snapshots    list the snapshots
      --only LIST         run only these steps (comma separated)
      --skip LIST         skip these steps (comma separated)
      --install-tools     install the recommended helpers that are missing
                          (earlyoom, irqbalance, zram-generator)
      --force             run even where a pre-flight check says no (a container)
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

Steps for --only/--skip: $(join_by ', ' "${SO_STEPS[@]}")

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
      --undo|--restore)
        SO_ARG_MODE=undo
        if [ $# -gt 1 ] && args_is_snapshot_id "$2"; then SO_ARG_SNAPSHOT="$2"; shift; fi ;;
      --only) args_need "$opt" "${2:-}" || return 2; SO_ARG_ONLY="$2"; shift ;;
      --skip) args_need "$opt" "${2:-}" || return 2; SO_ARG_SKIP="$2"; shift ;;
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

# args_check_steps LIST: every name in LIST is a step.
args_check_steps() {
  local name
  local -a names=()
  IFS=, read -r -a names <<< "$1"
  for name in "${names[@]+"${names[@]}"}"; do
    [ -n "$name" ] || continue
    if ! list_has "${SO_STEPS[*]}" "$name"; then
      log_error "unknown step: $name (steps: $(join_by ', ' "${SO_STEPS[@]}"))"
      return 1
    fi
  done
}

# args_apply: layer flags over the loaded configuration and export the
# runtime globals used by the rest of the program.
args_apply() {
  [ -n "$SO_ARG_TIMEOUT" ] && { config_set TIMEOUT "$SO_ARG_TIMEOUT" flag || return 2; }
  [ -n "$SO_ARG_COLOR" ] && { config_set COLOR "$SO_ARG_COLOR" flag || return 2; }
  [ -n "$SO_ARG_LOGGING" ] && config_set LOGGING "$SO_ARG_LOGGING" flag
  [ -n "$SO_ARG_SOURCE" ] && { config_set SELF_UPDATE_REPO "$SO_ARG_SOURCE" flag || return 2; }
  [ -n "$SO_ARG_BRANCH" ] && { config_set SELF_UPDATE_BRANCH "$SO_ARG_BRANCH" flag || return 2; }
  [ -n "$SO_ARG_ONLY" ] && { config_set ONLY "$SO_ARG_ONLY" flag || return 2; }
  [ -n "$SO_ARG_SKIP" ] && { config_set SKIP "$SO_ARG_SKIP" flag || return 2; }
  [ -n "$SO_ARG_INSTALL_TOOLS" ] && config_set INSTALL_TOOLS 1 flag
  [ -n "$SO_ARG_FORCE" ] && config_set FORCE 1 flag

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
  args_check_steps "$SO_ONLY" || return 2
  args_check_steps "$SO_SKIP" || return 2
  export SO_DRY_RUN SO_VERBOSE SO_QUIET SO_COLOR SO_TIMEOUT SO_PKG_TIMEOUT SO_DOWNLOAD_TIMEOUT
  log_init
  return 0
}
