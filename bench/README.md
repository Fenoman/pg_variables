# pg_variables Benchmarks

This directory contains lightweight benchmarks for the pg_variables hot paths.
They are meant for before/after comparisons on the same machine, not for
portable absolute performance numbers.

## Timing Benchmarks

Build and install the extension for the PostgreSQL server you want to test, then
create a scratch database:

```bash
createdb pgvbench
```

Run the scalar-heavy benchmark:

```bash
DBNAME=pgvbench ./bench/run_hot_paths.sh
```

Useful knobs:

```bash
ITERATIONS=10000000 \
TEXT_ITERATIONS=5000000 \
RECORD_ITERATIONS=10000 \
REPEATS=3 \
RUN_TYPED=1 \
RUN_RECORDS=1 \
DBNAME=pgvbench \
./bench/run_hot_paths.sh
```

When local authentication requires another OS user, pass a `psql` command:

```bash
PSQL="sudo -u postgres psql" DBNAME=pgvbench ./bench/run_hot_paths.sh
```

Each run starts with a `baseline count(g)` line (the `generate_series` + `count`
overhead with no `pgv_*` call) to subtract from the per-op timings. The whole
run repeats `REPEATS` times under a git-rev/version header, so compare the median
across runs rather than a single number.

## Per-transaction Throughput (pgbench)

`hot_paths.sql` loops inside one statement, so it never pays the per-commit cost
of transactional variables (`prepareChangesStack`, `processChanges` and
`ModuleContext` teardown run once per whole run). `bench/run_pgbench.sh` closes
that gap: every scenario in `bench/pgbench/` is one transaction driven by
`pgbench`, so the commit-time discard path is measured.

```bash
DBNAME=pgvbench ./bench/run_pgbench.sh
# knobs: TXNS (default 200000), CLIENTS (1), REPEATS (5), PGBENCH, PSQL
```

Scenarios (median tps over `REPEATS` runs, baseline first):

- `baseline` — `SELECT 1;` (round-trip floor; subtract from the rest)
- `set_reg`  — `pgv_set(..., false)` (regular set, no changesStack)
- `set_tx`   — `pgv_set(..., true)` (transactional set: full per-commit discard)
- `tx_block` — `BEGIN; 4x pgv_set(..., true); COMMIT;` (discard amortised over N sets)

Reads are covered by the in-statement `hot_paths.sql` instead: a pgbench read
scenario is not meaningful here because pg_variables state is backend-local, so
a variable can only be read from the same connection that set it.

The gap between `set_reg` and `set_tx` is the per-commit transactional overhead;
`tx_block` shows how it amortises when several sets share one commit.

The output is stored under `bench/results/` and ignored by git.

## Linux perf Profiles

The perf runner records separate profiles for:

- `pgv_set('bench_scalar', 'int_value', g::int)`
- `pgv_get('bench_scalar', 'int_value', NULL::int)`
- `pgv_exists('bench_scalar', 'int_value')`
- `pgv_get('bench_scalar', 'text_value', NULL::text)`
- `pgv_set('bench_scalar', 'text_value', repeat('x', 32))`

Run it on Linux:

```bash
PSQL="sudo -u postgres psql" \
DBNAME=pgvbench \
PERF_SECONDS=8 \
./bench/run_perf_hot_paths.sh
```

If perf is restricted, lower the kernel guard on a disposable profiling VM:

```bash
sudo sysctl -w kernel.perf_event_paranoid=1
sudo sysctl -w kernel.kptr_restrict=0
```

The runner writes `*.data`, `*.children`, and `*.nochildren` reports under
`bench/results/perf_<timestamp>/`.

On ARM virtual machines, generic hardware aliases such as `cycles` or
`instructions` may be unavailable even as root. In that case, call graph samples
from `perf record` are still useful, but IPC/cache/branch conclusions require a
host or VM with PMU passthrough.

## Notes

- The SQL uses `SELECT generate_series(...)` in a subquery, which produces a
  `ProjectSet` plan and avoids the `FunctionScan` tuplestore path that can
  otherwise dominate profiles.
- `jit` is disabled to reduce noise.
- The record workload is intentionally small because the observed production
  workload is scalar-heavy and record variables normally contain around 100 rows
  at most.
