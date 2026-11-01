#!/usr/bin/env bash
# lib/core/snapshot.sh - every change goes through here, so that --undo can
# put it back.
#
# A snapshot is a directory under SNAPSHOT_DIR (default
# /var/lib/system-optimize/snapshots) named after the time of the run,
# YYYYmmdd-HHMMSS. It holds:
#   info       what made it (version, time, host, command line)
#   manifest   one tab-separated line per thing that was changed, in order:
#                file    PATH     absent | saved:N     (N: files/N is the old copy)
#                sysctl  KEY      the value before
#                sysfs   PATH     the value before
#                unit    UNIT     enabled | disabled | ... (the state before)
#                svc     INIT:NAME  enabled | disabled  (an OpenRC or runit
#                                 service; INIT is openrc or runit)
#                ppd     -        the power-profiles-daemon profile before
#                tuned   -        the tuned profile before
#                pkg     NAME     installed   (installed by this run)
#   files/     copies of the files that were replaced or removed
#   undone     written by --undo once the snapshot has been restored
# Paths in the manifest are the real system paths (without SO_ROOT). The
# directory is 0700 and created on the first change of a real run; a dry
# run never creates one.

SO_SNAP=""          # the current run's snapshot directory, once created
SO_SNAP_COUNT=0     # entries recorded by this run

# snap_base: where snapshots live.
snap_base() {
  local d
  d=$(cfg SNAPSHOT_DIR)
  if [ -n "$d" ]; then
    printf '%s\n' "$d"
  else
    so_path /var/lib/system-optimize/snapshots
  fi
}

# snap_begin: create this run's snapshot (once).
snap_begin() {
  local base name dir
  [ -n "$SO_SNAP" ] && return 0
  [ "$SO_DRY_RUN" = 1 ] && return 1
  base=$(snap_base)
  (umask 077; mkdir -p -- "$base") || { log_error "cannot create the snapshot directory $base"; return 1; }
  name=$(printf '%(%Y%m%d-%H%M%S)T' -1)
  dir="$base/$name"
  [ -e "$dir" ] && dir="$base/$name-$$"
  (umask 077; mkdir -p -- "$dir/files") || { log_error "cannot create the snapshot $dir"; return 1; }
  : > "$dir/manifest"
  {
    printf 'version  %s\n' "$(version_string)"
    printf 'created  %(%Y-%m-%d %H:%M:%S %z)T\n' -1
    printf 'host     %s\n' "$(uname -n 2>/dev/null || echo unknown)"
    printf 'command  %s\n' "${SO_COMMAND_LINE:-system-optimize}"
  } > "$dir/info"
  SO_SNAP="$dir"
  log_detail "snapshot: $dir"
}

# snap_has KIND TARGET: already recorded by this run (the first record of a
# target holds the state before the run, so later ones are dropped).
snap_has() {
  [ -n "$SO_SNAP" ] || return 1
  grep -qF -- "$1"$'\t'"$2"$'\t' "$SO_SNAP/manifest"
}

# snap_record KIND TARGET VALUE: add a manifest line.
snap_record() {
  local kind="$1" target="$2" value="$3"
  snap_begin || return 1
  snap_has "$kind" "$target" && return 0
  value="${value//[$'\t\n']/ }"
  printf '%s\t%s\t%s\n' "$kind" "$target" "$value" >> "$SO_SNAP/manifest"
  SO_SNAP_COUNT=$((SO_SNAP_COUNT + 1))
}

# snap_file PATH: save PATH (a system path) before it is replaced or removed.
snap_file() {
  local path="$1" real n
  real=$(so_path "$path")
  snap_begin || return 1
  snap_has file "$path" && return 0
  if [ -e "$real" ] || [ -L "$real" ]; then
    n=$((SO_SNAP_COUNT + 1))
    cp -a -- "$real" "$SO_SNAP/files/$n" || { log_error "could not back up $path"; return 1; }
    snap_record file "$path" "saved:$n"
  else
    snap_record file "$path" absent
  fi
}

# ---------------------------------------------------------------------------
# Changing things (each records first, then changes; a dry run only reports)
# ---------------------------------------------------------------------------
# file_differs PATH NEWFILE: is the installed PATH missing or different?
file_differs() {
  local real
  real=$(so_path "$1")
  [ -f "$real" ] || return 0
  if has_cmd cmp; then
    ! cmp -s -- "$real" "$2"
  else
    # Minimal containers ship without diffutils.
    [ "$(sha256_of "$real")" != "$(sha256_of "$2")" ]
  fi
}

# install_file PATH MODE < CONTENT: put CONTENT at PATH (a system path).
# Never call it at the end of a pipeline (`cmd | install_file`): it would
# run in a subshell and the snapshot it starts would be lost to the run.
# Feed it with < FILE or < <(cmd).
# Returns 0 when it was written (or would be), 3 when PATH already holds
# exactly that, 1 on failure.
install_file() {
  local path="$1" mode="${2:-0644}" real tmp staged
  real=$(so_path "$path")
  tmp=$(tmp_file) || return 1
  cat > "$tmp"
  if ! file_differs "$path" "$tmp"; then
    log_detail "$path is already up to date"
    return 3
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    if [ -e "$real" ]; then log_dry "would replace $path"; else log_dry "would create $path"; fi
    _log_verbose "$(sed 's/^/      | /' "$tmp")"
    return 0
  fi
  snap_file "$path" || return 1
  mkdir -p -- "$(dirname "$real")" || return 1
  staged="$(dirname "$real")/.system-optimize.$$.tmp"
  { cp -- "$tmp" "$staged" && chmod "$mode" "$staged" && mv -f -- "$staged" "$real"; } || {
    rm -f -- "$staged"
    log_error "could not write $path"
    return 1
  }
  log_cmd "wrote $path"
  return 0
}

# remove_file PATH: remove a system file (backed up first).
remove_file() {
  local path="$1" real
  real=$(so_path "$path")
  [ -e "$real" ] || [ -L "$real" ] || return 0
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would remove $path"
    return 0
  fi
  snap_file "$path" || return 1
  rm -f -- "$real" || { log_error "could not remove $path"; return 1; }
  log_cmd "removed $path"
}

# write_sysfs PATH VALUE PREVIOUS: write VALUE to a /sys file (a system
# path), recording PREVIOUS for --undo.
write_sysfs() {
  local path="$1" value="$2" prev="$3"
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would set $path: $prev -> $value"
    return 0
  fi
  snap_record sysfs "$path" "$prev" || return 1
  log_cmd "echo $value > $path"
  if ! printf '%s\n' "$value" > "$(so_path "$path")" 2>/dev/null; then
    log_warn "could not write $value to $path"
    return 1
  fi
}

# unit_set UNIT enable|disable: enable --now or disable --now a systemd
# unit, recording its state before.
unit_set() {
  local unit="$1" action="$2" prev
  prev=$(unit_enabled_state "$unit")
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would run: systemctl $action --now $unit"
    return 0
  fi
  snap_record unit "$unit" "$prev" || return 1
  run systemctl "$action" --now "$unit"
}

# svc_set NAME enable|disable: enable and start, or stop and disable, a
# service by its base name with whichever init runs, recording its state
# before. systemd goes through unit_set; OpenRC uses rc-update and
# rc-service (default runlevel); runit links /etc/sv/NAME into the service
# directory, which runsvdir starts within seconds.
svc_set() {
  local name="$1" action="$2" prev
  case "$SO_INIT_SYSTEM" in
    systemd) unit_set "$name.service" "$action"; return ;;
    openrc|runit) ;;
    *) log_warn "$name: no init system to $action it with"; return 1 ;;
  esac
  prev=$(svc_enabled_state "$name")
  if [ "$prev" = absent ]; then
    log_warn "$name: no $SO_INIT_SYSTEM service of that name"
    return 1
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would $action the $SO_INIT_SYSTEM service $name"
    return 0
  fi
  snap_record svc "$SO_INIT_SYSTEM:$name" "$prev" || return 1
  _svc_apply "$SO_INIT_SYSTEM" "$name" "$action"
}

# _svc_apply INIT NAME enable|disable: the change itself (also for --undo).
_svc_apply() {
  local init="$1" name="$2" action="$3" dir
  case "$init:$action" in
    openrc:enable)
      do_run rc-update add "$name" default || return 1
      do_run rc-service "$name" start ;;
    openrc:disable)
      do_run rc-service "$name" stop || true
      do_run rc-update del "$name" default ;;
    runit:enable)
      dir=$(svc_runit_dir)
      [ -e "$(so_path "$dir/$name")" ] && return 0
      do_run ln -s "/etc/sv/$name" "$(so_path "$dir/$name")" ;;
    runit:disable)
      dir=$(svc_runit_dir)
      [ -L "$(so_path "$dir/$name")" ] || return 0
      has_cmd sv && { do_run sv down "$name" || true; }
      do_run rm -f -- "$(so_path "$dir/$name")" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Listing and restoring
# ---------------------------------------------------------------------------
# snap_ids: every snapshot name, oldest first.
snap_ids() {
  local d base
  base=$(snap_base)
  for d in "$base"/[0-9]*; do
    [ -f "$d/manifest" ] && printf '%s\n' "${d##*/}"
  done
  return 0
}

# snap_latest: the newest snapshot not yet undone.
snap_latest() {
  local id last="" base
  base=$(snap_base)
  while IFS= read -r id; do
    [ -e "$base/$id/undone" ] || last="$id"
  done < <(snap_ids)
  [ -n "$last" ] || return 1
  printf '%s\n' "$last"
}

# snap_summary ID: "N change(s)" and the undone mark.
snap_summary() {
  local dir n
  dir="$(snap_base)/$1"
  n=$(grep -c . "$dir/manifest" 2>/dev/null) || n=0
  printf '%s change(s)' "$n"
  [ -e "$dir/undone" ] && printf ', undone %s' "$(read_line "$dir/undone")"
  printf '\n'
}

# list_snapshots_main: --list-snapshots.
list_snapshots_main() {
  local id n=0 base
  base=$(snap_base)
  log_plain "Snapshots in $base:"
  while IFS= read -r id; do
    n=$((n + 1))
    log_kv "$id" "$(snap_summary "$id")"
  done < <(snap_ids)
  [ "$n" -gt 0 ] || log_plain "  (none)"
  return 0
}

# _undo_valid KIND TARGET VALUE: a manifest line we are willing to act on.
# The manifest is root's, in a 0700 directory, but it is still checked:
# files only under /etc, values only to /sys, names only of a safe shape.
_undo_valid() {
  local kind="$1" target="$2" value="$3"
  case "$kind" in
    file)
      [[ "$target" =~ ^/etc/[A-Za-z0-9_.@+/-]+$ ]] && [[ "$target" != *..* ]] &&
        [[ "$value" =~ ^(absent|saved:[0-9]+)$ ]] ;;
    sysctl) [[ "$target" =~ ^[a-z0-9_.-]+$ ]] && [[ "$value" =~ ^[A-Za-z0-9\ _.-]*$ ]] ;;
    sysfs)
      [[ "$target" =~ ^/sys/[A-Za-z0-9_./:-]+$ ]] && [[ "$target" != *..* ]] &&
        [[ "$value" =~ ^[A-Za-z0-9_.-]*$ ]] ;;
    unit) [[ "$target" =~ ^[A-Za-z0-9@._-]+$ ]] && [[ "$value" =~ ^[a-z-]+$ ]] ;;
    svc) [[ "$target" =~ ^(openrc|runit):[A-Za-z0-9@._-]+$ ]] && [[ "$value" =~ ^(enabled|disabled)$ ]] ;;
    ppd|tuned) [[ "$value" =~ ^[A-Za-z0-9_.-]*$ ]] ;;
    pkg) [[ "$target" =~ ^[A-Za-z0-9+._-]+$ ]] ;;
    *) return 1 ;;
  esac
}

# _undo_entry SNAPDIR KIND TARGET VALUE: put one thing back.
_undo_entry() {
  local dir="$1" kind="$2" target="$3" value="$4" real
  case "$kind" in
    file)
      real=$(so_path "$target")
      if [ "$value" = absent ]; then
        [ -e "$real" ] || [ -L "$real" ] || return 0
        do_run rm -f -- "$real" || return 1
        log_info "removed $target"
      else
        if [ "$SO_DRY_RUN" = 1 ]; then log_dry "would restore $target"; return 0; fi
        if ! { mkdir -p -- "$(dirname "$real")" &&
               cp -a -- "$dir/files/${value#saved:}" "$real.system-optimize-undo" &&
               mv -f -- "$real.system-optimize-undo" "$real"; }; then
          log_error "could not restore $target"
          return 1
        fi
        log_info "restored $target"
      fi ;;
    sysctl)
      # A dirty_*bytes or dirty_*ratio of 0 means "the other one is in
      # use"; writing it would fail. Its partner restores both.
      if [ "$value" = 0 ] && [[ "$target" =~ ^vm\.dirty_(background_)?(bytes|ratio)$ ]]; then
        return 0
      fi
      [ -n "$value" ] || return 0
      do_run sysctl -w "$target=$value" >/dev/null || return 1 ;;
    sysfs)
      [ -n "$value" ] || return 0
      if [ "$SO_DRY_RUN" = 1 ]; then log_dry "would set $target to $value"; return 0; fi
      log_cmd "echo $value > $target"
      printf '%s\n' "$value" > "$(so_path "$target")" 2>/dev/null || { log_warn "could not write $value to $target"; return 1; }
      ;;
    unit)
      case "$value" in
        enabled) do_run systemctl enable --now "$target" ;;
        disabled|absent) do_run systemctl disable --now "$target" ;;
        masked) do_run systemctl mask --now "$target" ;;
        *) log_detail "$target was $value before; left as it is" ;;
      esac ;;
    svc)
      if [ "$value" = enabled ]; then
        _svc_apply "${target%%:*}" "${target#*:}" enable
      else
        _svc_apply "${target%%:*}" "${target#*:}" disable
      fi ;;
    ppd) [ -n "$value" ] && do_run powerprofilesctl set "$value" ;;
    tuned)
      if [ -z "$value" ] || [ "$value" = none ]; then do_run tuned-adm off; else do_run tuned-adm profile "$value"; fi ;;
    pkg)
      if [ "$SO_DRY_RUN" = 1 ]; then log_dry "would remove the package $target"; return 0; fi
      pkg_remove "$target" ;;
  esac
}

# undo_step: restore SO_UNDO_ID (set by undo_main), newest change first.
undo_step() {
  local dir kind target value i failed=0 n=0 udev=0
  local -a lines=()
  dir="$(snap_base)/$SO_UNDO_ID"
  mapfile -t lines < "$dir/manifest"
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    IFS=$'\t' read -r kind target value <<< "${lines[i]}"
    [ -n "$kind" ] || continue
    n=$((n + 1))
    if ! _undo_valid "$kind" "$target" "$value"; then
      log_warn "skipping a manifest line that does not look right: ${lines[i]}"
      failed=$((failed + 1))
      continue
    fi
    [ "$kind" = file ] && [[ "$target" == /etc/udev/* ]] && udev=1
    _undo_entry "$dir" "$kind" "$target" "$value" || failed=$((failed + 1))
  done
  if [ "$udev" = 1 ] && has_cmd udevadm; then
    do_run udevadm control --reload-rules || true
  fi
  if [ "$failed" -gt 0 ]; then
    step_fail "$failed of $n change(s) could not be restored; the snapshot is kept for another try"
    return 1
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would restore $n change(s)"
  else
    printf '%(%Y-%m-%d %H:%M:%S)T\n' -1 > "$dir/undone"
    step_updated "restored $n change(s)"
  fi
}

# undo_main ID: --undo [ID].
undo_main() {
  local id="${1:-}" dir
  if [ -z "$id" ] || [ "$id" = latest ]; then
    id=$(snap_latest) || {
      log_error "no snapshot to undo in $(snap_base)"
      return 1
    }
  fi
  dir="$(snap_base)/$id"
  [ -f "$dir/manifest" ] || { log_error "no snapshot $id in $(snap_base)"; return 1; }
  [ -e "$dir/undone" ] && log_warn "snapshot $id was already undone on $(read_line "$dir/undone"); restoring it again"
  log_info "snapshot $id: $(snap_summary "$id")"
  if [ "$SO_DRY_RUN" != 1 ]; then
    confirm "Restore the system settings saved in snapshot $id?" || return 1
  fi
  SO_UNDO_ID="$id"
  run_step undo undo_step
}
