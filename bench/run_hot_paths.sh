#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="${SCRIPT_DIR}/sql/hot_paths.sql"
RESULTS_DIR="${RESULTS_DIR:-${SCRIPT_DIR}/results}"
DBNAME="${DBNAME:-pgvbench}"
PSQL="${PSQL:-psql}"

ITERATIONS="${ITERATIONS:-10000000}"
TEXT_ITERATIONS="${TEXT_ITERATIONS:-5000000}"
FIXED_ITERATIONS="${FIXED_ITERATIONS:-5000000}"
RECORD_ITERATIONS="${RECORD_ITERATIONS:-10000}"
ARRAY_ITERATIONS="${ARRAY_ITERATIONS:-250000}"
REPEATS="${REPEATS:-3}"
RUN_TYPED="${RUN_TYPED:-1}"
RUN_RECORDS="${RUN_RECORDS:-1}"
RUN_ARRAYS="${RUN_ARRAYS:-1}"

case "${RUN_TYPED}" in
	1|true|on|yes) RUN_TYPED_SQL=true ;;
	0|false|off|no) RUN_TYPED_SQL=false ;;
	*) echo "RUN_TYPED must be 0/1, true/false, on/off, or yes/no" >&2; exit 2 ;;
esac

case "${RUN_RECORDS}" in
	1|true|on|yes) RUN_RECORDS_SQL=true ;;
	0|false|off|no) RUN_RECORDS_SQL=false ;;
	*) echo "RUN_RECORDS must be 0/1, true/false, on/off, or yes/no" >&2; exit 2 ;;
esac

case "${RUN_ARRAYS}" in
	1|true|on|yes) RUN_ARRAYS_SQL=true ;;
	0|false|off|no) RUN_ARRAYS_SQL=false ;;
	*) echo "RUN_ARRAYS must be 0/1, true/false, on/off, or yes/no" >&2; exit 2 ;;
esac

mkdir -p "${RESULTS_DIR}"
OUT="${RESULTS_DIR}/hot_paths_$(date +%Y%m%d_%H%M%S).out"

# Provenance so before/after comparisons are pinned to a build.
GIT_REV="$(git -C "${SCRIPT_DIR}/.." rev-parse --short HEAD 2>/dev/null || echo unknown)"
git -C "${SCRIPT_DIR}/.." diff --quiet 2>/dev/null || GIT_REV="${GIT_REV} (dirty)"

echo "Writing benchmark output to ${OUT}" >&2
{
	echo "# git:        ${GIT_REV}"
	echo "# dbname:     ${DBNAME}"
	echo "# iterations: ${ITERATIONS}  text: ${TEXT_ITERATIONS}  fixed: ${FIXED_ITERATIONS}  record: ${RECORD_ITERATIONS}  array: ${ARRAY_ITERATIONS}"
	echo "# repeats:    ${REPEATS}   (compare the median across runs)"
} | tee "${OUT}"

# Repeat the whole run REPEATS times; each \timing line is one measurement, so
# the median across runs is what to compare. A single run is dominated by cache
# warm-up and one-off noise.
for run in $(seq 1 "${REPEATS}"); do
	echo "=== run ${run}/${REPEATS} ===" | tee -a "${OUT}"
	# PSQL may intentionally contain extra arguments, for example:
	#   PSQL="sudo -u postgres psql" ./bench/run_hot_paths.sh
	# shellcheck disable=SC2086
	${PSQL} -X \
		-v iterations="${ITERATIONS}" \
		-v text_iterations="${TEXT_ITERATIONS}" \
		-v fixed_iterations="${FIXED_ITERATIONS}" \
		-v record_iterations="${RECORD_ITERATIONS}" \
		-v array_iterations="${ARRAY_ITERATIONS}" \
		-v run_typed="${RUN_TYPED_SQL}" \
		-v run_records="${RUN_RECORDS_SQL}" \
		-v run_arrays="${RUN_ARRAYS_SQL}" \
		-d "${DBNAME}" \
		-f "${SQL_FILE}" | tee -a "${OUT}"
done
