#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

if [[ "$(uname -s)" != Linux ]] || ! command -v perf >/dev/null 2>&1; then
	echo "perf benchmarks require Linux and an installed perf executable" >&2
	exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${RESULTS_DIR:-${SCRIPT_DIR}/results}"
DBNAME="${DBNAME:-pgvbench}"
PSQL="${PSQL:-psql}"
SUDO="${SUDO-sudo}"
ITERATIONS="${ITERATIONS:-10000000}"
TEXT_ITERATIONS="${TEXT_ITERATIONS:-5000000}"
PERF_SECONDS="${PERF_SECONDS:-8}"
PERF_FREQ="${PERF_FREQ:-999}"
WARMUP_SECONDS="${WARMUP_SECONDS:-2}"
PERF_CALLGRAPH="${PERF_CALLGRAPH:-dwarf}"
for name in ITERATIONS TEXT_ITERATIONS PERF_SECONDS PERF_FREQ; do
	[[ "${!name}" =~ ^[1-9][0-9]*$ ]] || { echo "$name must be a positive integer" >&2; exit 2; }
done
[[ "$WARMUP_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid WARMUP_SECONDS" >&2; exit 2; }

mkdir -p "$RESULTS_DIR"
RESULTS_DIR="$(mktemp -d "$RESULTS_DIR/perf_$(date +%Y%m%d_%H%M%S)_XXXXXX")"
psql_pid=""
backend_pid=""
application_name=""

finish()
{
	local rc=$?
	trap - EXIT
	set +e
	if [[ -n "$psql_pid" ]]; then
		if kill -0 "$psql_pid" 2>/dev/null; then
			if [[ "$backend_pid" =~ ^[1-9][0-9]*$ ]]; then
				# Cancel only this run's connection, even if the PID has been reused.
				# shellcheck disable=SC2086
				PGCONNECT_TIMEOUT=5 ${PSQL} -X -v ON_ERROR_STOP=1 -qAt -d "$DBNAME" \
					-c "SET statement_timeout = '5s'; SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE pid = $backend_pid AND application_name = '$application_name'" \
					> "$RESULTS_DIR/cancel.log" 2>&1
			fi
			kill -TERM "$psql_pid" 2>/dev/null
		fi
		wait "$psql_pid" 2>/dev/null
		if [[ "$rc" == 0 ]]; then rc=1; fi
	fi
	printf '%s\n' "$rc" > "$RESULTS_DIR/exit-code"
	exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

GIT_REV="$(git -C "$SCRIPT_DIR/.." rev-parse HEAD 2>/dev/null || echo unknown)"
if git -C "$SCRIPT_DIR/.." status --porcelain --untracked-files=all > "$RESULTS_DIR/git-status" 2> "$RESULTS_DIR/git-error"; then
	[[ ! -s "$RESULTS_DIR/git-status" ]] || GIT_REV="$GIT_REV (dirty)"
else
	GIT_REV="$GIT_REV (status unavailable)"
fi
{
	printf 'git=%s\ndbname=%s\niterations=%s\ntext_iterations=%s\n' "$GIT_REV" "$DBNAME" "$ITERATIONS" "$TEXT_ITERATIONS"
	printf 'seconds=%s\nfrequency=%s\ncallgraph=%s\n' "$PERF_SECONDS" "$PERF_FREQ" "$PERF_CALLGRAPH"
	sha256sum "$SCRIPT_DIR/run_perf_hot_paths.sh"
} > "$RESULTS_DIR/provenance.log"

backend_active()
{
	local active
	# shellcheck disable=SC2086
	active="$(${PSQL} -X -v ON_ERROR_STOP=1 -qAt -d "$DBNAME" \
		-c "SELECT EXISTS (SELECT FROM pg_stat_activity WHERE pid = $backend_pid AND application_name = '$application_name' AND state = 'active' AND query LIKE 'SELECT count(pgv_%')" \
		2>> "$RESULTS_DIR/activity.stderr")" || return 1
	[[ "$active" == t ]]
}

run_perf()
{
	local log="$1" rc
	shift
	# shellcheck disable=SC2086
	if ${SUDO} perf "$@" > "$log" 2>&1; then rc=0; else rc=$?; fi
	printf '%s\n' "$rc" > "$log.rc"
	if [[ "$rc" != 0 ]]; then cat "$log" >&2; fi
	return "$rc"
}

run_profile()
{
	local name="$1" sql="$2" sqlfile ready=0 rc
	sqlfile="$RESULTS_DIR/$name.sql"
	application_name="pgv_perf_$$_$name"
	backend_pid=""
	cat > "$sqlfile" <<SQL
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
SET application_name = '$application_name';
SET jit = off;
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_variables;
SELECT version(), extversion FROM pg_extension WHERE extname = 'pg_variables';
SELECT pgv_free();
SELECT pgv_set('bench_scalar', 'int_value', 0);
SELECT pgv_set('bench_scalar', 'text_value', repeat('x', 32));
SELECT pg_backend_pid() AS pgv_backend_pid \gset
\echo PGV_BACKEND_PID :pgv_backend_pid
SELECT pg_sleep($WARMUP_SECONDS);
\timing on
$sql
SQL

	echo "Profiling $name. Logs: $RESULTS_DIR" >&2
	# stdin keeps private SQL files readable when PSQL uses another OS user.
	# shellcheck disable=SC2086
	${PSQL} -X -v ON_ERROR_STOP=1 -d "$DBNAME" -f - < "$sqlfile" > "$RESULTS_DIR/$name.out" 2>&1 &
	psql_pid=$!
	for ((attempt = 0; attempt < 200; attempt++)); do
		backend_pid="$(awk '/^PGV_BACKEND_PID [0-9]+$/ { print $2; exit }' "$RESULTS_DIR/$name.out")"
		if [[ "$backend_pid" =~ ^[1-9][0-9]*$ ]] && backend_active; then ready=1; break; fi
		kill -0 "$psql_pid" 2>/dev/null || break
		sleep 0.05
	done
	if [[ "$ready" != 1 ]]; then
		echo "No active target query for $name. Increase the iteration count if it finishes before capture." >&2
		cat "$RESULTS_DIR/$name.out" >&2
		return 1
	fi
	printf '%s\n' "$backend_pid" > "$RESULTS_DIR/$name.backend_pid"

	run_perf "$RESULTS_DIR/$name.record.log" record -F "$PERF_FREQ" -g --call-graph "$PERF_CALLGRAPH" \
		-p "$backend_pid" -o "$RESULTS_DIR/$name.data" -- sleep "$PERF_SECONDS"
	if ! kill -0 "$psql_pid" 2>/dev/null || ! backend_active; then
		echo "Target query ended during $name capture. Increase the iteration count." >&2
		return 1
	fi
	if wait "$psql_pid"; then rc=0; else rc=$?; fi
	psql_pid=""
	printf '%s\n' "$rc" > "$RESULTS_DIR/$name.psql.rc"
	[[ "$rc" == 0 ]] || return "$rc"
	[[ -s "$RESULTS_DIR/$name.data" ]] || { echo "Empty perf data for $name" >&2; return 1; }

	run_perf "$RESULTS_DIR/$name.nochildren" report --stdio --no-children --percent-limit 0.3 \
		--sort dso,symbol -i "$RESULTS_DIR/$name.data"
	run_perf "$RESULTS_DIR/$name.children" report --stdio --children --percent-limit 0.8 \
		--sort dso,symbol -i "$RESULTS_DIR/$name.data"
	run_perf "$RESULTS_DIR/$name.stacks" script -i "$RESULTS_DIR/$name.data"
	if ! grep -Eq '^[^[:space:]#].*[0-9]+\.[0-9]+:' "$RESULTS_DIR/$name.stacks" ||
		! grep -Eq '(variable_(set|get)_any|variable_exists).*pg_variables[.]so' "$RESULTS_DIR/$name.stacks"; then
		echo "No symbolized pg_variables samples for $name" >&2
		return 1
	fi
}

run_profile set_int \
	"SELECT count(pgv_set('bench_scalar', 'int_value', g::int)) FROM (SELECT generate_series(1, ${ITERATIONS}) AS g) AS s;"
run_profile get_int \
	"SELECT count(pgv_get('bench_scalar', 'int_value', NULL::int)) FROM (SELECT generate_series(1, ${ITERATIONS}) AS g) AS s;"
run_profile exists_int \
	"SELECT count(pgv_exists('bench_scalar', 'int_value')) FROM (SELECT generate_series(1, ${ITERATIONS}) AS g) AS s;"
run_profile get_text32 \
	"SELECT count(pgv_get('bench_scalar', 'text_value', NULL::text)) FROM (SELECT generate_series(1, ${ITERATIONS}) AS g) AS s;"
run_profile set_text32 \
	"SELECT count(pgv_set('bench_scalar', 'text_value', repeat('x', 32))) FROM (SELECT generate_series(1, ${TEXT_ITERATIONS}) AS g) AS s;"

echo "Complete perf output: $RESULTS_DIR" >&2
