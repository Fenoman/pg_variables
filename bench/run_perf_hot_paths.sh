#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
	echo "perf benchmarks require Linux" >&2
	exit 2
fi

if ! command -v perf >/dev/null 2>&1; then
	echo "perf is not installed" >&2
	exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${RESULTS_DIR:-${SCRIPT_DIR}/results/perf_$(date +%Y%m%d_%H%M%S)}"
DBNAME="${DBNAME:-pgvbench}"
PSQL="${PSQL:-psql}"
SUDO="${SUDO:-sudo}"

ITERATIONS="${ITERATIONS:-100000000}"
TEXT_ITERATIONS="${TEXT_ITERATIONS:-50000000}"
PERF_SECONDS="${PERF_SECONDS:-8}"
PERF_FREQ="${PERF_FREQ:-999}"
WARMUP_SECONDS="${WARMUP_SECONDS:-2}"

mkdir -p "${RESULTS_DIR}"
chmod 0777 "${RESULTS_DIR}"

run_profile()
{
	local name="$1"
	local sql="$2"
	local sqlfile="${RESULTS_DIR}/${name}.sql"
	local pidfile="${RESULTS_DIR}/${name}.pid"
	local backend_pid

	rm -f "${pidfile}"

	cat > "${sqlfile}" <<SQL
\\set ON_ERROR_STOP on
\\pset tuples_only on
\\pset format unaligned
\\timing on
SET jit = off;
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_variables;
SELECT pgv_free();
SELECT pgv_set('bench_scalar', 'int_value', 0);
SELECT pgv_set('bench_scalar', 'text_value', repeat('x', 32));
\\o ${pidfile}
SELECT pg_backend_pid();
\\o
SELECT pg_sleep(${WARMUP_SECONDS});
${sql}
SQL
	chmod 0644 "${sqlfile}"

	echo "Profiling ${name}" >&2
	# PSQL may intentionally contain extra arguments, for example:
	#   PSQL="sudo -u postgres psql" ./bench/run_perf_hot_paths.sh
	# shellcheck disable=SC2086
	${PSQL} -X -d "${DBNAME}" -f "${sqlfile}" > "${RESULTS_DIR}/${name}.out" 2>&1 &
	local psql_pid=$!

	for _ in $(seq 1 100); do
		[[ -s "${pidfile}" ]] && break
		sleep 0.05
	done

	if [[ ! -s "${pidfile}" ]]; then
		echo "Could not capture backend pid for ${name}" >&2
		wait "${psql_pid}" || true
		return 1
	fi

	backend_pid="$(tr -cd '0-9' < "${pidfile}")"
	echo "${backend_pid}" > "${RESULTS_DIR}/${name}.backend_pid"

	${SUDO} perf record \
		-F "${PERF_FREQ}" \
		-g --call-graph fp \
		-p "${backend_pid}" \
		-o "${RESULTS_DIR}/${name}.data" \
		-- sleep "${PERF_SECONDS}" \
		> "${RESULTS_DIR}/${name}.record.log" 2>&1 || true

	wait "${psql_pid}"

	${SUDO} perf report --stdio --no-children --percent-limit 0.3 \
		--sort dso,symbol \
		-i "${RESULTS_DIR}/${name}.data" \
		> "${RESULTS_DIR}/${name}.nochildren" 2>&1 || true

	${SUDO} perf report --stdio --children --percent-limit 0.8 \
		--sort dso,symbol \
		-i "${RESULTS_DIR}/${name}.data" \
		> "${RESULTS_DIR}/${name}.children" 2>&1 || true
}

run_profile "set_int" \
	"SELECT count(pgv_set('bench_scalar', 'int_value', g::int)) FROM (SELECT generate_series(1, ${ITERATIONS}) AS g) AS s;"
run_profile "get_int" \
	"SELECT count(pgv_get('bench_scalar', 'int_value', NULL::int)) FROM (SELECT generate_series(1, ${ITERATIONS}) AS g) AS s;"
run_profile "exists_int" \
	"SELECT count(pgv_exists('bench_scalar', 'int_value')) FROM (SELECT generate_series(1, ${ITERATIONS}) AS g) AS s;"
run_profile "get_text32" \
	"SELECT count(pgv_get('bench_scalar', 'text_value', NULL::text)) FROM (SELECT generate_series(1, ${ITERATIONS}) AS g) AS s;"
run_profile "set_text32" \
	"SELECT count(pgv_set('bench_scalar', 'text_value', repeat('x', 32))) FROM (SELECT generate_series(1, ${TEXT_ITERATIONS}) AS g) AS s;"

echo "perf output written to ${RESULTS_DIR}" >&2
