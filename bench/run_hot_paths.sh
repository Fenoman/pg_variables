#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

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
REPEATS="${REPEATS:-5}"
RUN_TYPED="${RUN_TYPED:-1}"
RUN_RECORDS="${RUN_RECORDS:-1}"
RUN_ARRAYS="${RUN_ARRAYS:-1}"

for name in ITERATIONS TEXT_ITERATIONS FIXED_ITERATIONS RECORD_ITERATIONS ARRAY_ITERATIONS REPEATS; do
	[[ "${!name}" =~ ^[1-9][0-9]*$ ]] || { echo "$name must be a positive integer" >&2; exit 2; }
done

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
OUT="$(mktemp "${RESULTS_DIR}/hot_paths_$(date +%Y%m%d_%H%M%S)_XXXXXX.out")"
RAW_DIR="${OUT%.out}.raw"
mkdir "$RAW_DIR"
trap 'rc=$?; printf "%s\n" "$rc" > "$RAW_DIR/exit-code"' EXIT

# Provenance so before/after comparisons are pinned to a build.
GIT_REV="$(git -C "${SCRIPT_DIR}/.." rev-parse HEAD 2>/dev/null || echo unknown)"
if git -C "${SCRIPT_DIR}/.." status --porcelain --untracked-files=all > "$RAW_DIR/git-status" 2> "$RAW_DIR/git-error"; then
	[[ ! -s "$RAW_DIR/git-status" ]] || GIT_REV="${GIT_REV} (dirty)"
else
	GIT_REV="${GIT_REV} (status unavailable)"
fi
sha256sum "$SCRIPT_DIR/run_hot_paths.sh" "$SQL_FILE" > "$RAW_DIR/workloads.sha256"

echo "Writing benchmark output to ${OUT}" >&2
{
	echo "# git:        ${GIT_REV}"
	echo "# dbname:     ${DBNAME}"
	echo "# iterations: ${ITERATIONS}  text: ${TEXT_ITERATIONS}  fixed: ${FIXED_ITERATIONS}  record: ${RECORD_ITERATIONS}  array: ${ARRAY_ITERATIONS}"
	echo "# repeats:    ${REPEATS}   (compare the median across runs)"
	echo "# raw logs:   ${RAW_DIR}"
} | tee "${OUT}"

# Repeat the whole run REPEATS times; each \timing line is one measurement, so
# the median across runs is what to compare. A single run is dominated by cache
# warm-up and one-off noise.
for ((run = 1; run <= REPEATS; run++)); do
	echo "=== run ${run}/${REPEATS} ===" | tee -a "${OUT}"
	# PSQL may intentionally contain extra arguments, for example:
	#   PSQL="sudo -u postgres psql" ./bench/run_hot_paths.sh
	# shellcheck disable=SC2086
	if ${PSQL} -X -v ON_ERROR_STOP=1 \
		-v iterations="${ITERATIONS}" \
		-v text_iterations="${TEXT_ITERATIONS}" \
		-v fixed_iterations="${FIXED_ITERATIONS}" \
		-v record_iterations="${RECORD_ITERATIONS}" \
		-v array_iterations="${ARRAY_ITERATIONS}" \
		-v run_typed="${RUN_TYPED_SQL}" \
		-v run_records="${RUN_RECORDS_SQL}" \
		-v run_arrays="${RUN_ARRAYS_SQL}" \
		-d "${DBNAME}" \
		-f "${SQL_FILE}" > "$RAW_DIR/run.$run.out" 2> "$RAW_DIR/run.$run.stderr"; then rc=0; else rc=$?; fi
	printf '%s\n' "$rc" > "$RAW_DIR/run.$run.rc"
	cat "$RAW_DIR/run.$run.out" "$RAW_DIR/run.$run.stderr" | tee -a "$OUT"
	[[ "$rc" == 0 ]] || exit "$rc"
done
