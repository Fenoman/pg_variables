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
REPEATS=5 \
RUN_TYPED=1 \
RUN_RECORDS=1 \
DBNAME=pgvbench \
./bench/run_hot_paths.sh
```

When local authentication requires another OS user, pass a `psql` command:

```bash
PSQL="sudo -u postgres psql" DBNAME=pgvbench ./bench/run_hot_paths.sh
```

Each run starts with a `baseline count(g)` line for the `generate_series` +
`count` overhead. Match the iteration count and expression construction before
subtracting durations and dividing by the operation count. Run a warmup before
collecting at least five valid repeats. Compare their median, range and IQR.
If the spread is comparable to the difference, the result is inconclusive.

## Per-transaction Throughput (pgbench)

`hot_paths.sql` loops inside one statement, so it pays commit-time cleanup once
per statement. `bench/run_pgbench.sh` measures repeated workload iterations.
Each SQL statement autocommits unless the script contains explicit
`BEGIN`/`COMMIT`. The transactional scenarios include `processChanges` and
`ModuleContext` teardown at their actual commit boundaries.

```bash
DBNAME=pgvbench ./bench/run_pgbench.sh
# knobs: TXNS (default 200000), CLIENTS (1), REPEATS (5), PGBENCH, PSQL
```

Each scenario receives an unmeasured warmup of up to 1000 iterations per client.
The measured sweep reverses order on alternate repeats to reduce order bias.
The summary reports median, minimum, maximum and IQR of average latency in
milliseconds per workload iteration. IQR uses linearly interpolated quartiles.

| Workload | Shape | Matched baseline |
| --- | --- | --- |
| `set_reg` | One regular set, one autocommit | `baseline`: one `SELECT 1` |
| `set_tx` | One transactional set, one autocommit | `baseline`: one `SELECT 1` |
| `insert_reg` | Two inserts and two deletes, four autocommits | `baseline_4x`: four `SELECT 1` statements |
| `tx_block` | Four transactional sets in one explicit transaction | `baseline_tx_block`: `BEGIN`, four `SELECT 1` statements, `COMMIT` |

Subtract latency for matched iterations, then divide by the number of measured
operations when a per-operation estimate is useful. Do not subtract TPS.
`insert_reg` includes both insertion and deletion, so its delta does not isolate
insertion. `set_tx` versus `set_reg` includes both call setup and commit cleanup.
Measure calls inside an open transaction and `COMMIT`/`ABORT` separately to
attribute those costs. The scalar perf profiles below measure calls only.

Reads use backend-local state. A pgbench read workload can set and read a value
within the same connection. The in-statement runner already covers reads.

Every pgbench invocation saves stdout, stderr and its exit code. Missing
metrics, incomplete transaction counts and reported failures reject the sweep.
Only a complete sweep produces the final summary. Raw files retain TPS and
per-repeat latency for independent analysis.

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

The runner waits for the exact backend and application name to execute its
target query. The query must remain active throughout the capture. Increase
`ITERATIONS`/`TEXT_ITERATIONS` if it finishes too early. `WARMUP_SECONDS` is a
startup delay, not a measured warmup. A denied perf invocation, failed SQL,
empty recording or missing symbolized pg_variables stack rejects the run.

The runner writes private `*.data`, `*.children`, `*.nochildren` and `*.stacks`
files plus SQL, command exit codes and logs under a unique
`bench/results/perf_<timestamp>_<suffix>/` directory. `RESULTS_DIR` selects the
parent directory. `SUDO=''` runs perf directly when the current user already
has permission. Permission failures mean profiling is unavailable with those
credentials. They are not successful profiles.

On ARM virtual machines, generic hardware aliases such as `cycles` or
`instructions` may be unavailable even as root. In that case, call graph samples
from `perf record` are still useful, but IPC/cache/branch conclusions require a
host or VM with PMU passthrough.

## Notes

- All runners record the source revision and staged, unstaged and untracked
  status. Workload hashes and raw outputs are stored under `bench/results/`,
  which git ignores. Source provenance does not prove which extension binary
  the server loaded. Record its installation/build hash separately when
  qualifying a candidate.
- The SQL uses `SELECT generate_series(...)` in a subquery, which produces a
  `ProjectSet` plan and avoids the `FunctionScan` tuplestore path that can
  otherwise dominate profiles.
- `jit` is disabled to reduce noise.
- The record workload is intentionally small because the observed production
  workload is scalar-heavy and record variables normally contain around 100 rows
  at most.
