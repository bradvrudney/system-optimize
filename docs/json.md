# Machine-readable output and history

For programs that drive system-optimize: the tray app, the local tuning
agent, scripts. Everything here is versioned: each document carries
`"schema"` and `"version"`. Within a version, fields are only ever added;
a field is never removed or changes meaning without the version going up.
Consumers should ignore fields they do not know.

## `--json`

`--json` works with every mode. It prints exactly one JSON document on
stdout and nothing else; the human-readable messages still go to the run
log (and to stderr with `--verbose`). The exit status is the same as
without `--json`.

| Command | Document |
| --- | --- |
| `--status --json` | `system-optimize/status` |
| `--list-steps --json` | `system-optimize/steps` |
| `[--dry-run] [options] --json` (apply) | `system-optimize/run` |
| `--undo [ID] --json` | `system-optimize/run` |
| `--benchmark-only --json` | `system-optimize/benchmark` |
| `--compare FILE --json` | `system-optimize/benchmark` |
| `--tune --json` | `system-optimize/tune` |
| `--check-drift --json` | `system-optimize/drift` |
| `--sample --json` | `system-optimize/sample` |
| `--history [N] --json` | `system-optimize/history` |
| `--list-snapshots --json` | `system-optimize/snapshots` |

Usage errors (exit 2) print `{"schema":"system-optimize/error","version":1,"error":"..."}`.

Common types:

- times are RFC 3339 in UTC, `"2026-11-01T16:20:05Z"`;
- a step `result` is one of `ok` (already in place), `updated`,
  `skipped`, `warning`, `failed`, `dry-run` (would change);
- a step `state` (status and list-steps) is one of `in-place`,
  `would-change`, `not-applicable`, `not-selected`, `unknown`;
- ids of runs and snapshots are `YYYYmmdd-HHMMSS[-N]`.

### `system-optimize/status`

```json
{
  "schema": "system-optimize/status", "version": 1,
  "generated_at": "2026-11-01T16:20:05Z",
  "program": { "version": "2.1.0", "commit": "757279e", "bundled": true },
  "system": {
    "os": { "id": "fedora", "id_like": "", "name": "Fedora Linux 43 (Workstation Edition)", "version_id": "43" },
    "kernel": "6.17.4-300.fc43.x86_64",
    "package_manager": "dnf", "can_install": true,
    "init": "systemd",
    "cpu": { "count": 24, "vendor": "AuthenticAMD", "model": "AMD Ryzen AI 9 HX 370", "driver": "amd-pstate-epp",
             "governor": "powersave", "energy_preference": "balance_performance" },
    "memory": { "ram_gib": 64, "swap_kind": "zram", "swap_mib": 8192 },
    "virtual": "none", "container": "none", "portable": true,
    "power_profile": { "daemon": "tuned-ppd", "profile": "performance" },
    "backend": "tuned",
    "desktop": { "session": "gnome", "display_server": "wayland", "user": "brad" }
  },
  "steps": [ /* the same objects as system-optimize/steps */ ],
  "profiles": [ /* the same objects as system-optimize/steps */ ],
  "helpers": [ { "name": "systemd-oomd", "state": "running" } ],
  "snapshots": [ /* the same objects as system-optimize/snapshots, newest first, at most 10 */ ],
  "drift": null,
  "last_benchmark": null,
  "settings": { "TIMEOUT": { "value": "300", "source": "default" } }
}
```

`helpers[].state` is `running`, `installed` or `absent`. `drift` is the
last `system-optimize/drift` document or `null`; `last_benchmark` the last
`system-optimize/benchmark` document or `null`. `settings` lists every
setting with its value and where it came from (`default`, `env`, `flag`
or `FILE:LINE`).

### `system-optimize/steps`

```json
{
  "schema": "system-optimize/steps", "version": 1,
  "steps": [
    {
      "name": "sysctl", "group": "default", "category": "kernel",
      "title": "Kernel settings sized to RAM and swap",
      "selected": true, "state": "would-change",
      "detail": "would change 14 setting(s)",
      "needs_reboot": false, "reversible": true
    },
    {
      "name": "noatime", "group": "opt-in", "category": "disk",
      "title": "noatime on local filesystems",
      "selected": false, "state": "not-selected", "detail": "",
      "needs_reboot": false, "reversible": true
    }
  ],
  "profiles": [
    { "name": "dev", "title": "Developer workstation", "steps": ["pkgmgr", "ccache", "plocate", "indexer", "noatime", "journal"], "active": false }
  ]
}
```

`group` is `default` (runs unless skipped) or `opt-in` (runs only when
enabled with `--enable`, `ENABLE=`, `--only` or a profile). `state` comes
from a dry run of each step, so it costs a few seconds; `--list-steps
--json --no-state` leaves every state `unknown` and returns at once.

### `system-optimize/run`

```json
{
  "schema": "system-optimize/run", "version": 1,
  "id": "20261101-162005", "mode": "apply",
  "dry_run": false, "started_at": "...", "finished_at": "...", "exit_status": 0,
  "snapshot": "20261101-162005",
  "steps": [ { "name": "sysctl", "result": "updated", "message": "changed 14 setting(s); saved in /etc/sysctl.d/99-system-optimize.conf" } ],
  "benchmark": { "before": { /* benchmark */ }, "after": { /* benchmark */ }, "comparison": { /* see below */ } },
  "safe_apply": { "deadline": "...", "state": "confirmed" },
  "log": "/var/log/system-optimize/20261101-162005-apply-4242.log"
}
```

`mode` is `apply` or `undo`. `snapshot` is `null` when nothing changed.
`benchmark` is present with `--benchmark`; `safe_apply` with `--safe`
(`state`: `confirmed`, `rolled-back`, `pending`, `rolled-back-regression`).

### `system-optimize/benchmark`

```json
{
  "schema": "system-optimize/benchmark", "version": 1,
  "id": "20261101-162005-before", "phase": "before",
  "taken_at": "...", "duration_s": 41,
  "machine": { "cpu_model": "AMD Ryzen AI 9 HX 370", "cpus": 24, "ram_gib": 64, "kernel": "6.17.4-300.fc43.x86_64", "os_id": "fedora" },
  "tests": [
    { "name": "cpu", "tool": "sysbench", "metric": "events_per_second", "unit": "events/s", "value": 41234.5, "higher_is_better": true },
    { "name": "memory", "tool": "sysbench", "metric": "throughput", "unit": "MiB/s", "value": 18342.1, "higher_is_better": true },
    { "name": "disk-randread", "tool": "fio", "metric": "iops", "unit": "IOPS", "value": 81234, "higher_is_better": true },
    { "name": "disk-seqwrite", "tool": "fio", "metric": "bandwidth", "unit": "MiB/s", "value": 1834.2, "higher_is_better": true },
    { "name": "latency", "tool": "builtin", "metric": "p99_wakeup", "unit": "us", "value": 85, "higher_is_better": false }
  ],
  "skipped": [ { "name": "disk-randread", "reason": "fio is not installed" } ],
  "comparison": null
}
```

`phase` is `before`, `after` or `standalone`. `comparison` (on the `after`
document, and from `--compare`) is:

```json
{
  "against": "20261101-162005-before",
  "tests": [ { "name": "cpu", "before": 41000.0, "after": 41234.5, "change_pct": 0.6, "verdict": "same" } ],
  "overall_change_pct": 1.8, "verdict": "better", "threshold_pct": 3
}
```

`change_pct` is positive when the result got better, whichever way the
metric runs. `verdict` is `better`, `worse` or `same` (within the noise
threshold, `BENCH_THRESHOLD`, default 3 %). `overall_change_pct` is the
geometric mean of the per-test changes.

### `system-optimize/tune`

```json
{
  "schema": "system-optimize/tune", "version": 1,
  "id": "20261101-170000", "started_at": "...", "finished_at": "...",
  "baseline": { /* benchmark */ },
  "trials": [
    { "candidate": "profile:gaming", "snapshot": "20261101-170112", "benchmark": { /* benchmark */ },
      "change_pct": 4.2, "kept": true, "reason": "4.2 % faster" },
    { "candidate": "step:noatime", "snapshot": "20261101-170420", "benchmark": { /* benchmark */ },
      "change_pct": -0.4, "kept": false, "reason": "no gain; rolled back" }
  ],
  "kept": ["profile:gaming"]
}
```

### `system-optimize/drift`

```json
{
  "schema": "system-optimize/drift", "version": 1, "checked_at": "...",
  "baseline_snapshot": "20261101-162005",
  "drifted": true,
  "steps": [ { "name": "sysctl", "detail": "would change 2 setting(s)" } ]
}
```

### `system-optimize/sample`

One sample of how the machine is doing (also written to the history):

```json
{
  "schema": "system-optimize/sample", "version": 1, "taken_at": "...",
  "metrics": {
    "load1": 0.42, "mem_available_mib": 51234, "swap_used_mib": 0,
    "psi_cpu_some_avg10": 0.0, "psi_memory_some_avg10": 0.0, "psi_io_some_avg10": 0.12,
    "cpu_temp_c": 48.0, "power_source": "ac", "power_profile": "performance"
  }
}
```

A metric the machine cannot report is left out.

### `system-optimize/snapshots` and `system-optimize/history`

```json
{ "schema": "system-optimize/snapshots", "version": 1,
  "snapshots": [ { "id": "20261101-162005", "created_at": "...", "entries": 23, "undone": false, "command": "system-optimize -y --enable noatime" } ] }
```

```json
{ "schema": "system-optimize/history", "version": 1, "store": "sqlite",
  "runs": [ { "id": "...", "mode": "apply", "started_at": "...", "exit_status": 0, "snapshot": "..." } ],
  "benchmarks": [ /* benchmark documents, newest first */ ],
  "samples": [ /* sample documents, newest first */ ] }
```

## History store

Every real run, benchmark, tuning trial, drift check and sample is kept in
a small history so that results can be compared over time. `--undo` never
touches it.

Where: `/var/lib/system-optimize/history.db` for root,
`${XDG_STATE_HOME:-~/.local/state}/system-optimize/history.db` otherwise
(`HISTORY_DIR` changes the directory). Without `sqlite3` the same tables
are tab-separated files in a `history/` directory next to it, one file per
table, with a header line. `--history` reads either.

Schema (SQLite; `PRAGMA user_version` is the schema version, 1):

```sql
CREATE TABLE runs (
  id TEXT PRIMARY KEY,            -- the run id (also the snapshot id when one was saved)
  mode TEXT NOT NULL,             -- apply | undo | tune | benchmark
  started_at TEXT NOT NULL, finished_at TEXT,
  exit_status INTEGER, snapshot TEXT,
  command TEXT,                   -- the command line, as in the log header
  steps_json TEXT                 -- the "steps" array of system-optimize/run
);
CREATE TABLE benchmarks (
  id TEXT NOT NULL,               -- benchmark id (run id plus -before/-after, or its own)
  run_id TEXT, phase TEXT NOT NULL, taken_at TEXT NOT NULL,
  test TEXT NOT NULL, tool TEXT, metric TEXT, unit TEXT,
  value REAL NOT NULL, higher_is_better INTEGER NOT NULL,
  PRIMARY KEY (id, test)
);
CREATE TABLE samples (
  taken_at TEXT NOT NULL, metric TEXT NOT NULL, value TEXT NOT NULL,
  PRIMARY KEY (taken_at, metric)
);
CREATE TABLE trials (
  tune_id TEXT NOT NULL, candidate TEXT NOT NULL, snapshot TEXT,
  benchmark_id TEXT, change_pct REAL, kept INTEGER NOT NULL, reason TEXT,
  PRIMARY KEY (tune_id, candidate)
);
CREATE TABLE drift (
  checked_at TEXT PRIMARY KEY, drifted INTEGER NOT NULL, steps_json TEXT
);
```

Maintenance: `--history-prune DAYS` deletes rows older than DAYS (samples
first; default `HISTORY_KEEP_DAYS=180` is applied after every run),
`--history-clear` empties the store after a confirmation (`--yes`).
Readers should open the database read-only
(`sqlite3 -readonly` or `file:...?mode=ro`); system-optimize writes with a
busy timeout, so a reader never blocks a run for long.
