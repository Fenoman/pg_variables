#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="${SCRIPT_DIR}/sql/hot_paths.sql"
RESULTS_DIR="${RESULTS_DIR:-${SCRIPT_DIR}/results}"
DBNAME="${DBNAME:-pgvbench}"
PSQL="${PSQL:-psql}"

ITERATIONS="${ITERATIONS:-100000000}"
TEXT_ITERATIONS="${TEXT_ITERATIONS:-50000000}"
RECORD_ITERATIONS="${RECORD_ITERATIONS:-100}"
RUN_TYPED="${RUN_TYPED:-1}"
RUN_RECORDS="${RUN_RECORDS:-1}"

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

mkdir -p "${RESULTS_DIR}"
OUT="${RESULTS_DIR}/hot_paths_$(date +%Y%m%d_%H%M%S).out"

echo "Writing benchmark output to ${OUT}" >&2
echo "DBNAME=${DBNAME} ITERATIONS=${ITERATIONS} TEXT_ITERATIONS=${TEXT_ITERATIONS} RECORD_ITERATIONS=${RECORD_ITERATIONS}" >&2

# PSQL may intentionally contain extra arguments, for example:
#   PSQL="sudo -u postgres psql" ./bench/run_hot_paths.sh
# shellcheck disable=SC2086
${PSQL} -X \
	-v iterations="${ITERATIONS}" \
	-v text_iterations="${TEXT_ITERATIONS}" \
	-v record_iterations="${RECORD_ITERATIONS}" \
	-v run_typed="${RUN_TYPED_SQL}" \
	-v run_records="${RUN_RECORDS_SQL}" \
	-d "${DBNAME}" \
	-f "${SQL_FILE}" | tee "${OUT}"
